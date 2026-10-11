#!/usr/bin/env python3
"""Read-only pre-publish gate. Reports paths/categories, never matched content."""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def git_names(*args):
    result = subprocess.run(["git", "ls-files", *args, "-z"], cwd=ROOT, check=True, capture_output=True)
    return set(result.stdout.split(b"\0")) - {b""}

cached = git_names("--cached")
candidates = cached | git_names("--others", "--exclude-standard")
patterns = {
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "GitHub token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b",
    "AWS access key": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "personal absolute path": rb"/Users/[A-Za-z0-9_.-]+/",
}
problems = []
count = 0
for raw in candidates:
    name = raw.decode("utf-8", "surrogateescape")
    path = ROOT / name
    parts = Path(name).parts
    basename = Path(name).name
    if ((basename.startswith(".env") and basename != ".env.example")
            or basename.startswith(".settings") or path.suffix.lower() in {".pdf", ".log", ".scpt"}
            or parts[0] == "artifacts" or name == "VALIDATION.md"):
        problems.append((name, "private/local file in publish candidates"))
        continue
    if path.is_symlink():
        problems.append((name, "symlink in publish candidates"))
        continue
    count += 1
    versions = []
    if path.is_file():
        versions.append(("working tree", path.read_bytes()))
    if raw in cached:
        staged = subprocess.run(["git", "show", ":" + name], cwd=ROOT, capture_output=True, check=True)
        versions.append(("Git index", staged.stdout))
    for version, data in versions:
        for category, pattern in patterns.items():
            if re.search(pattern, data):
                problems.append((name, category + " (" + version + ")"))
for name, category in sorted(problems):
    print(f"BLOCKED: {name}: {category}")
print(f"Checked {count} publish candidates; {len(problems)} findings.")
raise SystemExit(bool(problems))
