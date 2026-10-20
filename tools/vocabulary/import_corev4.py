#!/usr/bin/env python3
"""Copy and independently decode the seven audited CoreV4 English dictionaries.

This imports offline source data, not CoreV4 binary formats into KBLM. Existing
keyboard words/frequencies/context tables are not modified. Compile the original
QuickLZ decoder in a temporary directory with its bounds-checking option enabled.
"""
from __future__ import annotations
import argparse, ctypes, hashlib, json, pathlib, re, shutil, struct, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from verify_language_data import Pack
import build_language_data as builder

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def decode_dictionary(path, codec):
    raw=bytearray(path.read_bytes());span=left=1
    for i in range(len(raw)):
        if left==0:span+=1;left=span
        raw[i]^=0x65 if left==span or left==1 else 0x53
        left-=1
    b=bytes(raw)
    def u16(o):return struct.unpack_from('>H',b,o)[0]
    def u32(o):return struct.unpack_from('>I',b,o)[0]
    def char(o):return chr(struct.unpack_from('<H',b,o)[0])
    if len(b)<70 or u32(0)!=3:raise ValueError('unsupported/truncated lexical format')
    count,nblocks,tail=u32(55),u16(59),u32(66)
    if not count or not nblocks or 70+(nblocks+1)*10>len(b):raise ValueError('invalid header')
    blocks=[(char(70+i*10),u32(76+i*10)) for i in range(nblocks+1)]
    if not all(blocks[i][1]<blocks[i+1][1]<=len(b) for i in range(nblocks)):raise ValueError('invalid block boundaries')
    words=[];payloads=0
    for i,(first,start) in enumerate(blocks[:-1]):
        end=blocks[i+1][1]
        valid,method,ns=struct.unpack_from('>BBH',b,start)
        if start+4+ns*10>end:raise ValueError('invalid subblock table')
        if valid&8:words.append(first)
        subs=[(char(start+4+j*10),u32(start+6+j*10)) for j in range(ns)]
        for j,(second,offset) in enumerate(subs):
            limit=subs[j+1][1] if j+1<ns else end
            if not start+4+ns*10<=offset<limit<=end:raise ValueError('invalid subblock bounds')
            data=b[offset:limit]
            if len(data)<5:raise ValueError('truncated subblock')
            n=struct.unpack_from('>I',data,1)[0]
            if 5+2*n>len(data):raise ValueError('truncated lengths/case flags')
            if data[0]&8:words.append(first+second)
            if not n:continue
            lengths=data[5:5+n];payload=data[5+2*n:]
            if method!=4 or len(payload)<3:raise ValueError('unsupported compression')
            buf=ctypes.create_string_buffer(payload+b'\0'*16)
            compressed=codec.qlz_size_compressed(buf);expanded=codec.qlz_size_decompressed(buf)
            if not 3<=compressed<=len(payload) or not 0<expanded<10_000_000:raise ValueError('invalid compression sizes')
            dest=ctypes.create_string_buffer(expanded+16);scratch=ctypes.create_string_buffer(4096)
            actual=codec.qlz_decompress(buf,dest,scratch)
            if actual!=expanded:raise ValueError('decompression failed')
            unpacked=dest.raw[:expanded];cursor=0
            for length in lengths:
                suffix=[]
                for _ in range(length):
                    if cursor>=len(unpacked):raise ValueError('truncated word suffix')
                    val=unpacked[cursor];cursor+=1
                    if val==0:
                        if cursor+2>len(unpacked):raise ValueError('truncated escaped character')
                        val=int.from_bytes(unpacked[cursor:cursor+2],'big');cursor+=2
                    suffix.append(chr(val))
                words.append(first+second+''.join(suffix))
            if cursor!=len(unpacked):raise ValueError('unconsumed suffix bytes')
            payloads+=1
    if len(words)!=count or len(set(words))!=count:raise ValueError('word count or uniqueness mismatch')
    if not blocks[-1][1]<=tail<=len(b)-4:raise ValueError('invalid special tail')
    cursor=tail;groups=u32(cursor);cursor+=4
    for _ in range(groups):
        if cursor+8>len(b):raise ValueError('truncated special group')
        n=u32(cursor+4);cursor+=8+4*n
        if cursor>len(b):raise ValueError('truncated special entries')
    if cursor+4>len(b):raise ValueError('truncated elision table')
    n=u32(cursor);cursor+=4+4*n
    if cursor!=len(b) or u32(62)*4!=len(b)-tail:raise ValueError('tail size mismatch')
    return words,payloads

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-core',type=pathlib.Path,required=True)
    p.add_argument('--output',type=pathlib.Path,default=ROOT/'tools/data/corev4/english')
    p.add_argument('--baseline-pack', type=pathlib.Path, default=ROOT/'keyboard/langdata.bin', help='pre-import v5 pack; reproduce using build_language_data.py --without-corev4')
    args=p.parse_args();core=args.source_core.resolve();out=args.output.resolve()
    audit=json.loads((core/'analysis/daily-use-audit/dictionary-integrity.json').read_text())
    if len(audit)!=7:raise ValueError('expected seven separately audited English dictionary variants')
    baseline_path=args.baseline_pack.resolve();baseline_sha=sha(baseline_path)
    baseline_pack=Pack(baseline_path);baseline={w.decode('utf-8') for w in baseline_pack.vocabulary()[0]}
    if baseline_pack.version != 5: raise ValueError('supply the pre-import v5 pack using --baseline-pack; refusing to redefine transfer baseline')
    out.mkdir(parents=True,exist_ok=True);(out/'raw').mkdir(exist_ok=True);(out/'wordlists').mkdir(exist_ok=True)
    all_words=set();records=[];assets=[]
    with tempfile.TemporaryDirectory(prefix='corev4-english-import-') as temporary:
        t=pathlib.Path(temporary)
        (t/'quicklz.h').write_text((core/'v2core/core/include/common/quicklz.h').read_text().replace('#include "stdafx.h"','#include <stddef.h>'))
        (t/'quicklz.cpp').write_text((core/'v2core/core/source/common/quicklz.cpp').read_text().replace('#include "kptcall.h"',''))
        library=t/('quicklz.dylib' if sys.platform=='darwin' else 'quicklz.so')
        cmd=['clang++','-std=c++17','-O2','-DKPTINLINE=inline','-DQLZ_MEMORY_SAFE',('-dynamiclib' if sys.platform=='darwin' else '-shared'),'-fPIC',str(t/'quicklz.cpp'),'-o',str(library)]
        subprocess.run(cmd,check=True)
        codec=ctypes.CDLL(str(library))
        for name in ['qlz_size_compressed','qlz_size_decompressed']:
            f=getattr(codec,name);f.argtypes=[ctypes.c_void_p];f.restype=ctypes.c_size_t
        codec.qlz_decompress.argtypes=[ctypes.c_void_p]*3;codec.qlz_decompress.restype=ctypes.c_size_t
        for original in audit:
            # Audit paths identify the original checkout; prefer a relative path
            # under the supplied root so relocating that checkout remains possible.
            old=pathlib.Path(original['path']);parts=old.parts
            relative=pathlib.Path(*parts[parts.index('CoreV4')+1:]);source=core/relative
            if sha(source)!=original['sha256']:raise ValueError('original changed since integrity audit: '+str(relative))
            region={'engus':'en-US','enggb':'en-GB','english_in':'en-IN'}[source.stem]
            label=f"{region}-{original['declared_words']}-{original['sha256'][:8]}"
            directory=out/'raw'/label;directory.mkdir(exist_ok=True)
            sources=[source]
            for n in range(3):
                context=source.parent.parent/'Context'/f'{source.stem}_{n}.atc'
                if not context.is_file():context=source.parent/f'{source.stem}_{n}.atc'
                if not context.is_file():raise ValueError('matching context file absent: '+str(context))
                sources.append(context)
            for asset in sources:
                target=directory/asset.name
                if target.exists() and sha(target)!=sha(asset):raise ValueError('refusing to overwrite a different imported asset: '+str(target))
                shutil.copy2(asset,target)
                if sha(target)!=sha(asset):raise ValueError('copy checksum mismatch')
                assets.append(dict(path=target.relative_to(out).as_posix(),source=asset.relative_to(core).as_posix(),bytes=target.stat().st_size,sha256=sha(target)))
            words,payloads=decode_dictionary(directory/source.name,codec)
            if len(words)!=original['declared_words'] or 'correction' not in words:raise ValueError('audited content mismatch')
            wordlist=out/'wordlists'/f'{label}.txt';wordlist.write_text('\n'.join(sorted(words))+'\n')
            all_words.update(words)
            records.append(dict(id=label,region=region,source=relative.as_posix(),dictionary='raw/'+label+'/'+source.name,dictionary_sha256=original['sha256'],stored_forms=len(words),decoded_payloads=payloads,wordlist=wordlist.relative_to(out).as_posix(),wordlist_sha256=sha(wordlist)))
    compatible={w for w in all_words if re.fullmatch(r"[a-z']+",w) and 2<=len(w)<=32 and not w.startswith("'") and not w.endswith("'") and w not in builder.EXCLUDE}
    exports={'english-all.txt':all_words,'english-ascii.txt':compatible,'english-additions.txt':all_words-baseline,
             'english-ascii-additions.txt':compatible-baseline,'english-merged-with-ios.txt':all_words|baseline}
    generated=[]
    for name,words in exports.items():
        path=out/name;path.write_text('\n'.join(sorted(words))+'\n');generated.append(dict(path=name,forms=len(words),sha256=sha(path)))
    report=dict(schema_version=1,source_project='Xploree / CoreV4 (user-provided local checkout)',scope='Seven distinct audited English lexical variants plus their original matching context triplets',
        active_runtime_modified=False,counts=dict(dictionary_variants=len(records),original_assets=len(assets),core_unique_stored_forms=len(all_words),core_ascii_eligible_forms=len(compatible),current_ios_forms=len(baseline),new_stored_forms=len(all_words-baseline),new_ascii_eligible_forms=len(compatible-baseline),merged_stored_forms=len(all_words|baseline),merged_ascii_with_existing=len(compatible|baseline),current_pack_capacity=65534,current_pack_free_slots=65534-len(baseline)),
        baseline=dict(path='keyboard/langdata.bin',sha256=baseline_sha,format=f'KBLM v{baseline_pack.version}'),dictionaries=records,assets=assets,exports=generated,
        interpretation=['Wordlists preserve stored spellings; CoreV4 capitalization/display flags and special-character expansion rules are not applied. Original binary files retain all such data.',
          'No unigram frequencies are fabricated. Original .atc data is copied losslessly but is not interpreted as iOSKeyboard counts or IDs.',
          'All seven versions remain separate; two UK variants with equal entry counts can differ in bytes/context and must not be collapsed by count.',
          'ASCII eligibility follows current lexical character/exclusion/length policy only; it is not a quality/admission or licensing approval.',
          'Raw CoreV4 files are not KBLM format and are offline source assets, not added to the app resource build.'])
    (out/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    if sha(baseline_path)!=baseline_sha:raise ValueError('active iOS pack changed during transfer')
    print(json.dumps(report['counts'],indent=2))

if __name__=='__main__':main()
