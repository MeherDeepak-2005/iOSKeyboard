> Historical baseline report: measured before the English expansion. See [implementation results](docs/english-vocabulary/IMPLEMENTATION_RESULTS.md) for the integrated pack and validation.

# Xploree English vocabulary coverage and expansion plan

Research and local audit date: **6 October 2026**. Scope: English used internationally, including formal writing, literature, everyday communication and texting. This is an investigation and implementation plan; no vocabulary, model weights or production behavior was changed.

## Recommendation

Expand the existing vocabulary in two steps: first repair common regional spellings, everyday inflections and established modern terms; then introduce a larger, compact recognition vocabulary with separate permissions for suggestions and automatic corrections. Improve contextual evidence alongside the word list. Merely adding rare words will not produce respectful phrasing, reliable next-word predictions or better typo correction.

Start with **ESDB regional exports, Open English WordNet and a reviewed project-owned vocabulary**. Add **MASC/OANC and refreshed Tatoeba CC0** for contextual evidence. Use **Wiktionary/Kaikki** selectively for regional and informal terms, with its attribution/share-alike obligations preserved. Consider **COCA and GloWbE** after securing the appropriate commercial embedded-data rights. Their academic or ordinary download access must not be treated as permission to distribute a derived keyboard dictionary.

There is substantial room for improvement, but an exact percentage behind Gboard, Apple or SwiftKey is not established. Their complete, version-matched dictionary inventories were not available in the official materials examined, and no competitor device experiment was run. Published capabilities and measured Xploree gaps are distinguished below.

## Evidence and measurement boundaries

The audited artifact is this checkout's [English language pack](/Users/meherdeepak/iOSKeyboard/keyboard/langdata.bin), matching [ARTIFACTS.json](/Users/meherdeepak/iOSKeyboard/ARTIFACTS.json). Its identity has **not** been matched against the currently distributed App Store application. Thus, “current” below means the repository's bundled pack, not an independently inspected App Store installation.

The [machine-readable audit](/Users/meherdeepak/iOSKeyboard/docs/english-vocabulary/coverage-audit-2026-10-06.json) records every probe, frequency, source tier and bigram status. The [complete probe inventory](/Users/meherdeepak/iOSKeyboard/docs/english-vocabulary/PROBE_RESULTS.md) lists all tested forms, grouped by presence and contextual evidence. The [read-only audit utility](/Users/meherdeepak/iOSKeyboard/tools/evaluation/audit_english_coverage.py) reads local artifacts and emits JSON; it never downloads or builds dictionaries. Reproduce from the repository root with:

```sh
python3 -B tools/evaluation/audit_english_coverage.py
```

Four measurements must remain separate:

| Measurement | Meaning | Status in this report |
|---|---|---|
| Surface-form coverage | Whether a particular normalized word is in the bundled vocabulary | Measured across the pack and targeted probes |
| Corpus token coverage | Fraction of running tokens recognized | Measured on the existing build corpus only |
| Candidate recall / correction quality | Whether the intended word is retrieved, ranked and committed correctly | Requires decoder replay; dictionary membership alone is insufficient |
| Competitive quality | Same input, context, locale and personalization state across keyboards | Device experiment planned; no results claimed |

An inflected form is an entry, not necessarily a different lemma. A corpus token is an occurrence, not a distinct word. Neural subword vocabulary sizes and dictionary surface-form counts are not comparable.

## Current dictionary audit

### Pack size and contextual evidence

| Property | Measured value | Consequence |
|---|---:|---|
| Format | KBLM v5 | Packed word IDs and n-gram references |
| Word forms | 60,450 | Includes inflections, contractions and names |
| File size | 9,391,297 bytes / 8.96 MiB | Dictionary storage, not total extension RAM |
| Trie nodes | 145,386 | Search work depends on branches visited, not just word count |
| Bigram contexts / entries | 28,949 / 239,287 | Direct observed continuation evidence is uneven |
| Trigram contexts / entries | 217,418 / 384,691 | These are context records, not unique vocabulary additions |
| Words without an outgoing bigram context | 31,501 / 52.11% | No observed next-word distribution after these words |
| Words without any incoming or outgoing bigram role | 29,586 / 48.94% | Still have unigram evidence; this is not a decoder failure count |
| Cold-start words | 20 | Explicit product priors |
| Current builder maximum | 65,534 word forms | Only **5,084 additional slots** without changing the format/architecture |
| Existing release file cap | 11,000,000 bytes | 1,608,703 bytes of file headroom, independently of ID headroom |

SHA-256: `a5accdb6100bf782637b91b522a33af20d199e7c85cc39e9a0da21ff4cbfc0d8`.

The word limit is the current builder's explicit guard. The file cap comes from [verify_release_artifacts.py](/Users/meherdeepak/iOSKeyboard/tools/verify_release_artifacts.py:12); it is a project release policy, not an Apple memory limit. Adding 5,084 words is not guaranteed to fit: trie nodes and contextual records also consume storage.

### How the present pipeline loses useful vocabulary

The [builder](/Users/meherdeepak/iOSKeyboard/tools/build_language_data.py:170) scans a pinned **2018 FrequencyWords English list**, admits words validated by an **American-English ESDB size-60/70 snapshot**, then stops at 60,000 base entries. Size-70 words need a higher frequency threshold. It subsequently merges the 40-entry [supplement](/Users/meherdeepak/iOSKeyboard/tools/data/english_supplemental.tsv) and harvested contractions.

This creates three bottlenecks: US-only validity selection, an old frequency source controlling admission, and a hard base-list cutoff. An otherwise valid word can be rejected because its spelling is regional, because it lacks sufficient evidence in the 2018 list, or because it falls below the selection cutoff. These mechanisms are verified; attributing each individual rejection to one exact gate would require the unavailable local FrequencyWords cache.

The already-vendored ESDB snapshot contains **163,933 normalized forms**. Of these, **103,528 are absent** from the pack: 49,990 from tier 60 and 53,538 from tier 70. Among the missing forms, 82,324 have no apostrophe and 21,204 contain one. This is a source-minus-pack count, **not 103,528 approved additions**: rare forms, possessives, abbreviations and unsuitable candidates still require filtering. It nevertheless shows that useful expansion does not depend entirely on acquiring new data.

The [snapshot normalizer](/Users/meherdeepak/iOSKeyboard/tools/build_esdb_snapshot.py:30) folds through ASCII, while the builder admits only `a–z` and apostrophes. Accented display forms, hyphenated forms and digit-containing texting forms need explicit representation support. Putting them into a TSV alone will not solve their coverage.

