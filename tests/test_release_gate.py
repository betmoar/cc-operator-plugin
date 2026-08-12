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

    # --- reference-style issue links survive extraction ---
    # The section body is cut at `^\[`, which IS the link-def block, so a
    # section using `[#N]` used to publish literal `[#N]` text with no link.
    # Measured on v0.7.0 before the fix: 9 dead references in the release body.
    _CL_WITH_REFS = (
        "# C\n\n## [Unreleased]\n\n"
        "## [0.2.0] - 2026-01-02\n\n- fixed [#7] and [#8]\n\n"
        "## [0.1.0] - 2026-01-01\n\n- init, see [#1]\n\n"
        "[#1]: https://x/issues/1\n"
        "[#7]: https://x/issues/7\n"
        "[#8]: https://x/issues/8\n"
    )

    def test_notes_carry_the_link_defs_they_use(self):
        # Through the full gate: 0.2.0 is the newest heading, so this is the
        # path release.yml actually runs.
        write(self.dir / ".claude-plugin" / "plugin.json",
              json.dumps({"name": "cc-operator", "version": "0.2.0"}))
        write(self.dir / "CHANGELOG.md", self._CL_WITH_REFS)
        problems, notes = rg.gate(self.dir, "v0.2.0")
        self.assertEqual(problems, [])
        self.assertIn("[#7]: https://x/issues/7", notes)
        self.assertIn("[#8]: https://x/issues/8", notes)

    def test_notes_do_not_leak_other_versions_defs(self):
        # Each section carries only the defs its own body uses. Exercised on
        # extract_section directly: an older version is by definition not the
        # newest heading, so gate() would refuse it before extracting.
        notes_2 = rg.extract_section(self._CL_WITH_REFS, "0.2.0")
        self.assertIn("[#7]: https://x/issues/7", notes_2)
        self.assertNotIn("[#1]:", notes_2)
        # the converse, so the filter is not merely dropping the first def
        notes_1 = rg.extract_section(self._CL_WITH_REFS, "0.1.0")
        self.assertIn("[#1]: https://x/issues/1", notes_1)
        self.assertNotIn("[#7]:", notes_1)

    def test_notes_without_refs_are_unchanged(self):
        make(self.dir, "0.1.0", "0.1.0")
        _, notes = rg.gate(self.dir, "v0.1.0")
        self.assertEqual(notes, "### Added\n- thing")

    def test_ref_with_no_definition_anywhere_fails_the_gate(self):
        # Appending only the defs that EXIST leaves a body whose `[#99]`
        # publishes as literal text — the same dead-link bug this fix exists to
        # prevent, on a different input. check_issue_refs catches it on PRs;
        # this gate is the independent second one, and a CHANGELOG edited on a
        # release branch reaches `gh release create` unvalidated.
        write(self.dir / ".claude-plugin" / "plugin.json",
              json.dumps({"name": "cc-operator", "version": "0.1.0"}))
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [0.1.0] - x\n\n- fixed [#99], defined nowhere\n")
        problems, _ = rg.gate(self.dir, "v0.1.0")
        self.assertTrue(any("[#99]" in p and "no `[#N]: <url>` definition" in p
                            for p in problems), problems)

    def test_partially_defined_refs_ship_the_defined_ones_and_fail(self):
        # A mixed section must not lose the good defs on the way to failing.
        write(self.dir / ".claude-plugin" / "plugin.json",
              json.dumps({"name": "cc-operator", "version": "0.1.0"}))
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [0.1.0] - x\n\n- [#7] and [#99]\n\n"
              "[#7]: https://x/issues/7\n")
        problems, notes = rg.gate(self.dir, "v0.1.0")
        self.assertIn("[#7]: https://x/issues/7", notes)
        self.assertTrue(any("[#99]" in p for p in problems), problems)

    def test_code_span_ref_is_not_treated_as_a_reference(self):
        # Prose documenting the inverted-ref class writes `[#28]` in backticks.
        # Without stripping code spans, the gate would demand a definition for
        # an example — and refuse to publish a correct changelog.
        notes, unresolved = rg.extract_section_checked(
            "# C\n\n## [0.1.0] - x\n\n- the class is `[#28]` quoted\n", "0.1.0")
        self.assertEqual(unresolved, [])
        self.assertEqual(notes, "- the class is `[#28]` quoted")


if __name__ == "__main__":
    unittest.main()
