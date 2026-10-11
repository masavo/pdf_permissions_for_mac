"""Self-contained tests: synthetic PDFs/secrets, no personal files or Keychain writes."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def make_pdf(path):
    contents = b"BT /F1 12 Tf 40 100 Td (Synthetic security test) Tj ET\n"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
               b"<< /Length " + str(len(contents)).encode() + b" >>\nstream\n" + contents + b"endstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    data = b"%PDF-1.4\n"
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += str(index).encode() + b" 0 obj\n" + obj + b"\nendobj\n"
    start = len(data)
    data += b"xref\n0 6\n0000000000 65535 f \n"
    data += b"".join(f"{n:010d} 00000 n \n".encode() for n in offsets[1:])
    data += f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
    path.write_bytes(data)

class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pdf-security-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ["secure_pdf.sh", "setup.sh", "install_folder_action.sh", "folder-action.applescript", "register_folder_action.applescript"]:
            shutil.copy2(ROOT / name, self.root / name)
        shutil.copytree(ROOT / "lib", self.root / "lib")
        self.owner = secrets.token_urlsafe(24)
        self.env = os.environ | dict(OWNER_PASSWORD=self.owner, USER_PASSWORD="", SECRET_BACKEND="environment",
                                     TARGET_PREFIX="", QPDF_BIN="", LOG_FILE=str(self.root / "test.log"),
                                     STABILITY_CHECKS="1", STABILITY_INTERVAL_SECONDS="0.01",
                                     PDF_CONFIG_FILE=str(self.root / ".settings"), PDF_ENVCHAIN_ACTIVE="")
        self.pdf = self.root / "sample 日本語 ' space.pdf"
        make_pdf(self.pdf)

    def run_script(self, *args, script="secure_pdf.sh", **env):
        return subprocess.run(["/bin/bash", str(self.root / script), *map(str, args)],
                              env=self.env | env, capture_output=True, timeout=15)

    def caps(self, password=""):
        result = subprocess.run(["qpdf", "--password-file=-", "--json", "--json-key=encrypt", str(self.pdf)],
                                input=(password + "\n").encode(), capture_output=True, check=True)
        return json.loads(result.stdout)["encrypt"]

    def test_default_permissions_and_secret_not_logged(self):
        self.assertEqual(self.run_script(self.pdf).returncode, 0)
        encrypted = self.caps()
        expected = dict(accessibility=True, extract=True, modify=False, modifyannotations=True,
                        modifyassembly=False, modifyforms=False, modifyother=False, printhigh=True, printlow=True)
        self.assertEqual(encrypted["capabilities"], expected)
        self.assertTrue(self.caps(self.owner)["ownerpasswordmatched"])
        self.assertNotIn(self.owner.encode(), (self.root / "test.log").read_bytes())
        self.assertEqual(self.pdf.stat().st_mode & 0o777, 0o600)

    def test_error_preserves_input_and_reports_failure(self):
        self.pdf.write_bytes(b"not a PDF")
        before = self.pdf.read_bytes()
        self.assertNotEqual(self.run_script(self.pdf).returncode, 0)
        self.assertEqual(self.pdf.read_bytes(), before)
        self.assertFalse(list(self.root.glob(".secure-pdf*")))

    def test_symlink_input_rejected(self):
        alias = self.root / "alias.pdf"
        alias.symlink_to(self.pdf)
        self.assertNotEqual(self.run_script(alias).returncode, 0)

    def test_log_symlink_rejected(self):
        victim = self.root / "victim.txt"
        victim.write_text("unchanged")
        (self.root / "test.log").symlink_to(victim)
        self.assertNotEqual(self.run_script(self.pdf).returncode, 0)
        self.assertEqual(victim.read_text(), "unchanged")

    def test_custom_cannot_override_password(self):
        before = self.pdf.read_bytes()
        result = self.run_script(self.pdf, PERMISSION_POLICY="custom", QPDF_PERMISSION_ARGS="--owner-password=override")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.pdf.read_bytes(), before)

    def test_custom_multiline_rejected(self):
        self.assertNotEqual(self.run_script(self.pdf, PERMISSION_POLICY="custom", QPDF_PERMISSION_ARGS="--print=none\n--print=full").returncode, 0)

    def test_zero_stability_interval_rejected(self):
        self.assertNotEqual(self.run_script(self.pdf, STABILITY_INTERVAL_SECONDS="0").returncode, 0)

    def test_owner_equal_user_rejected(self):
        self.assertNotEqual(self.run_script(self.pdf, USER_PASSWORD=self.owner).returncode, 0)

    def test_newline_password_rejected(self):
        self.assertNotEqual(self.run_script(self.pdf, OWNER_PASSWORD="one\ntwo").returncode, 0)

    def test_environment_does_not_source_dotenv(self):
        (self.root / ".env").write_text('exit 87\n')
        self.assertEqual(self.run_script(self.pdf).returncode, 0)

    def test_explicit_backend_overrides_settings(self):
        (self.root / ".settings").write_text("SECRET_BACKEND=dotenv\n")
        (self.root / ".env").write_text("exit 87\n")
        self.assertEqual(self.run_script(self.pdf).returncode, 0)

    def fake_envchain(self, inject=True):
        path = self.root / "envchain"
        path.write_text('#!/bin/bash\nns="$1"; shift\n' +
                        ('export OWNER_PASSWORD="${TEST_OWNER}" USER_PASSWORD=""\n' if inject else '') + 'exec "$@"\n')
        path.chmod(0o700)
        return str(path)

    def test_envchain_reexec_ignores_dotenv(self):
        (self.root / ".env").write_text('exit 87\n')
        self.assertEqual(self.run_script(self.pdf, SECRET_BACKEND="envchain", ENVCHAIN_BIN=self.fake_envchain(),
                                        TEST_OWNER=self.owner).returncode, 0)
        self.assertTrue(self.caps(self.owner)["ownerpasswordmatched"])

    def test_empty_envchain_fails_without_inherited_or_dotenv_fallback(self):
        (self.root / ".env").write_text('OWNER_PASSWORD="must-not-be-used"\n')
        self.assertNotEqual(self.run_script(self.pdf, SECRET_BACKEND="envchain", ENVCHAIN_BIN=self.fake_envchain(False)).returncode, 0)

    def test_setup_envchain_no_dotenv_and_repeat_install(self):
        envchain = self.fake_envchain()
        # Tool discovery in setup uses PATH, as on a fresh installation.
        env = dict(PATH=str(self.root) + ":" + self.env["PATH"], TEST_OWNER=self.owner,
                   FOLDER_ACTION_SCRIPTS_DIR=str(self.root / "installed"))
        args = ["--folder", str(self.root), "--skip-secrets", "--no-register"]
        for _ in range(2):
            self.assertEqual(self.run_script(*args, script="setup.sh", **env).returncode, 0)
        self.assertFalse((self.root / ".env").exists())
        settings = (self.root / ".settings").read_bytes()
        self.assertNotIn(self.owner.encode(), settings)
        self.assertIn(b"SECRET_BACKEND=envchain", settings)
        self.assertTrue((self.root / "installed" / "PDF自動権限付与.scpt").exists())

    def test_setup_preserves_existing_dotenv(self):
        path = self.root / ".env"
        path.write_text('OWNER_PASSWORD="' + self.owner + '"\nUSER_PASSWORD=""\n')
        before = path.read_bytes()
        result = self.run_script("--folder", str(self.root), "--backend", "dotenv", "--no-register", script="setup.sh",
                                 FOLDER_ACTION_SCRIPTS_DIR=str(self.root / "installed"))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_input_changed_while_encrypting_is_not_overwritten(self):
        wrapper = self.root / "qpdf-wrapper"
        qpdf = shutil.which("qpdf")
        # Delay output from qpdf and concurrently replace the input.
        wrapper.write_text(f'#!/bin/bash\n"{qpdf}" "$@"\nstatus=$?\nprintf changed > "$TEST_INPUT"\nexit "$status"\n')
        wrapper.chmod(0o700)
        self.assertNotEqual(self.run_script(self.pdf, QPDF_BIN=str(wrapper), TEST_INPUT=str(self.pdf)).returncode, 0)
        self.assertEqual(self.pdf.read_bytes(), b"changed")

    def test_existing_lock_blocks_processing(self):
        lock_hash = hashlib.sha256(str(self.pdf.resolve()).encode()).hexdigest()
        (self.root / (".secure-pdf-" + lock_hash + ".lock")).mkdir()
        self.assertNotEqual(self.run_script(self.pdf).returncode, 0)

    def test_qpdf_children_do_not_receive_password_environment(self):
        wrapper = self.root / "qpdf-wrapper"
        wrapper.write_text('#!/bin/bash\n[[ ! ${OWNER_PASSWORD+x} && ! ${USER_PASSWORD+x} ]] || exit 86\nexec "' + shutil.which("qpdf") + '" "$@"\n')
        wrapper.chmod(0o700)
        self.assertEqual(self.run_script(self.pdf, QPDF_BIN=str(wrapper)).returncode, 0)

if __name__ == "__main__":
    unittest.main()
