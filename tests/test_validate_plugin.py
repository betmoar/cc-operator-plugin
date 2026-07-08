"""Each validate_plugin check must FIRE on a broken fixture and PASS on a good
tree. We build a minimal valid repo in a tmpdir, assert it is clean, then break
one contract at a time and assert the specific failure surfaces.
"""
import json
import pathlib
import shutil
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import validate_plugin as vp  # noqa: E402


GOOD_CHARTER = "# OPERATOR.md\n\n" + "\n".join(
    f"## {sec}\n\nrule [D:tag-{i}] body.\n"
    for i, sec in enumerate(vp.CHARTER_SECTION_ORDER)
)


def write(p, text):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


def make_good_tree(root):
    write(root / ".claude-plugin" / "plugin.json", json.dumps({
        "name": "cc-operator", "version": "0.1.0",
        "description": "d", "license": "MIT",
    }))
    write(root / ".claude-plugin" / "marketplace.json", json.dumps({
        "name": "cc-operator-plugin", "owner": {"name": "b"},
        "plugins": [{"name": "cc-operator", "source": "./", "description": "d"}],
    }))
    write(root / "CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-07-06\n\n- init\n")
    write(root / "templates" / "OPERATOR.md", GOOD_CHARTER)
    write(root / "templates" / "VERDICTS-header.md",
          "# Verdicts\n" + vp.VERDICTS_HEADER + "\n|---|---|---|---|\n")
    for name, model in (("op-author", "claude-opus-4-8"),
                        ("op-mechanic", "claude-sonnet-4-6"),
                        ("op-reviewer", "claude-opus-4-8")):
        tools = ("Read, Grep, Glob, Bash" if name == "op-reviewer"
                 else "Read, Write, Edit, Grep, Glob, Bash")
        write(root / "agents" / f"{name}.md", textwrap.dedent(f"""\
            ---
            name: {name}
            description: d
            model: {model}
            tools: {tools}
            ---
            Body. End with NEEDS_CONTEXT when underspecified.
            """))
    write(root / "hooks" / "hooks.json", json.dumps({
        "hooks": {"Stop": [{"hooks": [{
            "type": "command",
            "command": 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh"',
        }]}]}
    }))
    for s in ("ops-init.sh", "ops-verdict.sh", "ops-stop-hook.sh"):
        write(root / "scripts" / s, "#!/usr/bin/env bash\nset -eu\necho ok\n")


class ValidatorTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def problems(self):
        probs = []
        vp.check_manifests(self.dir, probs)
        vp.check_changelog(self.dir, probs)
        vp.check_charter(self.dir, probs)
        vp.check_ledger_schema(self.dir, probs)
        vp.check_agents(self.dir, probs)
        vp.check_hook(self.dir, probs)
        vp.check_scripts(self.dir, probs)
        return probs

    def assertFires(self, needle):
        probs = self.problems()
        self.assertTrue(any(needle in p for p in probs),
                        f"expected a problem containing {needle!r}; got {probs}")

    # --- baseline ---
    def test_good_tree_is_clean(self):
        self.assertEqual(self.problems(), [])

    # --- 1. manifests ---
    def test_wrong_plugin_name(self):
        p = self.dir / ".claude-plugin" / "plugin.json"
        d = json.loads(p.read_text()); d["name"] = "operator"; write(p, json.dumps(d))
        self.assertFires("name is")

    def test_non_semver_version(self):
        p = self.dir / ".claude-plugin" / "plugin.json"
        d = json.loads(p.read_text()); d["version"] = "1.0"; write(p, json.dumps(d))
        self.assertFires("not semver")

    def test_wrong_marketplace_source(self):
        p = self.dir / ".claude-plugin" / "marketplace.json"
        d = json.loads(p.read_text()); d["plugins"][0]["source"] = "./operator"
        write(p, json.dumps(d))
        self.assertFires("source is")

    # --- 3. changelog sync ---
    def test_changelog_not_newest(self):
        write(self.dir / "CHANGELOG.md",
              "# C\n\n## [Unreleased]\n\n## [0.2.0]\n\n## [0.1.0]\n")
        self.assertFires("newest versioned heading")

    def test_changelog_missing(self):
        (self.dir / "CHANGELOG.md").unlink()
        self.assertFires("CHANGELOG.md: missing")

    # --- 4. charter gates ---
    def test_charter_too_long(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER + "\nx" * (vp.CHARTER_MAX_LINES + 5))
        self.assertFires("cap")

    def test_charter_section_order(self):
        scrambled = "# OPERATOR.md\n\n" + "\n".join(
            f"## {sec}\n\nrule [D:t{i}].\n"
            for i, sec in enumerate(reversed(vp.CHARTER_SECTION_ORDER)))
        write(self.dir / "templates" / "OPERATOR.md", scrambled)
        self.assertFires("section order")

    def test_charter_untagged_section(self):
        bad = "# OPERATOR.md\n\n" + "".join(
            (f"## {sec}\n\nrule [D:t{i}].\n" if sec != "HANDOFF"
             else f"## {sec}\n\nno tag here.\n")
            for i, sec in enumerate(vp.CHARTER_SECTION_ORDER))
        write(self.dir / "templates" / "OPERATOR.md", bad)
        self.assertFires("no citation tag")

    # --- 5. ledger schema ---
    def test_verdicts_header_wrong(self):
        write(self.dir / "templates" / "VERDICTS-header.md",
              "# V\n| Gate | Criterion | Evidence (cmd) | PASS/FAIL |\n")
        self.assertFires("byte-match")

    # --- 6. agents ---
    def test_agent_missing_model(self):
        p = self.dir / "agents" / "op-author.md"
        write(p, p.read_text().replace("model: claude-opus-4-8\n", ""))
        self.assertFires("missing 'model:'")

    def test_agent_missing_needs_context(self):
        p = self.dir / "agents" / "op-mechanic.md"
        write(p, p.read_text().replace("NEEDS_CONTEXT", "just-guess"))
        self.assertFires("NEEDS_CONTEXT")

    def test_agent_build_naming(self):
        p = self.dir / "agents" / "op-reviewer.md"
        write(p, p.read_text() + "\nRefer to the unknowns-harness F1 finding.\n")
        self.assertFires("build-specific naming")

    # --- 7. hook ---
    def test_hook_wrong_command(self):
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["Stop"][0]["hooks"][0]["command"] = "bash other.sh"
        write(p, json.dumps(d))
        self.assertFires("ops-stop-hook.sh")

    # --- 8. scripts ---
    def test_script_syntax_error(self):
        write(self.dir / "scripts" / "ops-init.sh",
              "#!/usr/bin/env bash\nif then fi oops(\n")
        self.assertFires("syntax error")

    def test_script_missing(self):
        (self.dir / "scripts" / "ops-verdict.sh").unlink()
        self.assertFires("scripts/ops-verdict.sh: missing")


if __name__ == "__main__":
    unittest.main()
