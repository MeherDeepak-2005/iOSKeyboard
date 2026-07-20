# Generated-Text Safety Policy

`keyboard/safety.kbguard` applies only to generated suggestions, corrections, Glide
results, neural candidates, and learning. It never censors literal typing or a media
search query. Runtime matching is exact after documented normalization; there is no
fuzzy profanity match.

## Reviewed Runtime Inputs

- `google_profanity_en.txt`: pinned MIT-licensed English source.
- `safety_recovered_reviewed.tsv`: 804 entries recovered byte-for-byte from the
  prior reviewed production artifact, including 26 Telugu entries.
- `safety_terms.tsv`: project-reviewed additions.

Only rows with `review_status=approved` are eligible. The binary builder rejects an
unknown schema and ignores `candidate` or `rejected` rows.

## Telugu And Tenglish Review Queue

`mine_telugu_safety_candidates.py` uses the CC-BY-4.0 Telugu Hate Speech training
split to rank exact Telugu tokens by positive-vs-negative document enrichment. It
then joins exact native forms against the Aksharantar training split to propose
explicit Roman aliases. It writes no sentence text and adds zero runtime terms.

```sh
python3 tools/mine_telugu_safety_candidates.py \
  --hate-csv tools/.cache/telugu_hatespeech_train.csv \
  --aksharantar tools/.cache/aksharantar_tel.zip \
  --output tools/data/safety_tenglish_candidates.tsv \
  --audit-output tools/data/safety_telugu_candidate_audit.json \
  --expected-hate-sha256 da735d6ab71de52c2d123ff0c32d5e960e17078be856072ad098d3e7a564ac59 \
  --expected-aksharantar-sha256 08f1c2841f4d02fcc2a56362f7760ec16fc52d8a199029c68d44024ab0d22c1a
```

The current queue contains 194 Telugu forms and 244 Roman aliases. Corpus
co-occurrence produces false positives, including ordinary vocabulary and names;
this queue is not release-eligible.

For promotion, a Telugu native speaker must review each exact Telugu form and each
Roman alias independently, document the intended action, and move only accepted
rows to `safety_terms.tsv` with `review_status=approved`. A second reviewer should
check high-impact suppressions. Rebuild and run the false-positive fixtures before
shipping.

The production derivation intentionally excludes MACD and X-MuTeST because their
access terms are not suitable for this commercial runtime policy.

Sources:

- Telugu Hate Speech: https://huggingface.co/datasets/mounikaiiith/Telugu-Hatespeech
- Aksharantar: https://huggingface.co/datasets/ai4bharat/Aksharantar
