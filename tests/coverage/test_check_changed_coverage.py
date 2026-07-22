#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("check_changed_coverage.py")
SPEC = importlib.util.spec_from_file_location("check_changed_coverage", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ChangedCoverageTests(unittest.TestCase):
    def test_parse_added_lines_tracks_new_ranges_per_file(self):
        diff = """\
+++ b/lib/example.sh
@@ -1,0 +2,2 @@
+first
+second
+++ b/lib/other.psm1
@@ -8 +9 @@
+replacement
"""

        self.assertEqual(
            MODULE.parse_added_lines(diff),
            {"lib/example.sh": {2, 3}, "lib/other.psm1": {9}},
        )

    def test_read_cobertura_merges_reports_by_highest_hit_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.xml"
            second = root / "second.xml"
            first.write_text(
                '<coverage><packages><package><classes><class filename="lib/a.sh"><lines>'
                '<line number="4" hits="0"/><line number="5" hits="1"/>'
                '</lines></class></classes></package></packages></coverage>',
                encoding="utf-8",
            )
            second.write_text(
                '<coverage><packages><package><classes><class filename="/repo/lib/a.sh"><lines>'
                '<line number="4" hits="2"/></lines></class></classes></package></packages></coverage>',
                encoding="utf-8",
            )

            coverage = MODULE.read_cobertura([first, second], {"lib/a.sh"})

        self.assertEqual(coverage, {"lib/a.sh": {4: 2, 5: 1}})

    def test_build_report_uses_only_executable_changed_lines(self):
        report = MODULE.build_report(
            {"lib/a.sh": {2, 3, 4}, "lib/b.sh": {8}},
            {"lib/a.sh": {2: 1, 4: 0}, "lib/b.sh": {8: 1}},
            95.0,
        )

        self.assertEqual(
            report["total"],
            {"executableChanged": 3, "covered": 2, "missed": 1, "percent": 66.67},
        )
        self.assertEqual(report["files"][0]["missedLines"], [4])
        self.assertFalse(report["passed"])

    def test_changed_lines_include_only_exact_executable_coverage_lines(self):
        self.assertEqual(
            MODULE.get_executable_changed_lines({2, 4, 8, 9}, {4: 1, 9: 0, 10: 1}),
            [4, 9],
        )

    def test_build_report_allows_changed_file_with_no_executable_lines(self):
        report = MODULE.build_report(
            {"lib/comments.sh": {1, 2}},
            {"lib/comments.sh": {4: 1}},
            95.0,
        )

        self.assertEqual(report["files"][0]["executableChanged"], 0)
        self.assertTrue(report["passed"])

    def test_build_report_fails_when_changed_file_has_no_coverage_data(self):
        report = MODULE.build_report({"lib/missing.sh": {1}}, {}, 95.0)

        self.assertEqual(report["missingCoverageFiles"], ["lib/missing.sh"])
        self.assertFalse(report["passed"])


if __name__ == "__main__":
    unittest.main()
