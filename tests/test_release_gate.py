"""release_gate: tag must equal plugin.json version and the newest CHANGELOG
heading; --notes-out yields that version's section. Each failure mode fires."""
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import release_gate as rg  # noqa: E402


def write(p, text):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


def make(root, version="0.1.0", newest="0.1.0"):
    write(root / ".claude-plugin" / "plugin.json",
          json.dumps({"name": "cc-operator", "version": version}))
    write(root / "CHANGELOG.md",
          f"# C\n\n## [Unreleased]\n\n## [{newest}] - 2026-07-06\n\n"
          f"### Added\n- thing\n")


class ReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_matching_tag_passes(self):
        make(self.dir, "0.1.0", "0.1.0")
        problems, notes = rg.gate(self.dir, "v0.1.0")
        self.assertEqual(problems, [])
        self.assertIn("thing", notes)

    def test_bad_tag_format(self):
        make(self.dir)
        problems, _ = rg.gate(self.dir, "0.1.0")  # missing 'v'
        self.assertTrue(any("not v<x.y.z>" in p for p in problems))

    def test_tag_version_mismatch(self):
        make(self.dir, version="0.1.0", newest="0.1.0")
        problems, _ = rg.gate(self.dir, "v0.2.0")
        self.assertTrue(any("does not match plugin.json" in p for p in problems))

    def test_changelog_not_newest(self):
        make(self.dir, version="0.2.0", newest="0.1.0")
        problems, _ = rg.gate(self.dir, "v0.2.0")
        self.assertTrue(any("newest CHANGELOG heading" in p for p in problems))

    def test_missing_changelog(self):
        write(self.dir / ".claude-plugin" / "plugin.json",
              json.dumps({"name": "cc-operator", "version": "0.1.0"}))
        problems, _ = rg.gate(self.dir, "v0.1.0")
        self.assertTrue(any("CHANGELOG.md: missing" in p for p in problems))

    def test_notes_extraction(self):
        make(self.dir, "0.1.0", "0.1.0")
        _, notes = rg.gate(self.dir, "v0.1.0")
        self.assertTrue(notes.startswith("### Added"))


if __name__ == "__main__":
    unittest.main()
