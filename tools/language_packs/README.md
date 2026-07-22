# Language-pack pipeline

Language packs are immutable, hash-verified release units. A `production` manifest
must contain layout, lexicon, transliteration FST, language model, safety, and blind
benchmark artifacts, plus native-speaker approval. The validator rejects path
traversal, symlinks, missing files, checksum changes, and evaluation data declared as
training data.

The Tenglish builder compiles only `tel_train.json` into a deterministic sorted
`KBXL` research lexicon. It intentionally does not compile validation or test rows,
does not mark the result releasable, and does not add it to an Xcode target:

```bash
python3 tools/language_packs/build_tenglish_lexicon.py \
  --input-zip tools/.cache/aksharantar_tel.zip \
  --reviewed-core tools/language_packs/sources/te-IN/tenglish-core-reviewed.tsv \
  --output-dir /tmp/tenglish-pack \
  --license-ack
python3 tools/language_packs/validate_manifest.py /tmp/tenglish-pack/manifest.json
```

Aksharantar contains source-dependent licensing: manually collected rows are CC-BY,
while mined and existing-source rows are CC0. Preserve row provenance and the project
citation in release notices. A generated lexicon is only one input: tap transliteration
still requires a weighted FST, Telugu LM, code-switch policy, safety review, and a
user-separated benchmark before bundling.

Source and license: <https://huggingface.co/datasets/ai4bharat/Aksharantar#licensing-information>

## Telugu beta pack

`build_telugu_pack.py` compiles the reviewable five-row mobile layout JSON to a
binary property list, the Aksharantar training split to a compact Unicode-scalar
trie and sorted transliteration lexicon, and manifest-listed Telugu corpora to
compact bi/trigram records. It also projects native sentences through the best
attested Aksharantar forms and appends a Roman Telugu bi/trigram tail to `KBXL v3`.
Roman mode therefore has its own mmap prior and never falls through to English.
No Telugu glyph, conversion, vocabulary, or context table is generated from Swift.

Inspect the exact artifacts currently shipped by both targets:

```bash
python3 tools/language_packs/inspect_runtime_packs.py
```
The pack exposes separate `tenglish_to_telugu`, `roman_telugu`, and native `telugu`
input modes.

```bash
python3 tools/language_packs/build_telugu_pack.py \
  --layout tools/language_packs/sources/te-IN/apple-mobile-2020.json \
  --aksharantar tools/.cache/aksharantar_tel.zip \
  --corpus-manifest tools/language_packs/sources/te-IN/corpus-release-v1.json \
  --reviewed-core tools/language_packs/sources/te-IN/tenglish-core-reviewed.tsv \
  --output-dir keyboard \
  --max-words 22000 \
  --max-roman-keys 12000 \
  --max-variants 3 \
  --native-bigram-byte-budget 114688 \
  --native-trigram-byte-budget 114688 \
  --roman-bigram-byte-budget 49152 \
  --roman-trigram-byte-budget 49152 \
  --license-ack
python3 tools/language_packs/validate_manifest.py keyboard/telugu_pack_manifest.json
```

Every corpus entry is hash-pinned, source-capped, domain-tagged, weighted, and
labelled with release eligibility. The builder uses deterministic hash sampling,
so source ordering cannot determine starters when a cap is reached. Plain text,
JSONL, and Tatoeba TSV inputs can provide native Telugu or direct Roman Telugu
sentences. Unknown words break n-gram context instead of connecting unrelated
tokens across an OOV gap. See `corpus-manifest.schema.json`.

The native and Roman bi/trigram sections also have independent byte budgets. Within
each budget, contexts are retained by weighted evidence and each continuation list
is capped. A 15 GB source can therefore improve which records are selected without
silently increasing the extension artifact or resident heap.

### Preparing large Telugu corpora

Do not point the pack builder at raw web documents. `prepare_telugu_corpus.py`
streams local text, JSONL, or Parquet shards; splits documents into sentences;
rejects URLs, email addresses, phone-like strings, script-mixed rows, repetition,
and unreasonable lengths; deduplicates; and keeps a deterministic hash sample. The
output and every input shard are SHA-256 recorded in a reviewable report.

IndicCorpV2 publishes Telugu as one 15.76 GB text object. The range sampler takes
one deterministic, jittered byte range from each equal-size stratum, records every
range hash, and avoids downloading a biased prefix or the entire corpus:

