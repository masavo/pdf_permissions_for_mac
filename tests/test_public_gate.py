import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PublicGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pdf-public-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts" / "check_public_files.py", self.root / "scripts" / "check_public_files.py")
        shutil.copy2(ROOT / ".gitignore", self.root / ".gitignore")
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)

    def run_gate(self):
        return subprocess.run([os.sys.executable, str(self.root / "scripts" / "check_public_files.py")], capture_output=True)

    def test_local_files_ignored_but_examples_public(self):
        for name in [".env", ".env.backup", ".env~", ".settings", ".settings.bak", "example.pdf", "example.log", "VALIDATION.md"]:
            (self.root / name).write_text("local-only")
        for name in [".env.example", "settings.example"]:
            (self.root / name).write_text("safe example")
        self.assertEqual(self.run_gate().returncode, 0)
        files = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"], cwd=self.root, capture_output=True, check=True).stdout
        self.assertIn(b".env.example", files)
        self.assertIn(b"settings.example", files)
        self.assertNotIn(b"local-only", self.run_gate().stdout)

    def test_forced_secret_config_addition_blocked(self):
        (self.root / ".env").write_text("local-only")
        subprocess.run(["git", "add", "-f", ".env"], cwd=self.root, check=True)
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_staged_secret_detected_even_if_working_copy_clean(self):
        path = self.root / "accidental.txt"
        # Synthetic marker; never a usable token.
        path.write_text("ghp" + "_" + "A" * 36)
        subprocess.run(["git", "add", "accidental.txt"], cwd=self.root, check=True)
        path.write_text("clean working copy")
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Git index", result.stdout)
        self.assertNotIn(("A" * 36).encode(), result.stdout)

if __name__ == "__main__":
    unittest.main()
