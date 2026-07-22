#!/usr/bin/env python3
"""Validate user-facing support tables and repository links."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PLATFORMS = ("windows", "macos", "linux")
README_FILES = (
    "README.md",
    "README.es.md",
    "README.ar.md",
    "README.zh.md",
    "README.ru.md",
    "README.he.md",
)
DEFAULT_PROFILE_DESCRIPTIONS = {
    "README.md": "Create an account profile (credentials separate; normal state shared)",
    "README.es.md": "Crear un perfil de cuenta (credenciales separadas; estado normal compartido)",
    "README.ar.md": "إنشاء ملف تعريف حساب (بيانات اعتماد منفصلة وحالة عادية مشتركة)",
    "README.zh.md": "创建账户配置文件（凭据独立，常规状态共享）",
    "README.ru.md": "Создать профиль аккаунта (отдельные учётные данные, общее обычное состояние)",
    "README.he.md": "יצירת פרופיל חשבון (אישורים נפרדים ומצב רגיל משותף)",
}
RETIRED_SUPPORT_TERMS = re.compile(
    r"\bexperimental\b|\bunverified\b|\bexperiment(?:al|ell|almente)\b|"
    r"эксперимент|实验性|تجريبي|ניסיוני",
    re.IGNORECASE,
)


def load_adapters() -> list[dict]:
    adapters = []
    for manifest_path in sorted(REPO_ROOT.glob("*/adapter.json")):
        adapter = json.loads(manifest_path.read_text(encoding="utf-8"))
        adapters.append(adapter)
    return adapters


def table_rows(readme: str) -> dict[str, list[str]]:
    rows = {}
    for line in readme.splitlines():
        match = re.match(r"\| \[([^]]+)]\(([^/)]+)/\) \|.*\|$", line)
        if not match:
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        rows[match.group(2)] = cells[-3:]
    return rows


def validate_readme(path: Path, adapters: list[dict]) -> list[str]:
    text = path.read_text(encoding="utf-8")
    errors = []
    if "Spielewoy/multi-codex" in text:
        errors.append(f"{path.name}: stale Spielewoy/multi-codex URL")
    if RETIRED_SUPPORT_TERMS.search(text):
        errors.append(f"{path.name}: contains retired experimental/unverified support wording")
    for command in ("--isolated", "-i", "--isolate", "multi-cli continue"):
        if command not in text:
            errors.append(f"{path.name}: missing command documentation for {command}")
    default_row = f"| `multi-cli new <tool>/<name>` | {DEFAULT_PROFILE_DESCRIPTIONS[path.name]} |"
    if default_row not in text:
        errors.append(f"{path.name}: default new command must describe shared account profiles")
    rows = table_rows(text)
    expected_ids = {adapter["id"] for adapter in adapters}
    if set(rows) != expected_ids:
        missing = sorted(expected_ids - set(rows))
        extra = sorted(set(rows) - expected_ids)
        errors.append(f"{path.name}: support rows mismatch; missing={missing}, extra={extra}")
    for adapter in adapters:
        cells = rows.get(adapter["id"])
        if not cells:
            continue
        for index, platform in enumerate(PLATFORMS):
            expected_level = adapter["support"][platform]["level"]
            normalized = cells[index].lower()
            if expected_level == "supported" and normalized.startswith("unsupported"):
                errors.append(f"{path.name}: {adapter['id']} {platform} contradicts supported manifest status")
            if expected_level == "unsupported" and "supported" in normalized and "unsupported" not in normalized:
                errors.append(f"{path.name}: {adapter['id']} {platform} contradicts unsupported manifest status")
    return errors


def validate_local_links(path: Path) -> list[str]:
    errors = []
    text = path.read_text(encoding="utf-8")
    for target in re.findall(r"\[[^]]*]\(([^)]+)\)", text):
        if target.startswith(("http://", "https://", "#", "mailto:")):
            continue
        file_target = target.split("#", 1)[0]
        if file_target and not (path.parent / file_target).exists():
            errors.append(f"{path.relative_to(REPO_ROOT)}: broken local link {target}")
    return errors


def main() -> int:
    adapters = load_adapters()
    errors = []
    for file_name in README_FILES:
        path = REPO_ROOT / file_name
        errors.extend(validate_readme(path, adapters))
        errors.extend(validate_local_links(path))
    for path in REPO_ROOT.glob("*/README.md"):
        errors.extend(validate_local_links(path))
        if RETIRED_SUPPORT_TERMS.search(path.read_text(encoding="utf-8")):
            errors.append(f"{path.relative_to(REPO_ROOT)}: contains retired support wording")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Validated {len(README_FILES)} main READMEs and {len(adapters)} adapter support rows.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
