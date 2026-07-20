import struct
import csv
import unittest

import build_safety_lexicon as safety


class SafetyLexiconArtifactTests(unittest.TestCase):
    def expected_terms(self):
        terms = {}
        for raw in safety.GOOGLE_EN_SOURCE.read_text(encoding="utf-8").splitlines():
            safety.merge_term(terms, raw.strip(), safety.LANG_EN,
                              safety.SOURCE_GOOGLE_EN)
        for path, source_id in (
            (safety.RECOVERED_SOURCE, safety.SOURCE_RECOVERED),
            (safety.CURATED_SOURCE, safety.SOURCE_PROJECT),
            (safety.T_ENGLISH_SOURCE, safety.SOURCE_TENGLISH),
        ):
            for term, language, row_source, action in safety.read_policy_tsv(path, source_id):
                safety.merge_term(terms, term, language, row_source, action)
        return terms

    def test_pinned_english_input_is_unchanged(self):
        self.assertEqual(safety.sha256(safety.GOOGLE_EN_SOURCE), safety.GOOGLE_EN_SHA256)
        self.assertEqual(
            len(safety.GOOGLE_EN_SOURCE.read_text(encoding="utf-8").splitlines()),
            962,
        )

    def test_packed_artifact_contains_every_policy_term(self):
        data = safety.OUT.read_bytes()
        self.assertEqual(data[:8], b"KBGUARD1")
        version, entry_size, count, blob_bytes, _ = struct.unpack_from("<HHIII", data, 8)
        self.assertEqual((version, entry_size), (1, 24))
        blob_base = 24 + count * entry_size
        self.assertEqual(blob_base + blob_bytes, len(data))

        actual = {}
        hashes = []
        for index in range(count):
            offset = 24 + index * entry_size
            term_hash, blob_offset, length, lang, action, _, source_id, _ = (
                struct.unpack_from("<QIHBBHHI", data, offset)
            )
            term = data[blob_base + blob_offset:blob_base + blob_offset + length].decode("utf-8")
            self.assertEqual(term_hash, safety.fnv1a64(term))
            actual[term] = (lang, action, source_id)
            hashes.append((term_hash, term))

        self.assertEqual(actual, self.expected_terms())
        self.assertEqual(hashes, sorted(hashes))
        self.assertEqual(count, 997)

    def test_every_recovered_reviewed_term_remains_in_runtime_policy(self):
        expected = self.expected_terms()
        with safety.RECOVERED_SOURCE.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle, delimiter="\t"))
        self.assertEqual(len(rows), 804)
        for row in rows:
            language = safety.LANGUAGES[row["language"]]
            term = safety.normalize(row["term"], language)
            self.assertIn(term, expected)

    def test_unreviewed_tenglish_candidates_do_not_ship(self):
        expected = self.expected_terms()
        with safety.T_ENGLISH_SOURCE.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle, delimiter="\t"))
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(row["review_status"], "candidate")
            normalized = safety.normalize(row["term"], safety.LANG_TENGLISH)
            self.assertNotIn(normalized, expected)


if __name__ == "__main__":
    unittest.main()
