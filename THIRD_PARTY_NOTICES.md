# Third-Party Notices

## Google Profanity Words English List

`keyboard/safety.kbguard` contains a normalized, exact-match transformation of the
English list from `coffee-and-fun/google-profanity-words`, pinned at commit
`0ae3460863120bc671361b9403cc65d5f2075b89`. The keyboard uses it only to suppress
automatic suggestions and corrections; it does not censor text entered by a user.

- Source: https://github.com/coffee-and-fun/google-profanity-words/blob/0ae3460863120bc671361b9403cc65d5f2075b89/data/en.txt
- License: MIT

MIT License

Copyright (c) Robert James Gabriel / Coffee & Fun LLC

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Reviewed Telugu and Tenglish Safety Policy

`keyboard/safety.kbguard` also preserves 804 terms recovered from the project's
previous reviewed production artifact, including 26 Telugu-script entries. Their
reviewed actions and language IDs are tracked in
`tools/data/safety_recovered_reviewed.tsv`; they are internal project policy, not
third-party training data.

Review candidates are mined from the CC-BY-4.0 Telugu Hate Speech training split;
exact Roman aliases are joined from AI4Bharat Aksharantar. They remain in
`tools/data/safety_tenglish_candidates.tsv` with `candidate` review status and are
not included in runtime policy until native-speaker adjudication approves each
exact form. No source sentence is copied into the review artifact.

- Telugu Hate Speech source: https://huggingface.co/datasets/mounikaiiith/Telugu-Hatespeech
- License: https://creativecommons.org/licenses/by/4.0/

## English Speller Database (ESDB)

`keyboard/langdata.bin` preserves its vetted American-English baseline and also includes
frequency/dispersion-gated ESDB v2 size-60/70 forms for American, British,
Canadian and Australian English, plus evidence-gated Open English WordNet forms. Project-reviewed supplemental terms are tracked separately. The generated
tier snapshot is pinned to commit `1e5b7d3a72f47a71da5d28686c1dd4b397178485`.

ESDB is derived from BSD-compatible sources and the combined work is available under
an MIT-like license. The upstream `Copyright` file remains the authoritative notice.

- Source: https://github.com/en-wl/wordlist/tree/v2
- Copyright: https://github.com/en-wl/wordlist/blob/v2/Copyright

## FrequencyWords English 2018

`keyboard/langdata.bin` uses a transformed subset of the FrequencyWords English
frequency list to rank ESDB-validated entries. The source is pinned at commit
`525f9b560de45753a5ea01069454e72e9aa541c6`.

The FrequencyWords repository code is MIT licensed and its generated frequency
content is licensed under Creative Commons Attribution-ShareAlike 4.0
International. Glyph filters the list, adds project vocabulary and contractions,
and serializes it into a memory-mapped trie with frequency and language-model data.

- Source: https://github.com/hermitdave/FrequencyWords
- License: https://creativecommons.org/licenses/by-sa/4.0/

## Tatoeba English CC0 Sentences

The bi- and trigram counts in `keyboard/langdata.bin` are derived from the English
CC0-only Tatoeba sentence export snapshot vendored at
`tools/data/tatoeba-eng-cc0-2026-07-18.tsv.bz2`. Glyph lowercases and tokenizes the
sentences, counts bounded context tables, and does not ship sentence text in the app.

- Source: https://tatoeba.org/en/downloads
- Public-domain dedication: https://creativecommons.org/publicdomain/zero/1.0/

## AI4Bharat Aksharantar Telugu

`keyboard/tenglish_lexicon.bin` and the vocabulary/trie portion of
`keyboard/telugu_langdata.bin` contain transformed records from the Telugu training
split of AI4Bharat Aksharantar. The pack preserves source weights, normalizes output
to NFC, selects a bounded vocabulary, and does not include validation or test rows.

Aksharantar uses source-dependent licensing: manually collected data is CC BY and
mined/existing-source data is CC0. The exact archive and member hashes are recorded
in `keyboard/telugu_pack_manifest.json` and `ARTIFACTS.json`.

