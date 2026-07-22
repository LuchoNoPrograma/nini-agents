#!/usr/bin/env python3
"""Enforce coverage for executable lines added since a Git baseline."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


def run_git(repo: Path, arguments: list[str]) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "git command failed")
    return completed.stdout


def parse_added_lines(diff: str) -> dict[str, set[int]]:
    changed: dict[str, set[int]] = defaultdict(set)
    current_path: str | None = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_path = line[6:]
            continue
        if not line.startswith("@@ ") or current_path is None:
            continue
        added_range = line.split(" +", 1)[1].split(" ", 1)[0]
        start_text, separator, count_text = added_range.partition(",")
        start = int(start_text)
        count = int(count_text) if separator else 1
        changed[current_path].update(range(start, start + count))
    return dict(changed)


def get_changed_lines(repo: Path, baseline: str, pathspecs: list[str]) -> dict[str, set[int]]:
    run_git(repo, ["rev-parse", "--verify", f"{baseline}^{{commit}}"])
    diff = run_git(repo, ["diff", "--unified=0", "--no-color", baseline, "--", *pathspecs])
    changed = parse_added_lines(diff)
    untracked = run_git(repo, ["ls-files", "--others", "--exclude-standard", "--", *pathspecs])
    for relative_path in untracked.splitlines():
        path = repo / relative_path
        if path.is_file():
            changed[relative_path.replace("\\", "/")] = set(
                range(1, len(path.read_text(encoding="utf-8-sig").splitlines()) + 1)
            )
    return changed


def resolve_coverage_path(filename: str, changed_paths: set[str]) -> str | None:
    normalized = filename.replace("\\", "/").lstrip("./")
    exact = [path for path in changed_paths if normalized == path]
    if exact:
        return exact[0]
    suffixes = [path for path in changed_paths if normalized.endswith(f"/{path}")]
    if len(suffixes) == 1:
        return suffixes[0]
    return None


def read_cobertura(paths: list[Path], changed_paths: set[str]) -> dict[str, dict[int, int]]:
    coverage: dict[str, dict[int, int]] = defaultdict(dict)
    for path in paths:
        root = ET.parse(path).getroot()
        for class_node in root.findall(".//class"):
            relative_path = resolve_coverage_path(class_node.get("filename", ""), changed_paths)
            if relative_path is None:
                continue
            for line_node in class_node.findall("./lines/line"):
                number = int(line_node.get("number", "0"))
                hits = int(float(line_node.get("hits", "0")))
                coverage[relative_path][number] = max(coverage[relative_path].get(number, 0), hits)
    return dict(coverage)


def find_cobertura_reports(coverage_root: Path) -> list[Path]:
    if coverage_root.is_file():
        return [coverage_root] if coverage_root.suffix.lower() == ".xml" else []
    return sorted(coverage_root.rglob("cobertura.xml"))


def get_executable_changed_lines(changed_lines: set[int], line_hits: dict[int, int]) -> list[int]:
    return sorted(changed_lines.intersection(line_hits))


def build_report(
    changed: dict[str, set[int]],
    coverage: dict[str, dict[int, int]],
    minimum: float,
) -> dict[str, object]:
    files = []
    missing_files = []
    covered_total = 0
    executable_total = 0
    for path in sorted(changed):
        line_hits = coverage.get(path)
        if not line_hits:
            missing_files.append(path)
            continue
        executable_lines = get_executable_changed_lines(changed[path], line_hits)
        covered_lines = [line for line in executable_lines if line_hits[line] > 0]
        missed_lines = [line for line in executable_lines if line_hits[line] == 0]
        executable_total += len(executable_lines)
        covered_total += len(covered_lines)
        files.append(
            {
                "path": path,
                "executableChanged": len(executable_lines),
                "covered": len(covered_lines),
                "missedLines": missed_lines,
            }
        )
    percent = 100.0 if executable_total == 0 else 100.0 * covered_total / executable_total
    return {
        "minimumPercent": minimum,
        "total": {
            "executableChanged": executable_total,
            "covered": covered_total,
            "missed": executable_total - covered_total,
            "percent": round(percent, 2),
        },
        "files": files,
        "missingCoverageFiles": missing_files,
        "passed": not missing_files and percent >= minimum,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--coverage-root", type=Path, required=True)
    parser.add_argument("--minimum", type=float, default=95.0)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pathspec", action="append", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repo = arguments.repo.resolve()
    changed = get_changed_lines(repo, arguments.baseline, arguments.pathspec)
    reports = find_cobertura_reports(arguments.coverage_root.resolve())
    if not reports:
        raise RuntimeError(f"No cobertura.xml found under {arguments.coverage_root}")
    coverage = read_cobertura(reports, set(changed))
    report = build_report(changed, coverage, arguments.minimum)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    total = report["total"]
    print(
        f"Changed-line coverage: {total['percent']:.2f}% "
        f"({total['covered']}/{total['executableChanged']})"
    )
    for path in report["missingCoverageFiles"]:
        print(f"No coverage data for changed production file: {path}", file=sys.stderr)
    for file_report in report["files"]:
        if file_report["missedLines"]:
            lines = ", ".join(str(line) for line in file_report["missedLines"])
            print(f"Missed changed lines in {file_report['path']}: {lines}", file=sys.stderr)
    if not report["passed"]:
        print(f"Changed-line coverage gate FAILED (minimum {arguments.minimum:.2f}%).", file=sys.stderr)
        return 1
    print(f"Changed-line coverage gate passed (minimum {arguments.minimum:.2f}%).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"Changed-line coverage gate ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
