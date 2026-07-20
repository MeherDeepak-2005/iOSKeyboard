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
  --license-ack
python3 tools/language_packs/validate_manifest.py keyboard/telugu_pack_manifest.json
```

Every corpus entry is hash-pinned, source-capped, domain-tagged, weighted, and
labelled with release eligibility. The builder uses deterministic hash sampling,
so source ordering cannot determine starters when a cap is reached. Plain text,
JSONL, and Tatoeba TSV inputs can provide native Telugu or direct Roman Telugu
sentences. Unknown words break n-gram context instead of connecting unrelated
tokens across an OOV gap. See `corpus-manifest.schema.json`.

The tracked manifest intentionally contains only the small Tatoeba bootstrap. Its
318 sentences are enough to validate the complete binary/runtime path but not to
claim production Telugu quality. Add pinned Dakshina/Sangraha-derived training
sources only after their exact split, redistribution terms, source revision, and
domain cap are recorded. A source marked `researchOnly` can build an internal pack,
but the Release artifact verifier rejects it.

The schema-v2 manifest remains `research`: the five-row arrangement was captured
from a current Apple Telugu keyboard reference and cross-checked against Unicode,
but it cannot become release-eligible until a native speaker approves it and a
user-separated Telugu benchmark is attached by hash.