```bash
python3 tools/language_packs/sample_hf_text_ranges.py \
  --repository ai4bharat/IndicCorpV2 --filename data/te.txt \
  --revision 2d7285e6ce14fdb3fb2449c9f89427b9f582ac3f \
  --source-bytes 15760603733 \
  --source-sha256 60693a4fd501b4a37ce57c76d6057a224fd6434bf6580eb134382cbe4ba1799a \
  --range-count 32 --range-bytes 1048576 \
  --output tools/.cache/indiccorpv2-te-ranges.txt \
  --report tools/.cache/indiccorpv2-te-ranges.report.json
```

```bash
python3 tools/language_packs/prepare_telugu_corpus.py \
  --input tools/.cache/sangraha/verified/tel/data-0.parquet \
  --format parquet --text-field text --language telugu \
  --source-id sangraha_verified_tel_0 \
  --max-sentences 150000 \
  --output tools/data/sangraha-tel-verified.txt.bz2 \
  --report tools/data/sangraha-tel-verified.report.json

python3 tools/language_packs/prepare_telugu_corpus.py \
  --input tools/.cache/sangraha/synthetic/tel_Latn/wiki_tel_Latn_0000_of_0063.parquet \
  --format parquet --text-field text --language roman_telugu \
  --source-id sangraha_synthetic_tel_latn_0 \
  --max-sentences 100000 \
  --output tools/data/sangraha-tel-latn.txt.bz2 \
  --report tools/data/sangraha-tel-latn.report.json
```

Dataset roles are deliberately separate:

- IndicCorpV2 (`tel_Telu`, CC0) and Sangraha Verified (`tel`, CC BY 4.0)
  are native-LM candidates. Their web/news domains receive lower weights than a
  future reviewed conversational corpus.
- Aksharantar training rows supply attested word transliterations. They do not
  provide sentence context.
- Sangraha `synthetic/tel_Latn` can bootstrap Roman Telugu context at low weight,
  but remains synthetic and must not be the blind evaluation source.
- Dakshina training text/lexicon can supplement native and attested Roman forms;
  its development and test sentences remain evaluation-only.
- Samanantar is parallel translation data and the public distribution is marked
  CC BY-NC 4.0. It is excluded from a commercial Release pack.
- MILU, IndicQuest, and IndicParam are benchmarks; IndicVoices and Kathbath are
  speech data. None belongs in the tap-prediction training stream.

The tracked pack combines the 318-sentence Tatoeba bootstrap with a deterministic,
hash-pinned 100,000-sentence stratified sample of IndicCorpV2 Telugu. It contains
22,000 native words, 12,000 Roman keys, and 20,028 weighted transliteration mappings.
That is enough to make native and Roman context tables useful, but its predominantly
web/news register is not a substitute for conversational data or a user-separated
quality benchmark. Add Dakshina/Sangraha-derived training sources only after their
exact split, redistribution terms, source revision, and domain cap are recorded. A
source marked `researchOnly` can build an internal pack, but the Release artifact
verifier rejects it.

### Runtime residency and downloadable packs

All three runtime dictionaries are opened with Foundation's read-only mapped-data
option. Tenglish and Telugu use lazily initialized process-wide readers, so opening
the English keyboard does not parse or copy either Indic pack into heap memory.
Sorted fixed-width n-gram records are searched in place; no decompressed dictionary
or hash table is retained. The current bundled inventory is 60,450 English words
(9,391,297 bytes), 22,000 Telugu words (1,918,563 bytes), and 12,000 Roman keys /
20,028 mappings (967,207 bytes), for 12,277,067 dictionary bytes total.

Do not make On-Demand Resources the only source for an iOS 18 keyboard extension.
The host controls extension lifetime, and a keyboard must remain usable when the
companion app has never fetched an optional asset. Keep compact mapped fallbacks in
the extension. Future larger packs should be downloaded by the companion app,
verified against a signed manifest, atomically installed into the App Group, and
rolled back to the bundled pack on any failure. Background Assets can replace that
delivery layer only when the deployment floor permits it.

The schema-v2 manifest remains `research`: the five-row arrangement was captured
from a current Apple Telugu keyboard reference and cross-checked against Unicode,
but it cannot become release-eligible until a native speaker approves it and a
user-separated Telugu benchmark is attached by hash.