### Targeted diagnostic probes

The audit contains **478 distinct normalized probe keys**, grouped below. Categories can overlap. These lists were deliberately chosen to expose gaps, partly from previously identified examples; **their percentages must not be presented as representative English coverage or competitor recall**. Regional or colloquial entries are candidates for review, not universal spelling recommendations.

| Category | Tested | Present | Missing | Present but no outgoing bigram | Interpretation |
|---|---:|---:|---:|---:|---|
| Common controls | 33 | 33 | 0 | 0 | Core everyday vocabulary is represented |
| Regional spellings | 55 | 5 | 50 | 1 | Clear international spelling gap |
| International English usage | 44 | 21 | 23 | 15 | Uneven regional vocabulary and evidence |
| Formal / academic | 58 | 36 | 22 | 7 | Common courtesy words fare better than specialized academic forms |
| Literary | 30 | 21 | 9 | 13 | Some terms recognized but sparsely contextualized |
| Everyday inflections | 44 | 12 | 32 | 5 | Missing productive, useful word families |
| Texting / slang | 76 | 40 | 36 | 32 | Recent curated slang exists; several established acronyms do not |
| Modern / technical | 52 | 15 | 37 | 7 | Significant gaps in current everyday technology language |
| International names / places | 45 | 28 | 17 | 13 | Recognition needs a separate proper-name policy |
| Orthography / contractions | 43 | 30 | 13 | 12 | Includes intentional exclusions and unsupported characters |

| Gap | Confirmed missing examples | Useful controls / qualifications |
|---|---|---|
| Regional spelling | `colour`, `favourite`, `organise`, `centre`, `travelling`, `cancelled`, `litre`, `acknowledgement` | Do not automatically replace a user's established regional spelling |
| Regional usage | `prepone`, `outstation`, `batchmate`, `brekkie`, `braai`, `jollof`, `jeepney` | `lakh`, `crore`, `chai` already exist; qualify region/register and validate local usage |
| Academic | `delineate`, `epistemology`, `reproducibility`, `heterogeneity`, `metacognition` | `please`, `respectfully`, `sincerely`, `gratitude` are present |
| Literary | `synecdoche`, `metonymy`, `enjambment`, `bildungsroman`, `numinous` | Rare terms should usually be recognized without becoming strong automatic replacements |
| Inflections | `unsubscribed`, `unsubscribing`, `screenshots`, `screenshotting`, `livestreaming`, `unmuting` | `unsubscribe`, `screenshot`, `rescheduled`, `rescheduling` are present |
| Texting | `brb`, `ttyl`, `ikr`, `omw`, `nvm`, `tysm`, `lmao` | `idk`, `tbh`, `ngl`, `rizz`, `delulu`, `iykyk` exist; slang with profanity remains subject to existing suggestion policy |
| Technology / contemporary | `covid`, `coronavirus`, `chatbot`, `tokenization`, `webhook`, `passkeys`, `deepfake` | `bluetooth`, `autocorrect`, `passkey` exist |
| Names / places | `bengaluru`, `telangana`, `visakhapatnam`, `tirupati`, `ananya`, `aditya`, `aoife` | `bangalore`, `hyderabad`, `vijayawada` exist; display capitalization is another concern |
| Written forms | `café`, `naïve`, `résumé`, `co-operate`, `e-mail`, `wi-fi` | ASCII counterparts exist; preserve distinctions such as résumé/resume |

`dont`, `im`, `youre` and `cant` in the last category are **deliberate builder exclusions**, not evidence that the source dictionary forgot them. `u`/`r` and forms such as `gr8` hit existing single-letter/character policies. Expanding casual recognition should not silently disable the desired `dont → don't` correction or make `ur` an automatic replacement for `your`.

### Corpus coverage and phrase gaps

Using the exact build tokenizer and its 128-token sentence limit, the local CC0 corpus contains 41,502 sentences, 572,779 tokens and 39,060 distinct token types. The pack recognizes **559,995 tokens (97.768%)**, but misses **8,107 types**: type coverage is **79.245%**. These are **in-sample measurements on the source already used to build the language model**, not independent quality results.

The OOV count mixes real gaps with tokenization artifacts and source bias. Examples include `covid` (91 occurrences), `coronavirus` (61) and `favourite` (17), but also `s` (593), `u` (499) and repeated proper names. Do not ingest the most frequent OOV list wholesale.

All component words in the following phrases are present. The audit checks stored adjacent n-grams, not actual suggestion ranking:

| Phrase | Observed adjacent bigrams | Observed adjacent trigrams | Implication |
|---|---:|---:|---|
| `kind regards` | 0/1 | Not applicable | Courtesy vocabulary exists; direct phrase evidence does not |
| `yours sincerely` | 0/1 | Not applicable | Same gap |
| `thank you for your consideration` | 3/4 | 2/3 | Partial phrase support |
| `could you please clarify` | 2/3 | 1/2 | Partial phrase support |
| `i appreciate your help` | 3/3 | 0/2 | Bigram support without the observed three-word contexts |
| `please let me know` | 3/3 | 2/2 | Positive control |
| `statistically significant` | 0/1 | Not applicable | Academic collocation gap |
| `no worries` | 0/1 | Not applicable | Casual phrase gap |

Backoff or personalization can still produce a missing observed phrase. Conversely, a stored phrase does not establish tone awareness. “Respectful English” requires phrase evaluation and context/register handling; it is not a distinct list of sophisticated words.

## Comparison with Gboard, Apple and SwiftKey

