#!/usr/bin/env python3
"""Check the publishable tree and all referenced Git history without rewriting it."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SCANNER = ROOT / ".tools/bin/gitleaks"
VERSION = "8.30.1"


def main():
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    ).decode().split("\0")
    forbidden = {".agent-local", ".cortexkit", ".opencode", ".tools", ".toolchain", ".venv", "_opam", "_build", "node_modules", "site"}
    attribution = re.compile(r"\b(?:ai|human)[ -]assisted\b|\bmade\s+by\b|\b(?:created|authored|generated)\s+by\s+(?:an?\s+)?(?:ai|llm|chatgpt|claude|openai)\b", re.I)
    machine_path = re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/")
    files = sorted(set(filter(None, paths)))
    for name in files:
        path = Path(name)
        if path.parts[0] in forbidden or path.suffix in {".pyc", ".log", ".bak", ".corrected", ".install", ".wasm"} or path.name == ".DS_Store":
            raise SystemExit(f"Generated/private artifact in publishable tree: {name}")
        source = ROOT / path
        if source.is_symlink() or not source.resolve().is_relative_to(ROOT) or not source.is_file():
            raise SystemExit(f"Review non-regular publishable file explicitly: {name}")
        if path.parts[0] != "licenses":
            text = source.read_text(encoding="utf-8")
            if attribution.search(text):
                raise SystemExit(f"Creation-attribution wording requires review: {name}")
            if machine_path.search(text):
                raise SystemExit(f"Personal machine path requires review: {name}")
    if subprocess.check_output([str(SCANNER), "version"], cwd=ROOT, text=True).strip() != VERSION:
        raise SystemExit(f"Install the pinned repository-local Gitleaks {VERSION} first")
    environment = dict(os.environ, GOMAXPROCS="2")
    environment.pop("GITLEAKS_CONFIG", None)
    environment.pop("GITLEAKS_CONFIG_TOML", None)
    flags = ["--redact=100", "--ignore-gitleaks-allow", "--timeout=120", "--no-banner", "--no-color"]
    temporary = Path(os.environ.get("TMPDIR", ROOT / ".agent-local/tmp"))
    if not temporary.resolve().is_relative_to(ROOT):
        raise SystemExit("Publication scratch must stay inside this repository")
    with tempfile.TemporaryDirectory(prefix="tern-publication-", dir=temporary) as directory:
        snapshot = Path(directory)
        for name in files:
            target = snapshot / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        subprocess.run([str(SCANNER), "dir", *flags, str(snapshot)], cwd=ROOT, env=environment, check=True)
    subprocess.run([str(SCANNER), "git", "--log-opts=--all", *flags, str(ROOT)], cwd=ROOT, env=environment, check=True)
    print(f"Publication inventory: {len(files)} text files; no generated/private artifacts or project attribution/personal-path findings.")
    print("Default secret rules checked the current publishable tree and all referenced history; no history or identity metadata was changed.")


if __name__ == "__main__":
    main()
