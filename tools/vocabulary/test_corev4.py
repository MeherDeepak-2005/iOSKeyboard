"""Wide-ID serialization and context-preserving CoreV4 admission regressions."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_language_data as builder
from verify_language_data import Pack

class CoreV4Tests(unittest.TestCase):
    def test_sorted_union_remaps_contexts_without_changing_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            data = b'aaa\ncaf\xc3\xa9\ncant\nz\n'
            (root/'english-all.txt').write_bytes(data)
            manifest = root/'manifest.json'
            manifest.write_text(json.dumps({'exports': [{'path':'english-all.txt','forms':4,
                'sha256':hashlib.sha256(data).hexdigest()}]}))
            with patch.object(builder, 'COREV4_MANIFEST', manifest):
                vocab, bi, tri, starters, totals = builder.merge_corev4(
                    [('the',100),('z',1)], {1:[(0,3)]}, {(0,1):[(1,2)]}, [(1,4)],
                    {'bigrams':{1:9},'trigrams':{(0,1):7}})
                self.assertEqual(dict(vocab), {'the':100,'z':1,'aaa':1,'café':1})
                ids = {w:i for i,(w,_) in enumerate(vocab)}
                self.assertEqual(bi, {ids['z']:[(ids['the'],3)]})
                self.assertEqual(tri, {(ids['the'],ids['z']):[(ids['z'],2)]})
                self.assertEqual(totals['bigrams'], {ids['z']:9})
                self.assertEqual(totals['trigrams'], {(ids['the'],ids['z']):7})
                self.assertEqual(starters, [(ids['z'],4)])
                (root/'english-all.txt').write_bytes(data+b'tampered\n')
                with self.assertRaises(SystemExit):
                    builder.merge_corev4([], {}, {}, [], None)

    def test_v5_and_v6_have_identical_logical_contexts_for_small_vocab(self):
        with tempfile.TemporaryDirectory() as temp:
            packs=[]
            for version in (5,6):
                path=Path(temp)/f'v{version}.bin'
                builder.write_bin([('the',10),('word',2)],{0:[(1,3)]},
                    {(0,1):[(1,2)]},[(0,4)],output=path,version=version)
                packs.append(Pack(path))
            old,new=packs
            self.assertEqual(old.vocabulary(),new.vocabulary())
            self.assertEqual(old.bigrams(),new.bigrams())
            self.assertEqual({old.context_pair(k):v for k,v in old.trigrams().items()},new.trigrams())
            self.assertEqual(old.trie(),new.trie())
            self.assertEqual(old.sentence_starters(),new.sentence_starters())

    def test_writer_keeps_context_pairs_and_terminal_ids_above_65535(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/'wide.bin'
            vocab = [(f'w{i:05}',1) for i in range(65538)]
            builder.write_bin(vocab, {65536:[(65537,3)]},
                {(0,65536):[(65536,7)], (1,0):[(65537,9)]}, [(65537,11)],
                output=out,version=6)
            pack=Pack(out)
            self.assertEqual(pack.bigrams()[65536], (3,((65537,3),)))
            self.assertEqual(pack.trigrams()[(0,65536)],(7,((65536,7),)))
            self.assertEqual(pack.trigrams()[(1,0)],(9,((65537,9),)))
            self.assertEqual(pack.sentence_starters(),((65537,11),))
            self.assertTrue(any(row[3]==65537 for row in pack.trie()))
            previous=out.read_bytes()
            with self.assertRaises(ValueError):
                builder.write_bin(vocab,{}, {}, [],output=out,version=6,max_bytes=1)
            self.assertEqual(out.read_bytes(),previous)