| Product | What official evidence establishes | Difference relevant to Xploree | What remains unmeasured |
|---|---|---|---|
| Gboard | Google describes discovering out-of-vocabulary words and updating language models. Its 2025 confidential analytics account explicitly discusses the Android app. [Vocabulary discovery](https://research.google/blog/improving-gboard-language-models-via-private-federated-analytics/), [2025 production account](https://research.google/blog/discovering-new-words-with-confidential-federated-analytics/). | Xploree's dominant admission frequency source is static 2018 data with a small manual supplement. It needs a repeatable vocabulary refresh process. | Complete English inventory, exact regional word membership, and whether each Android research feature exists in Gboard for iOS |
| Apple keyboard | Apple documents predictions informed by prior conversations and writing style. Its current feature matrix lists multiple regional English variants. [Prediction behavior](https://support.apple.com/en-au/104995), [QuickType availability](https://www.apple.com/ios/feature-availability/). | Xploree's US-filtered base lacks common regional forms and has sparse phrase evidence. These are concrete areas to test against Apple's regional modes. | Actual recognition/correction of each probe, full dictionary size, personalization behavior on the user's device |
| Microsoft SwiftKey | Its iOS language list includes English for Australia, Canada, India, UK and US; the prediction bar learns new words from use. [Languages](https://support.microsoft.com/en-au/swiftkey-keyboard/what-languages-are-currently-supported-for-microsoft-swiftkey-keyboard), [Learning behavior](https://support.microsoft.com/en-us/swiftkey-keyboard/how-does-the-microsoft-swiftkey-prediction-bar-work). | Regional support and learning should be first-class evaluation axes. Xploree's adoption and next-word pathways currently differ for static and newly learned words. | Complete lexicon, word-by-word advantage, and a controlled learning-speed comparison |

Apple's live availability page was labeled iOS/iPadOS 27 when accessed. It must not be used as evidence of a feature on an older test device. Likewise, [Gboard's iOS language configuration](https://support.google.com/gboard/answer/7068494?hl=en&co=GENIE.Platform%3DiOS) does not establish Android/iOS decoder equivalence.

The [Gboard Neural Search Space paper](https://aclanthology.org/2024.emnlp-industry.93/) describes a decoding approach, not a downloadable copy of the complete shipped Gboard dictionary. A research model's vocabulary size cannot establish whether Xploree knows more or fewer useful words. NSS may improve context-sensitive search, but it cannot by itself repair Xploree's source selection, orthography filters, licensing or missing contextual training evidence. The current neural integration also applies known-word constraints. Keep NSS as a separate experiment after vocabulary and decoder parity work.

**Extent established:** Xploree has systematic regional, inflectional, contemporary and contextual gaps, directly evidenced above. **Extent not established:** “X% fewer words than Apple” or “Y% worse recall than Gboard.” Claims like those require a common device benchmark, not assumptions about proprietary word lists. An AOSP/LatinIME list would not substitute for current Gboard's inventory.

## Source acquisition plan

The following are source candidates, not instructions to merge everything. Source totals are not net additions. Exact incremental counts for newly acquired sources remain unknown until normalization, overlap analysis and editorial filtering. Examples describe the intended coverage class; they are not claims that every named source contains every example.

### What to obtain and where

| ID / priority | Source and download path | Exact scope to acquire | Coverage purpose and published scale |
|---|---|---|---|
| S1 / First | [English Speller Database](https://github.com/en-wl/wordlist), [existing pinned revision](https://github.com/en-wl/wordlist/tree/1e5b7d3a72f47a71da5d28686c1dd4b397178485) | Source archive/checkout at a pinned revision; export size 60 and selected 70 for American, British `-ise` and `-ize`, Canadian and Australian variants. Keep metadata. Do not start with the largest rare-word tiers. | Regional spellings and attested inflections. Existing US snapshot already has 103,528 forms absent from the pack, before product filtering. |
| S2 / First | [Open English WordNet releases](https://github.com/globalwordnet/english-wordnet#releases), [2025 core LMF XML gzip](https://en-word.net/static/english-wordnet-2025.xml.gz) | Complete **2025 core** lexical file. Skip Plus/Namenet initially. Extract entries and available forms; do not embed definitions or the whole semantic graph. | Formal, literary and specialist lexical validation. Published core contains 135,969 words, including entries that will overlap or be unsuitable. |
| S3 / Second | [Kaikki raw Wiktionary extraction](https://kaikki.org/dictionary/rawdata.html) | Current **compressed raw English-edition JSONL**; stream-filter `lang_code == "en"`. This edition contains many languages, so English filtering is mandatory. Skip audio, templates, Lua and deprecated post-processed language files. | Regional labels, contemporary slang, abbreviations and inflections. Raw archive includes much more than keyboard vocabulary. |
| S4 / Optional weighting | [wordfreq repository](https://github.com/rspeer/wordfreq) | Pinned source/package, notices and normalization code; use only English `large` frequencies through the library's API. Do not ship other languages or export an attribution-free flat word list. | Cross-domain frequency evidence for validated candidates. Data is a snapshot through about **2021**, not a current trend feed. |
| S5 / First, contextual | [MASC data-only download](https://anc.org/data/masc/downloads/data-download/), [OANC download](https://anc.org/data/oanc/download/) | MASC **500K UTF-8 text, data-only ZIP/TGZ** as the pilot. Then current OANC GrAF distribution; retain text and genre/document metadata, skip unnecessary annotations. Avoid counting overlapping MASC/OANC documents twice. | Diverse conversational and written evidence. MASC spans 19 genres; OANC is roughly 15 million words. |
| S6 / First, contextual | [Tatoeba downloads](https://tatoeba.org/en/downloads) | Select **Sentences (CC0) → English**. Full selected English CC0 export, not all languages or all licenses. No translations/audio needed. Keep the old snapshot as a reproducible baseline. | Sentence evidence and contractions; incremental coverage depends on new English contributions, not a promised larger lexicon. |
| S7 / Conditional commercial | [COCA file descriptions](https://www.wordfrequency.info/files.asp), [commercial acquisition](https://www.wordfrequency.info/purchase.asp) | Prefer `words_219k.txt`, `lemmas_60k_words.txt`, `lemmas_60k.txt`; optional `lemmas_60k_subgenres.txt`. COCA is already English. Start with these tables, not the entire corpus. | Approximately 220K observed forms, lemma/form links and genre frequencies; useful for academic and general writing. |
| S8 / Conditional commercial | [GloWbE corpus catalog](https://www.english-corpora.org/corpora.asp?o=y), [full-text formats/download entry](https://www.corpusdata.org/formats.asp) | Pilot the 2.1M-word sample. If licensed, select country/document subsets from one word/lemma/POS distribution plus source metadata. Initial regions: India, UK, US, Canada, Australia, NZ, Singapore, South Africa and Nigeria. Confirm vendor packaging; selective extraction may still require the full archive. | Regional English from 20 countries; about 1.9 billion words in the corpus, collected 2012–2013. Useful for regional patterns, not current slang trends. |
| S9 / Optional literary | [Project Gutenberg permitted acquisition routes](https://www.gutenberg.org/policy/robot_access.html), [catalog access](https://www.gutenberg.org/ebooks/offline_catalogs.html) | Curate 100–300 English books/essays with eligible rights in target territories. Obtain plain UTF-8 text through permitted harvest/mirror routes. Skip images, EPUB duplicates and the full library. | Literary words and phrasing; historical material needs archaic-spelling and author-bias controls. |
| S10 / Optional academic | [PMC Open Access subset](https://pmc.ncbi.nlm.nih.gov/tools/openftlist/), [current AWS download instructions](https://pmc.ncbi.nlm.nih.gov/tools/pmcaws/) | Filter current inventory/metadata for English **CC0 or CC-BY** articles; initially cap at 1,000–5,000 articles. Download JATS XML and required metadata, not PDFs/media/supplements. | Contemporary scientific and medical vocabulary, including morphology. This supplements academic English; it is not a balanced general academic corpus. |
| S11 / Optional place layer | [GeoNames downloads and schema](https://download.geonames.org/export/dump/), [cities15000.zip](https://download.geonames.org/export/dump/cities15000.zip) | Start with cities15000, country information and English administrative names. For language-qualified aliases use `alternateNamesV2.zip`, join only selected place IDs and English aliases. Skip allCountries initially. | International city/place names. Separate them from common-word correction priors; this does not provide personal given names. |
| S12 / Rights unresolved | [NUS SMS author repository](https://github.com/kite1988/nus-sms-corpus), [English XML ZIP](https://github.com/kite1988/nus-sms-corpus/blob/master/smsCorpus_en_xml_2015.03.09_all.zip) | English XML archive dated 2015-03-09 only. Skip Chinese, SQL and third-party JSON duplicates. Obtain explicit reuse terms before production integration. | 55,835 historical English SMS messages; useful for short forms and conversational patterns, not 2026 trend coverage. |
| S13 / Reference; conditional | [BNC2014 access](https://cass.lancs.ac.uk/bnc2014/), [Spoken XML portal](http://corpora.lancs.ac.uk/bnc2014/) | Spoken XML only if the intended use is permitted. Written corpus access is through approved tools; its full texts are not available for general download. | Contemporary British conversation/reference evidence. Current public access is described as non-commercial research. |
| S14 / First, owned | Existing [English supplement](/Users/meherdeepak/iOSKeyboard/tools/data/english_supplemental.tsv); future editorial and explicitly consented contributions | No external corpus download. Commission reviewed regional terms and short-message/courtesy examples. Initial review workload: 500–2,000 candidate terms and 1,000–2,000 original phrase examples. | Fast response to product-specific omissions and current language; quantities are proposed collection targets, not measured net additions. |

### Download and preparation time estimates

Assumptions: **100 Mbps connection achieving 50 Mbps sustained payload = 6.25 MB/s**. Decimal MB/GB. Transfer estimate is `bytes × 8 / effective bits per second`; 1 GB takes about 2.7 minutes, 10 GB about 26.7 minutes. A connection achieving only 5 Mbps takes roughly ten times as long. Practical ranges below allow server/connection overhead, but are not measured downloads.

**Published** means a size stated by the source page; **budget** means an unverified planning envelope that must be replaced with the selected file's actual size. Compute times assume a modern laptop, streaming parsing and local SSD. They exclude adapter development, editorial review and legal/access negotiations.

| Source | Transfer volume basis | Practical download estimate | Local extraction/analysis estimate | Access delay / important qualification |
|---|---|---|---|---|
| S1 ESDB | **Budget:** 10–50 MB source archive | 1–3 min; local snapshot needs no download | 2–15 min | No account expected; pin revision and notices |
| S2 WordNet | **Budget:** 10–30 MB compressed core XML | 1–3 min | 1–10 min | Exact selected release size to verify |
| S3 Kaikki | **Published:** 2.8 GB compressed, 23.9 GB raw English-edition extraction | 8–20 min; theoretical transfer about 7.5 min | 10–60 min streaming English selection | Weekly-changing file; record dump/extractor dates and hash; reserve ~30 GB if retaining expanded raw data |
| S4 wordfreq | **Budget:** 30–70 MB package/source acquisition | 1–3 min | 1–5 min English iteration | Snapshot age remains ~2021 even if packaging changes |
| S5 MASC → OANC | **Budget:** MASC 2–10 MB; current OANC 100–500 MB. Source separately publishes **326 MB for the older XML archive**, not the current GrAF ZIP. | 1–2 min / 1–5 min | 1–5 min / 5–30 min | Inspect archive notices and exact current sizes; page reports ~4.8 GB unpacked OANC |
| S6 Tatoeba English CC0 | **Budget:** 1–10 MB compressed selected export | 1–2 min | 1–5 min | Weekly export; choosing all English sentences changes the license scope |
| S7 COCA tables | **Budget:** 20–150 MB for selected tables | 1–3 min after access | 2–15 min | Purchase/delivery and negotiated distribution rights: duration unknown |
| S7 alternative full COCA | **Conditional budget:** 2–10 GB for one compressed format; actual vendor size unverified | 6–40 min if within that budget | 1–4 hr for parsing/counting | Not recommended first. Do not promise “3 hours to download”; formats and delivery differ |
| S8 GloWbE | **Budget:** 10–100 MB sample; 5–20 GB if a full distribution is needed | 1–3 min sample; 15–75 min full, conditional on size | 5–15 min sample; 1–6 hr full | Country subsets may reduce processing but not purchase/download size; rights duration unknown |
| S9 Gutenberg | **Budget:** 50–300 MB for curated selection, plus catalog if used | 5–30 min | 10–60 min | Small-file request pacing can dominate transfer; per-title territorial review is separate |
| S10 PMC selected articles | **Budget:** 0.1–1 GB selected XML, plus inventory overhead not yet sized | 5–45 min | 10–60 min | Many objects/request throttling dominate; use current documented services |
| S11 GeoNames | **Published:** cities15000 ~3.2 MB; optional alternateNamesV2 ~195 MB | 1–2 min / 1–5 min | 1–10 min | Pin snapshot because files change daily |
| S12 NUS SMS | **Published:** English XML ZIP 2,359K | Under 1 min to 2 min | 1–5 min | Rights clarification has no verified turnaround |
| S13 BNC2014 | Spoken XML size not verified; **budget 100–500 MB**, conditional | 1–5 min once available, if within budget | 5–30 min | Registration/license; written full-text download unavailable; commercial permission unresolved |
| S14 Owned additions | No external download | Not applicable | Minutes for import after review | Proposed editorial/collection cycle: 2–6 weeks, depending on reviewer capacity |

The acquisition tables deliberately separate bytes from word counts. COCA's downloadable full text is listed as about 950M words, while its frequency tables refer to a roughly 1B-word corpus; neither number specifies compressed download size. [COCA formats](https://www.corpusdata.org/formats.asp).

### Reuse conditions for an App Store product

| Source | Publicly stated terms / uncertainty | Required treatment in this plan |
|---|---|---|
| ESDB | MIT-like combined work, constituent notices. [Copyright](https://github.com/en-wl/wordlist/blob/v2/Copyright). | Retain authoritative notices and pinned source provenance |
| Open English WordNet | CC-BY 4.0. [Project](https://en-word.net/). | Attribute release/contributors; preserve transformation record |
| Wiktionary / Kaikki | Wiktionary text has attribution/share-alike requirements; external quotations/media can have different rights. [Copyright information](https://en.wiktionary.org/wiki/Wiktionary:Copyrights). | Keep entry attribution and applicable license; extract lexical metadata, not quoted literary examples; keep the derived-data distribution arrangement explicit |
| wordfreq | Apache code; CC-BY-SA 4.0 data plus source credits. Maintainer discourages stripped flat-list redistribution. [License and conversion guidance](https://github.com/rspeer/wordfreq#license). | Preserve library semantics, attribution and data terms. Prefer evaluation/calibration first; do not casually relabel exported frequencies project-owned |
| OANC / MASC | Project explicitly permits commercial use and redistribution. [Open ANC terms](https://anc.org/data/oanc/). | Archive the exact distribution notices and source IDs; distinguish requested community contributions from mandatory terms |
| Tatoeba CC0 | Only part of Tatoeba is CC0; broader sentence exports use CC-BY 2.0 FR. [Download terms](https://tatoeba.org/en/downloads). | Use the explicit CC0 English export for the first update |
| COCA tables | The commercial checkout says the license prevents giving data to others outside the company; it does not establish permission for the proposed embedded redistribution. [Commercial license process](https://www.wordfrequency.info/purchase1.asp?i=w60c). | Obtain terms covering embedded transformed forms/frequencies before including them in a distributed pack |
| COCA full text / GloWbE | Full-text terms restrict external distribution and derived frequencies/ngrams; academic licenses exclude sold products. [Restrictions](https://www.corpusdata.org/restrictions.asp). | Obtain a specific commercial grant/waiver for the proposed embedded artifacts. The allowance for coarse frequency bands is not blanket permission to distribute a large word list |
| Gutenberg | US public-domain status does not establish worldwide status; some titles have additional conditions. [License](https://www.gutenberg.org/policy/license.html). | Per-title rights and territory selection, source notices, permitted download routes |
| PMC | Rights vary article by article. [OA subset](https://pmc.ncbi.nlm.nih.gov/tools/openftlist/). | Allowlist CC0/CC-BY and verify article metadata; exclude NC/ND/unknown terms from this initial commercial pipeline |
| GeoNames | CC-BY 4.0. [Distribution readme](https://download.geonames.org/export/dump/). | Attribution, snapshot identity and filtered alias provenance |
| NUS SMS | The inspected author repository provides downloads/citation instructions but no explicit general commercial redistribution grant. | Treat as conditional; request documented rights before ingestion. No author was contacted in this task |
| BNC2014 | Public access described as non-commercial research; written full texts cannot currently be released. [Access terms](https://cass.lancs.ac.uk/bnc2014/). | Reference-only where permitted; no production injection until a suitable separate permission is obtained |
| Owned contributions | Rights must come from original authors/contributors | Record contribution permission; avoid copying proprietary dictionaries or collecting private typed messages without explicit consent |

Keep rights records source-specific. Combining a permissive source with share-alike or contract-restricted data does not erase the latter's conditions. The current FrequencyWords-derived pack already has [CC-BY-SA provenance](/Users/meherdeepak/iOSKeyboard/THIRD_PARTY_NOTICES.md:66); expansion should preserve and review that existing arrangement rather than assume the baseline is unrestricted.

## Source-by-source decoding and injection plan

Every adapter below is **proposed**, not implemented. No external corpus is loaded by the keyboard at runtime. Extraction happens offline, produces reviewable records, and enters the common merge/export pipeline described next.

| Source | Decode and isolate useful records | Inject into the current/future dictionary | Coverage contribution and rejection rules |
|---|---|---|---|
| S1 ESDB | Build the pinned SQLite database; export regional size-60/70 records with lemma, POS, inflection and dialect metadata. Compare each dialect against the current US snapshot. Preserve accents in source records. | Feed attested forms into the validity catalog. Select high-value ASCII forms for the first v5 build; retain remaining valid forms for the later recognition layer. | Regional spelling families and missing inflections. Do not require every new valid form to appear in the 2018 frequency list. Gate tier-70 rarity separately; do not generate every conceivable suffix. |
| S2 WordNet | Stream LMF XML; extract lexical entries, written forms and POS. Deduplicate senses sharing the same form; separate multiword expressions. | Supply additional lexical validity. Join to usage evidence before promotion to correction vocabulary; put specialist long-tail forms in recognition. | Academic/literary terms. Synset counts are not frequency; synonyms must not become automatic substitutions for correctly typed words. |
| S3 Kaikki | Stream gzip JSONL and retain English records; inspect lemma/form links, POS, senses and tags. Normalize schema through the documented [Wiktextract format](https://github.com/tatuylonen/wiktextract). Keep regional, informal, archaic and offensive labels. | Emit source-attributed term/alias candidates and register metadata. Review contemporary terms; defer multiword and non-ASCII outputs to supported pathways. | Slang, abbreviations, regional usage and newer terminology. Reject vandalism, unattested strings and template debris; recognition and automatic suggestion eligibility differ. |
| S4 wordfreq | Query English frequencies using the pinned library's normalization. Keep its credits with generated calibration artifacts. | Use as one frequency feature alongside independent validity and held-out evaluation. | Better weighting for some candidates, not proof of correct spelling; avoid double-counting overlapping subtitle/web sources. |
| S5 MASC/OANC | Parse text plus document/genre metadata. Respect sentence boundaries; deduplicate documents and cap each author's/document's contribution. Split holdouts before counting. | Admit independently validated OOV forms; produce genre-aware unigram and sentence-bounded n-gram counts. Keep training data separate from evaluation. | Formal and everyday phrase evidence. Reserve some genres/documents for held-out testing; do not use all MASC both for training and evaluation. |
| S6 Tatoeba | Decode the four-column CC0 TSV: sentence ID, language, text, modification date. Verify `eng`, normalize apostrophes, retain IDs, deduplicate exact/near-duplicate sentences. | Refresh the pinned source only after delta review. Rebuild counts with the expanded vocabulary so previously OOV words can receive context evidence. | Incremental sentences and contractions. Repeated character names and translation-style sentences must not determine global frequency or cold-start suggestions. |
| S7 COCA tables | Read tabular files according to their supplied headers; join lemma/POS to observed surface forms. Use genre frequencies, document range, dispersion and capitalization evidence. | Import only licensed fields. Map calibrated frequency/band features into the approved build representation; promote validated academic/everyday forms. | Wider observed morphology and register evidence. A lemma list alone misses inflections; tables alone do not provide sentence context. [Column definitions](https://www.wordfrequency.info/files.asp). |
| S7 COCA full-text option | Use one word/lemma/POS format, keep document boundaries and source genre. Reconstruct contractions such as split `ca n't` using explicit rules. Break at redactions/missing spans. | Count licensed, source-balanced contexts offline, then merge probabilities/counts under the approved weighting design. | Phrase evidence if needed after the tables pilot. Never manufacture n-grams by joining across omissions. [Format notes](https://www.corpusdata.org/formats.asp), [omission policy](https://www.corpusdata.org/limitations.asp). |
| S8 GloWbE | Join text IDs with country metadata; language-filter document content, remove boilerplate and near-duplicate web pages. Normalize source tokenization with the same contraction safeguards as COCA. | Build regional usage features and approved regional vocabulary deltas; blend country distributions without letting US volume dominate. | Indian, African, Southeast Asian and other English usage. Country of a site is imperfect evidence of author dialect; no native-language transliteration expansion is intended. |
| S9 Gutenberg | Decode UTF-8, retain book/author/year/rights IDs; remove license/header/footer text from linguistic counts while retaining provenance. Split by book/author; identify archaic forms. | Add validated literary terms chiefly to recognition; give literary contexts a small, tuned contribution to general scoring. | Literary coverage and collocations. Do not make historical spelling or a prolific author's style the default for modern messages. |
| S10 PMC | Read inventory and article metadata, verify language/license, then stream JATS paragraphs. Exclude references, author lists, formulas, identifiers and extraction debris; retain paragraph/sentence boundaries. | Supply academically validated term candidates and a capped science-domain context stream. | Modern scientific vocabulary and inflections. Avoid brand names, gene strings and one-paper acronyms becoming general autocorrect targets. |
| S11 GeoNames | Parse UTF-8 TSV; join place IDs and English aliases using language codes. Keep display case, region, population and preferred/historical flags. Do not assume every ASCII transliteration is an English name. | Export a small curated place set initially; later a separate compact entity-recognition layer with prefix completion and conservative correction eligibility. | Place names and alternate city spellings. Population is a relevance feature, not a language frequency count; no person-name database is implied. |
| S12 NUS SMS | After rights clearance, parse message XML; preserve short forms while filtering identifiers/URLs and residual private data. Deduplicate and split by contributor where available. Manually separate legitimate variants from typos. | Produce reviewed informal candidates and capped messaging n-grams. Keep original and normalized views separate; do not expand all acronyms in emitted text. | Established texting conventions. Historical forms require current review; noisy spellings should not be admitted simply because someone typed them. |
| S13 BNC2014 | Only after suitable permission, parse spoken XML by utterance/speaker and retain boundaries; exclude transcription markup and nonlexical events. | Use permitted records for conversational validity/contexts. If rights remain research-only, keep it outside production artifacts. | British conversational usage. Do not plan to scrape the restricted written corpus. |
| S14 Owned additions | Review original records with term, display form, locale, register, examples and contributor permission. Have regional reviewers adjudicate disputed usage. | Small accepted ASCII additions can use the existing supplement first; later export richer flags and original context examples through the common pipeline. | Immediate gaps and new language. LLM suggestions may generate review candidates, but are not evidence of real usage and should not become synthetic “observed frequencies.” |

PMC's legacy FTP/cloud dataset files were removed in August 2026. Use its **current inventory, per-article metadata and AWS instructions**, not an old hard-coded OA bulk URL. [Current distribution notice](https://pmc.ncbi.nlm.nih.gov/tools/cloud/).

### Decouple acquisition, lexical validity and scoring

The proposed offline flow is:

```text
Pinned source archives + rights manifests
                 |
        source-specific adapters
                 |
       normalized lexical records  <---->  sentence/context records
                 |                              |
        provenance + overlap review      author/document/time split
                 |                              |
        validated candidate catalog      source-balanced counts
                 |                              |
         selection and calibration ------------+
                 |
       versioned export + evaluation + manifest
                 |
       existing v5 core / future recognition sidecar / personal overlay
```

Keep this work independent of the ongoing Swift/C++ parity migration. Both backends must consume the same release artifact and apply the same vocabulary semantics. Do not change NSS search, thresholds and vocabulary simultaneously, because the source of quality changes would become difficult to identify.

Proposed intermediate records:

| Record | Fields to preserve | Reason |
|---|---|---|
| Source manifest | Source ID, URL, release/commit, archive hash, retrieval date, exact license, rights scope, extraction version | Reproducibility and removal/rebuild by source |
| Lexical entry | Stable catalog ID, normalized lookup form, display form, lemma, POS, attested inflections, aliases | Distinguish lookup from spelling/casing shown to the user |
| Usage evidence | Source, count, document/author dispersion, country/locale, genre/register, observation date | Prevent a large biased corpus from controlling all rankings |
| Product policy | Preserve literal input, recognition eligibility, suggestion eligibility, autocorrection eligibility, prediction eligibility, safety action | Knowing a word does not mean forcing it into another word's place |
| Context record | Source/document/sentence IDs, split, normalized tokens, boundaries and rights reference | Auditable training without joining unrelated spans |
| Export delta | Old/new forms, reasons, duplicates, rejected forms, source attribution, affected tests, serialized bytes | Review quality and cost before release |

Normalize English text to NFC and preserve its display form. Normalize case/apostrophe variants into lookup keys without destructively stripping all accents. Store aliases only when a reviewed relationship is valid; `résumé` should not become indistinguishable from every use of `resume`. Multiword expressions belong to phrase/context records, not a single trie entry with spaces forced through an ASCII tokenizer. Forms such as `gr8`, `COVID-19` and `wi-fi` need explicit tokenizer/search decisions.

Count each source separately. Estimate source-specific probabilities or frequency features, cap repetitive contributors, and calibrate the mixture on held-out material. Do not add raw COCA counts, a tiny SMS corpus and manual scores as if their units were interchangeable. Keep document boundaries, preserve unknown-word breaks, and never remove OOV tokens and concatenate their neighbors. Existing n-gram probabilities and total counts must remain internally consistent after merging.

The v5 runtime expects integer frequencies/counts, not arbitrary floating-point priors. If calibrated estimates are converted into integer pseudo-counts, document the common scale, rounding, overflow bounds and denominator construction, and verify ranking drift. If the desired mixture cannot be represented faithfully, introduce a separately versioned scoring format later rather than silently changing what existing counts mean.

### Vocabulary tiers and capacity

| Layer | Proposed contents | Runtime behavior |
|---|---|---|
| Core correction vocabulary | Common words, useful inflections, established regional forms and approved contractions | Full tap/Glide search and ranking, with locale-aware preference |
| Recognition vocabulary | Rare but valid literary/academic forms, additional regional forms and selected entities | Preserve typed words; prefix completion and bounded fallback retrieval. Conservative automatic correction by default |
| Casual/register metadata | Acronyms, short forms and slang with explicit eligibility | Preserve user intent; suggest when context and personal use support it |
| Personal overlay | User-confirmed words, contacts where existing platform access permits, learned usage | One existing mutable personal store; published immutable scoring views, no second independent database |

**First release experiment:** review and select roughly **2,000–4,000 net new ASCII forms**, below the 5,084-slot limit and only if the file cap and quality gates pass. This is a proposed budget, not a forecast of useful additions from any one source. Allocate review effort across regional spellings/inflections first, academic/common technical omissions next, then established casual terms. Preserve the existing 60,450 forms initially so any quality change is easier to attribute.

**Later experiment:** measure 10K, 30K and 60K additional recognition-form tiers, rather than committing to an arbitrary “million-word dictionary.” Compare a compact sidecar with a newly versioned wider-ID pack. A sidecar needs explicit IDs/namespacing and bounded retrieval; it cannot silently append beyond UInt16 limits. Do not represent a large permanent dictionary as thousands of Swift `String`/mutable trie objects.

The mapped vocabulary should retain one shared backing allocation across Swift and C++. Mapped data still consumes resident memory when accessed. Additional words, branching, caches, DP states and n-grams can increase latency and RAM; C++ does not make expansion free. The current retained search has a 24,000-state seed cap, and supplementary/personal Glide indices have separate limits. Measure their saturation and fallback behavior as vocabulary grows.

### Integration points in this repository

These are planned changes for a future implementation task; the present report does not modify them.

| Component | Planned responsibility |
|---|---|
| [build_esdb_snapshot.py](/Users/meherdeepak/iOSKeyboard/tools/build_esdb_snapshot.py) | Export selected regional metadata and preserve Unicode display forms; replace the US-only, destructive ASCII source representation with a versioned richer catalog |
| [build_language_data.py](/Users/meherdeepak/iOSKeyboard/tools/build_language_data.py) | Read merged reviewed records instead of letting one old frequency list define all admissible words; rebuild word IDs, trie, frequencies and n-grams atomically |
| Proposed offline `tools/vocabulary/` adapters | Isolated source decoding, license manifests, deduplication, delta reports and register/locale features; no source-specific parsing in the app |
| [Lexicon.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Engine/Lexicon.swift), [LangData.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Engine/LangData.swift) and [native core](/Users/meherdeepak/iOSKeyboard/native/README.md) | Separate membership/preservation from candidate eligibility; define compact recognition lookup without duplicating the main map |
| [Keyboardengine.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Engine/Keyboardengine.swift) | Respect regional preference and register, retain strict real-word correction gates, and keep slang from displacing ordinary words merely because it is now known |
| [NgramScorer.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Engine/NgramScorer.swift:207) | Review the static-only filter for personal next-word merging; adding a learned nonstatic word currently does not automatically make it eligible here |
| [UserModel.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Engine/UserModel.swift), engine adoption policy | Evaluate learning speed independently: current adoption starts at eight uses, with further contextual checks except for confirmed spelling. Do not silently change learning thresholds as part of a source refresh |
| [GlidePath.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Engine/GlidePath.swift) and engine Glide indexing | Confirm new words enter the appropriate bounded Glide search path; tap recognition alone does not establish Glide coverage |
| [KBSafetyLexicon.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Shared/KBSafetyLexicon.swift) | Preserve all existing suppression/demotion rules across new sources; recognition must not censor literal typed input |
| [DecodeContract.swift](/Users/meherdeepak/iOSKeyboard/keyboard/Engine/DecodeContract.swift) | Preserve revision/session validity, casing and owned result buffers as richer display forms are introduced |
| [ARTIFACTS.json](/Users/meherdeepak/iOSKeyboard/ARTIFACTS.json), [notices](/Users/meherdeepak/iOSKeyboard/THIRD_PARTY_NOTICES.md) and release verifier | Publish input/output hashes, source rights, schema version and measured sizes as one coherent release |

Keep Telugu/transliteration behavior and resources unchanged. English usage such as `biryani` or `Bengaluru` is in scope; adding a general Romanized Telugu dictionary is not.

## Implementation order and decision gates

| Stage | Deliverable | Gate before advancing |
|---|---|---|
| 0 — Baseline, completed here | Local pack inventory, 478-key diagnostic audit, phrase evidence, source investigation and this plan | No production assets changed; distinguish repository artifact from App Store version |
| 1 — Source pilots | Pin ESDB regional export, WordNet, MASC and English CC0 source manifests; prepare reviewed owned additions | Exact source version, rights and candidate deltas available; do not acquire large optional corpora first |
| 2 — Offline merge | Canonical records, per-source overlap/rejection reports, deterministic exported candidate list | For every source report raw forms, normalized forms, existing overlap, unique approved additions and eligible suggestion/correction subsets |
| 3 — Small v5 expansion | A separate experimental pack with 2K–4K approved additions and rebuilt context counts | Below both word-ID and byte caps; binary validation and Swift/native parity pass; baseline artifact retained |
| 4 — Context and register | Balanced phrase/context evidence, reviewed locale preferences and casual eligibility | Better held-out suggestions without unwanted formal↔casual or regional rewriting; no leakage from test documents |
| 5 — Larger recognition layer | Sidecar/wider-ID comparison at increasing vocabulary sizes | Paired physical-iPhone quality, p95/p99 latency and memory pass product budgets |
| 6 — Continuous maintenance | Monthly reviewed vocabulary deltas, less frequent full rebuilds, rollback manifests | Stable source rights and provenance; new entries show enough independent evidence; monitor false corrections |

Licensed COCA/GloWbE can enter stages 2–4 when their exact embedded use is permitted. They should not block the first useful release. NUS SMS/BNC stay outside production if rights remain unresolved. Gutenberg, PMC and GeoNames are targeted optional streams, not prerequisites for fixing `colour`, `screenshots` or `brb`.

## Evaluation and competitor benchmark plan

### Vocabulary and context quality

Construct a separate held-out benchmark covering US, UK, Canada, Australia/NZ, India, Singapore, African English usage and other target markets. Use independent documents/contributors and temporal splits; remove near-duplicates across training and test. Review code-switching boundaries so non-English text does not inflate an English-only OOV claim. Weight both by real usage and equally by category, and publish both views.

The 478-key diagnostic is a regression list, not the final evaluation corpus. Add contemporary, licensed or consented messages, formal email/request examples, academic writing, literature and region-specific vocabulary. A useful pilot target is at least 200 reviewed cases per major stratum, then expand based on uncertainty. Report sample sizes and paired confidence intervals; do not turn a small pilot into a claim of population-wide superiority.

| Metric | How to measure | Required comparison |
|---|---|---|
| Token/type coverage | Normalized running tokens and distinct surface forms recognized; separately report names, compounds and unsupported orthography | Baseline vs each source ablation vs final merged pack |
| Correct-word preservation | Correctly typed regional, rare and informal words left intact on commit | Especially `colour`, formal terms, acronyms and personal names |
| Candidate recall@K | Intended word in search candidates before final ranking | Distinguishes missing vocabulary from search pruning |
| Top-1/top-3 correction | Intended word rank and automatic commit decision | Minor/severe typos, missing spaces, contractions and real-word errors |
| False autocorrection rate | Valid intended words changed incorrectly | Must not hide regression behind higher correction recall |
| Next-word recall@3 / MRR | Held-out continuation rank under identical context | Formal, casual and regional streams separately |
| Register appropriateness | Human review of suggestions in formal vs casual contexts | Respectful does not mean verbose; preserve intended tone |
| Glide quality | Intended word in candidates and top result for recorded paths | Common additions, inflections, regional forms and adopted words |
| Personal learning | Attempts to preserve/suggest a confirmed new word after 1/2/4/8/16 uses | Cold profile and learned profile reported separately |

Source attribution should answer: “How much coverage did S1 add beyond the baseline? How much did S3 add beyond S1+S2? What worsened?” Publish both standalone and incremental deltas because overlapping source yields cannot be added together. Exact net gains are intentionally **pending acquisition and review**, not invented from advertised dictionary totals.

Retain the existing severe-typo golden **`coeevitjkn → correction`** in all five contexts from [SevereTypoBenchmark.swift](/Users/meherdeepak/iOSKeyboard/keyboardTests/SevereTypoBenchmark.swift:13): empty; `auto`; `possibly receive`; `for definitely decided`; `could definitely receive`. Replay with the baseline and expanded pack. Repeat neural-off and trained-neural-on runs using the same model/tokenizer once trained artifacts are available. A deterministic/random plumbing fixture does not measure neural language quality; those trained artifacts remain unavailable on this laptop.

### Matched competitor experiment

| Control | Protocol |
|---|---|
| Platforms | Compare Xploree, Gboard iOS, SwiftKey iOS and Apple on the same physical iPhone/OS and host text field. Record exact app versions. Android Gboard is a separate experiment |
| Locale | Match the selected English region where available; record unsupported variants rather than silently substituting US |
| Personalization | Separate a clean test profile/device state from an intentionally trained profile. Do not reset the user's live personal dictionary for a benchmark |
| Input | Same intended text, preceding context, punctuation/space commit and tap-path conditions; record suggestions and committed text |
| Connectivity | Record offline and online status, Full Access, cloud/AI features and downloaded language resources; compare equivalent configurations |
| Repetition | Randomize keyboard/case order, reset field context between cases, repeat input, and note cross-case learning |
| Scoring | Recognition preservation, correction top-1/top-3, false replacements, next-word rank and Glide success; use the same adjudicated targets |
| Evidence | Save case ID, device/OS/app version, locale, configuration, literal input, context, displayed suggestions and committed output |

A word surviving on a competitor keyboard does not prove membership in its base dictionary; the system may preserve unknown input. Behavioral comparison is still the right product benchmark. This experiment can quantify the competitive gap without extracting proprietary dictionaries.

### Performance and release safety

Use Release builds on the target low-memory iPhone and a newer device. Measure cold initialization, first decode, warm p50/p95/p99 per keystroke, next-word and Glide time, peak/steady resident footprint and memory-pressure recovery. Record dictionary bytes, trie nodes, mapped pages touched, caches/DP allocations and seed-cap/fallback frequency. Keep settings, model tier, inputs and thermal conditions matched.

For vocabulary experiments, seek quality improvement with no material latency or false-correction regression; establish acceptable device-specific limits from the baseline before shipping. Do not claim RAM savings or faster initialization merely because a component moves to C++. File-size reduction and resident-memory reduction are separate results.

Within each new pack, retain Swift/C++ parity requirements: identical candidate coverage/order and correction decisions, deterministic Double costs within `1e-9`, and existing Core ML numerical tolerances. Vocabulary changes are expected to alter some results relative to the **old pack**; those intentional changes need a reviewed quality delta, not a claim of cross-pack identical behavior. Exercise backspace, cursor/layout changes, cancellation, stale neural completions, adopted words and memory pressure.

Release the pack, metadata and notices atomically; never mix new word IDs with old n-grams. Keep the baseline pack available for rollback and reject incompatible/corrupted packs safely.

## What this investigation delivered

The repository artifact, its local source overlap and its diagnostic word/phrase gaps were measured. Official competitor capabilities and fourteen potential source streams were investigated. Acquisition scope, estimated time, rights constraints and a separate extraction/injection plan are specified for each.

No external corpus was downloaded for ingestion, no dictionary was rebuilt, no model was trained and no performance/competitor result was fabricated. Source membership deltas for unacquired corpora, commercial permissions where needed, App Store artifact identity and paired physical-device improvements remain explicitly pending.
