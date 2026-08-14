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

    # --- a non-empty [Unreleased] must not ship silently (#39) ---------------
    # v0.7.0 published with five subsections of REAL work sitting above the
    # version heading: in the tag, in the squash commit, absent from the release
    # page. Repaired after the fact in 6f92b5d at a cost of 139 changelog lines.
    # Every individual step of the gate was correct — CHANGELOG_HEADING_RE
    # matches `[x.y.z]` by design, so `[Unreleased]` is invisible to it and
    # nothing asked whether content sat above the section being published.

    def test_non_empty_unreleased_refuses_the_tag(self):
        write(self.dir / ".claude-plugin" / "plugin.json",
              json.dumps({"name": "cc-operator", "version": "0.1.0"}))
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [Unreleased]\n\n### Added\n\n- a load-bearing line\n\n"
              "## [0.1.0] - x\n\n### Added\n- the shipped line\n")
        problems, _ = rg.gate(self.dir, "v0.1.0")
        self.assertTrue(any("[Unreleased] is not empty" in p for p in problems),
                        problems)

    def test_whitespace_only_unreleased_stays_green(self):
        # THE CONTROL, and the reason this is not "reject any [Unreleased]": a
        # bare heading with a blank line under it is this file's normal resting
        # state between releases (main's state today). A gate that fired here
        # would be switched off within one release — the vacuous-guard class.
        make(self.dir, "0.1.0", "0.1.0")          # make() writes exactly that
        problems, _ = rg.gate(self.dir, "v0.1.0")
        self.assertEqual(problems, [])

    def test_absent_unreleased_section_stays_green(self):
        # The section is optional. Its absence is not content being dropped.
        write(self.dir / ".claude-plugin" / "plugin.json",
              json.dumps({"name": "cc-operator", "version": "0.1.0"}))
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [0.1.0] - x\n\n### Added\n- thing\n")
        problems, _ = rg.gate(self.dir, "v0.1.0")
        self.assertEqual(problems, [])

    def test_unreleased_check_does_not_eat_the_link_def_block(self):
        # A changelog with NO version below [Unreleased] yet: the section must
        # stop at the `^[` def block, exactly as extract_section does. Reading
        # to EOF would swallow every definition in the file and report the
        # section as permanently non-empty — a gate nobody could ever satisfy.
        self.assertEqual(
            rg.unreleased_body("# C\n\n## [Unreleased]\n\n"
                               "[#1]: https://x/issues/1\n"), "")

    def test_notes_are_not_written_when_unreleased_is_dirty(self):
        # The refusal has to happen BEFORE publication, not alongside it: a
        # non-zero exit with notes already on disk invites a caller to publish
        # them anyway.
        write(self.dir / ".claude-plugin" / "plugin.json",
              json.dumps({"name": "cc-operator", "version": "0.1.0"}))
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [Unreleased]\n\n- pending work\n\n"
              "## [0.1.0] - x\n\n- shipped\n")
        out = self.dir / "notes.md"
        rc = rg.main(["v0.1.0", "--root", str(self.dir),
                      "--notes-out", str(out)])
        self.assertEqual(rc, 1)
        self.assertFalse(out.exists(), "notes were written despite the refusal")

    def test_near_miss_unreleased_headings_are_still_caught(self):
        # A one-character slip in the heading used to return "" — "nothing
        # pending, safe to tag" — with real content sitting underneath, which
        # reopens #39 through a typo instead of an empty section. Nothing
        # downstream catches it: check_changelog validates only the VERSIONED
        # heading. A guard a typo disables is not a guard.
        for heading in ("## [Unreleased]", "##[Unreleased]", " ## [Unreleased]",
                        "## Unreleased", "## [unreleased]", "### Unreleased"):
            with self.subTest(heading=heading):
                body = rg.unreleased_body(
                    f"# C\n\n{heading}\n\n- real pending content\n\n"
                    f"## [0.1.0] - x\n\n- shipped\n")
                self.assertTrue(body, f"{heading!r} read as empty")

    def test_tolerance_does_not_swallow_the_version_heading(self):
        # The looser terminator must still stop at a version heading, or the
        # Unreleased section absorbs the release notes and reads non-empty
        # forever — a gate nobody could satisfy, the same shape as the def-block
        # case above.
        self.assertEqual(
            rg.unreleased_body("# C\n\n## [Unreleased]\n\n## [0.1.0] - x\n\n"
                               "- shipped\n"), "")

    def test_real_repo_gate_passes(self):
        # This repo's own CHANGELOG at its own version — the check must not
        # fire on the tree that ships it.
        version = json.loads(
            (ROOT / ".claude-plugin" / "plugin.json").read_text())["version"]
        problems, _ = rg.gate(ROOT, f"v{version}")
        self.assertEqual(problems, [], problems)

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
