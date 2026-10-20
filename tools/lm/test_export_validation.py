import unittest
from export_validation import require_parity, steps_per_budget


class ExportValidationTests(unittest.TestCase):
    def test_millisecond_budget_uses_microseconds(self):
        self.assertEqual(steps_per_budget(100), 10)
        self.assertEqual(steps_per_budget(250, budget_ms=2), 8)

    def test_failed_or_nonfinite_parity_is_fatal(self):
        for error in [0.6, float("nan"), float("inf")]:
            with self.assertRaises(ValueError):
                require_parity(error, 0.5, "fixture")
        require_parity(0.01, 0.5, "fixture")


if __name__ == "__main__":
    unittest.main()