- Source and citation: https://huggingface.co/datasets/ai4bharat/Aksharantar
- Licensing: https://huggingface.co/datasets/ai4bharat/Aksharantar#licensing-information

## Tatoeba Telugu Sentences

The compact bi- and trigram records in `keyboard/telugu_langdata.bin` are derived
from the Tatoeba Telugu detailed sentence export snapshot dated July 19, 2026. The
keyboard ships aggregate counts, not sentence text. The source is licensed under
Creative Commons Attribution 2.0 France.

Contributors in this snapshot: AlphaSteppeNomad, Balamax, bharath, cntrational,
epraneeth98, frpzzd, Hari, NigerianSmiths, nurendra, ramanirudh, rarmdhyymm, simley,
and strykerami.

- Source: https://tatoeba.org/en/downloads
- License: https://creativecommons.org/licenses/by/2.0/fr/

## Unicode CLDR Telugu Keyboard Data

The external Telugu layout source is cross-checked against the Unicode CLDR Apple
Telugu keyboard chart. Unicode data is used under the Unicode License v3.

- Layout chart: https://www.unicode.org/cldr/charts/41/keyboards/layouts/te.html
- License: https://www.unicode.org/license.txt

## Unicode Character Data

Emoji search keywords in `keyboard/emoji.bin` include names derived from Unicode
Character Database 14.0 data through Python's `unicodedata` module.

- Terms of use: https://www.unicode.org/license.txt

The full artifact paths, hashes, build scripts, and transformations are recorded in
`ARTIFACTS.json`.

English vocabulary expansion v1

Open English WordNet 2025 core supplies selected English lemma/form validity and
part-of-speech metadata. Synset definitions and relations are not shipped.
Credit: John P. McCrae, the Open English WordNet contributors, and the English
WordNet project. This is a modified selected subset, not the original resource.
Source: https://en-word.net/
Download: https://en-word.net/static/english-wordnet-2025.xml.gz
License: https://creativecommons.org/licenses/by/4.0/

MASC (Manually Annotated Sub-Corpus), American National Corpus
Credit: Nancy Ide, Keith Suderman, and the MASC/OANC contributors. The selected
text-only corpus is tokenized, document-family split, deduplicated, filtered to
English vocabulary and transformed into bounded aggregate bi/trigram counts.
No MASC sentences are shipped inside the keyboard pack. Evaluation-only held-out
text remains in the source repository, separate from runtime resources.
Source: https://anc.org/data/masc/
Usage and redistribution terms: https://anc.org/data/oanc/
Download: https://github.com/nancyide/anc-website/releases/download/datasets-2026-09-25/masc_500k_texts.zip

Project-authored additions and example contexts are tracked in
tools/vocabulary/curated_terms.tsv and curated_contexts.jsonl. Their weights are
conservative editorial priors, not measured corpus frequencies. The dictionary
remains an adapted FrequencyWords resource under CC BY-SA 4.0; these additions
are distributed with that adapted data under the same license.

ESDB upstream combined and constituent notices (verbatim):

Copyright 2000-2026 by Kevin Atkinson

Permission to use, copy, modify, distribute, and sell any part of the English
Speller Database (ESDB, previously known as SCOWLv2), or word lists
created from it, is hereby granted without fee, provided that the above
copyright notice appears in all copies and that both the above copyright
notice and this notice appear in supporting documentation.  Kevin Atkinson
makes no representations about the suitability of this database for any
purpose.  It is provided "as is" without express or implied warranty.

ESDB is derived from many sources, most of which are in the Public Domain.
Data from the Corpus of Contemporary American English (COCA) was also used.

All data from COCA comes from 3-gram data that is not freely available;
however, the usage is within the rights given by the NDA that was signed when
purchasing the data.  More information on COCA is available at
https://www.english-corpora.org/coca/.

The primary source of words for ESDB comes from 12dicts and ENABLE2K.  Both
are in the Public Domain, but Alan Beale <biljir@pobox.com> deserves special
credit as he is the author of 12dicts and a major contributor to ENABLE2K.  In
addition, he gave me an incredible amount of feedback and created a number of
special lists in order to help improve the overall quality of ESDB.

