#!/usr/bin/env python3
"""Convert SimpleCov's JSON result into line-only Cobertura XML."""

from __future__ import annotations

import argparse
import fnmatch
import json
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pathspec", action="append", required=True)
    return parser.parse_args()


def get_coverage(result: dict[str, object]) -> dict[str, list[int | None]]:
    coverage: dict[str, list[int | None]] = {}
    for command in result.values():
        files = command.get("coverage", {})
        for filename, details in files.items():
            lines = details.get("lines", details) if isinstance(details, dict) else details
            current = coverage.setdefault(filename, [None] * len(lines))
            if len(current) < len(lines):
                current.extend([None] * (len(lines) - len(current)))
            for index, hits in enumerate(lines):
                if hits is None:
                    continue
                current[index] = int(hits) + int(current[index] or 0)
    return coverage


def build_cobertura(
    coverage: dict[str, list[int | None]], repo: Path, pathspecs: list[str]
) -> ET.ElementTree:
    root = ET.Element("coverage")
    classes = ET.SubElement(ET.SubElement(ET.SubElement(root, "packages"), "package"), "classes")
    for filename, hits_by_line in sorted(coverage.items()):
        path = Path(filename).resolve()
        try:
            relative_path = path.relative_to(repo.resolve()).as_posix()
        except ValueError:
            continue
        if not any(fnmatch.fnmatch(relative_path, pathspec) for pathspec in pathspecs):
            continue
        class_node = ET.SubElement(classes, "class", filename=relative_path)
        lines_node = ET.SubElement(class_node, "lines")
        for number, hits in enumerate(hits_by_line, start=1):
            if hits is not None:
                ET.SubElement(lines_node, "line", number=str(number), hits=str(hits))
    return ET.ElementTree(root)


def main() -> int:
    arguments = parse_arguments()
    raw_result = json.loads(arguments.input.read_text(encoding="utf-8"))
    tree = build_cobertura(get_coverage(raw_result), arguments.repo, arguments.pathspec)
    ET.indent(tree, space="  ")
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    tree.write(arguments.output, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