===

If you are using an official speller dictionary created by ESDB that is not
Australian English, then no additional copyright applies and including the
notice before the === is sufficient.

If you are using the Australian English dictionary or a wordlist that uses the 'D'
SPELLING code and/or the 'AU' REGION code, the copyright after '=== AU' applies.

If you are using a generated word list larger than 80, the copyright
after '=== UKACD' applies.

If you are distributing the database or results from the
database that is not a speller dictionary or generated word list, then both
copyrights may apply depending on the parts you use.  In addition, the WordNet
copyright MIGHT apply as WordNet was one of many sources used for the initial
POS assignment.

=== AU

The initial information for Australian English comes from Benjamin Titze:

  Copyright 2016 by Benjamin Titze

  Permission to use, copy, modify, distribute and sell this array, the
  associated software, and its documentation for any purpose is hereby
  granted without fee, provided that the above copyright notice appears
  in all copies and that both that copyright notice and this permission
  notice appear in supporting documentation. Benjamin Titze makes no
  representations about the suitability of this array for any
  purpose. It is provided "as is" without express or implied warranty.

=== UKACD

Some words used come from the UK Advanced Cryptics Dictionary:

  Copyright (c) J Ross Beresford 1993-1999. All Rights Reserved.

  The following restriction is placed on the use of this publication:
  if The UK Advanced Cryptics Dictionary is used in a software package
  or redistributed in any form, the copyright notice must be
  prominently displayed and the text of this document must be included
  verbatim.

  There are no other restrictions: I would like to see the list
  distributed as widely as possible.

=== WordNet

WordNet was used to help with the initial POS assignment:

  This software and database is being provided to you, the LICENSEE,
  by Princeton University under the following license.  By obtaining,
  using and/or copying this software and database, you agree that you
  have read, understood, and will comply with these terms and
  conditions.:

  Permission to use, copy, modify and distribute this software and
  database and its documentation for any purpose and without fee or
  royalty is hereby granted, provided that you agree to comply with
  the following copyright notice and statements, including the
  disclaimer, and that the same appear on ALL copies of the software,
  database and documentation, including modifications that you make
  for internal use or for distribution.

  WordNet 1.6 Copyright 1997 by Princeton University.  All rights
  reserved.

  THIS SOFTWARE AND DATABASE IS PROVIDED "AS IS" AND PRINCETON
  UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR
  IMPLIED.  BY WAY OF EXAMPLE, BUT NOT LIMITATION, PRINCETON
  UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES OF MERCHANT-
  ABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF THE
  LICENSED SOFTWARE, DATABASE OR DOCUMENTATION WILL NOT INFRINGE ANY
  THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.

  The name of Princeton University or Princeton may not be used in
  advertising or publicity pertaining to distribution of the software
  and/or database.  Title to copyright in this software, database and
  any associated documentation shall at all times remain with
  Princeton University and LICENSEE agrees to preserve same.


Xploree / CoreV4 English vocabulary import (user-provided local checkout)
Stored spellings from seven English dictionary variants are unioned into the
English KBLM v6 pack. Existing iOS frequencies/context counts are preserved;
new forms use a conservative prior of 1, not CoreV4 empirical counts. Source
binary dictionaries/context files are preserved separately under
 tools/data/corev4/english/raw with checksums and paths in manifest.json.
CoreV4 capitalization/display metadata and context scales are not transferred
to KBLM. This import does not assign the CoreV4 material the licenses of the
separate ESDB, FrequencyWords, Tatoeba, WordNet or MASC sources listed above.

## MARISA prototype (native/experimental/marisa only)

The optional native experiment vendors MARISA 0.3.1, commit
`3e87d53b78e15f2f43783d5e376561a8c9722051`, from
https://github.com/s-yata/marisa-trie under its BSD-2-Clause option.
Copyright (c) 2010–2025, Susumu Yata. All rights reserved.
The complete license and disclaimer are retained in
[native/experimental/marisa/vendor/COPYING.md](native/experimental/marisa/vendor/COPYING.md).
This dependency is not linked into the shipping iOS or Android targets.
