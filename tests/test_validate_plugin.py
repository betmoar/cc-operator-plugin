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


# One CLI per line: the charter now bounds per-line length (F19), so the
# fixture must satisfy CHARTER_MAX_LINE_CHARS like the real charter does.
_CLI_SENTENCE = " — run [DOC:spec-D4]:\n" + "\n".join(
    f"`.operator/bin/{c}`" for c in vp.CHARTER_REQUIRED_CLIS)

GOOD_CHARTER = "# OPERATOR.md\n\n" + "\n".join(
    f"## {sec}\n\nrule [D:tag-{i}] body"
    + (_CLI_SENTENCE if sec == "EVIDENCE GATE" else ".")
    + "\n"
    for i, sec in enumerate(vp.CHARTER_SECTION_ORDER)
)


# Stub scripts that actually SATISFY the guardrail checks. The good tree must
# be clean under every check in vp.CHECKS, not merely under the manifest-shaped
# ones — a fixture that only passes the checks someone remembered to call is
# how three guardrails went unexercised here.
GOOD_STATUSLINE = (
    "#!/usr/bin/env bash\n"
    "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
    "case \"$owner\" in */* | .* | *\"|\"* | *[[:space:]]*) owner=\"\" ;; esac\n")

GOOD_LOCK_BLOCK = (
    "# >>> LOCK BLOCK\n"
    "lock_acquire() { mkdir \"$LOCKDIR\" 2>/dev/null; }\n"
    "lock_release() { rm -f \"$LOCKDIR/holder\"; rmdir \"$LOCKDIR\"; }\n"
    "# <<< LOCK BLOCK\n")


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
    for name, model in (("op-author", "opus"),
                        ("op-mechanic", "sonnet"),
                        ("op-reviewer", "opus")):
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
        "hooks": {
            "Stop": [{"hooks": [{
                "type": "command",
                "command": 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh"',
            }]}],
            "SessionStart": [{"matcher": "startup", "hooks": [{
                "type": "command",
                "command": 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-sessionstart-hook.sh"',
            }]}],
        }
    }))
    write(root / ".claude-plugin" / "statusline.json", json.dumps({
        "name": "cc-operator", "render": "scripts/statusline.sh", "order": 30,
    }))
    for s in ("ops-init.sh", "ops-sessionstart-hook.sh"):
        write(root / "scripts" / s, "#!/usr/bin/env bash\nset -eu\necho ok\n")
    # The readers/CLIs need bodies that satisfy the byte-bound, guard-parity and
    # lock-parity checks — a bare `echo ok` stub fails all three.
    guards = ("check_bare_name() { case \"$2\" in .*) die x ;; esac; }\n"
              "check_owner_name() { :; }\n")
    bounded = "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
    write(root / "scripts" / "ops-stop-hook.sh",
          "#!/usr/bin/env bash\n" + bounded +
          "case \"$owner\" in */* | .* | *\"|\"* | *[[:space:]]*) owner=\"\" ;; esac\n")
    write(root / "scripts" / "ops-task.sh", "#!/usr/bin/env bash\n" + guards)
    write(root / "scripts" / "ops-verdict.sh",
          "#!/usr/bin/env bash\n" + guards + bounded +
          "while IFS= read -r -n 512 row; do :; done < \"$frag\"\n" +
          GOOD_LOCK_BLOCK)
    write(root / "scripts" / "ops-adopt.sh",
          "#!/usr/bin/env bash\n" + guards + bounded + GOOD_LOCK_BLOCK)
    write(root / "scripts" / "statusline.sh", GOOD_STATUSLINE)
    # Every shipped slash command: frontmatter the harness registers it by,
    # and plugin-root script paths (a bare scripts/ path resolves only inside
    # this repo — the v0.2.0 blocked-start bug check_commands exists for).
    for name in ("start", "handoff"):
        write(root / "commands" / f"{name}.md", textwrap.dedent(f"""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Bash(bash:*), Read, Write, Edit
            ---
            Run `bash "${{CLAUDE_PLUGIN_ROOT}}/scripts/ops-init.sh"`.
            """))
    # Two workflow fixtures carrying the shared tier-validation invariants
    # identically (ROUTABLE + BAD_CHARSET byte-equal, KNOWN_TIERS = resolver's
    # TIER_NAMES) so check_workflows, check_workflow_parity, and
    # check_workflow_tier_namespace pass on the good tree. The sandbox forbids
    # imports, so the block is copy-pasted; parity + namespace-equality are the
    # only things holding it together.
    write(root / "scripts" / "ops-tiers.sh",
          'TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON"\n'
          '# minimal stub; one byte-bounded read satisfies check_reader_bounds\n'
          'while IFS= read -r -n 512 line; do :; done < "$1"\n')
    # ops-render.sh ships alongside the resolver; a stub with one bounded read
    # satisfies check_scripts (bash -n) and check_reader_bounds.
    write(root / "scripts" / "ops-render.sh",
          '# stub renderer\n'
          'while IFS= read -r -n 256 line; do :; done\n')
    # The renderer splices a model: id into each template; default.tmpl must
    # carry a model: line or check_render_templates fires.
    write(root / "agents" / "_templates" / "default.tmpl",
          '---\nname: op-NAME\nmodel: MODEL\ntools: Read\n---\nbody\n')
    WF_SHARED = (
        'const ROUTABLE = /^glm-|\\/|^claude-/;\n'
        'const BAD_CHARSET = /[^\\w./:@[\\]-]/;\n'
        'const KNOWN_TIERS = ["JUDGMENT","IMPLEMENT","MECHANICAL","RECON"];\n'
        'for (const [n, id] of Object.entries({JUDGMENT:"claude-opus-5"})) {\n'
        '  if (!ROUTABLE.test(id) || BAD_CHARSET.test(id)) throw new Error("bad");\n'
        '}\n'
    )
    for wname in ("review", "brainstorm"):
        write(root / "workflows" / f"{wname}.js",
              f'export const meta = {{ name: "{wname}", description: "d" }};\n' + WF_SHARED)


class ValidatorTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def problems(self):
        # Iterate vp.CHECKS rather than re-listing the checks here. The old
        # hand-copied list had silently fallen three behind the build
        # (check_reader_bounds, check_guard_parity, check_lock_parity), so
        # test_good_tree_is_clean — the assertion a reader trusts most — was
        # not exercising them at all.
        probs = []
        for check in vp.CHECKS:
            check(self.dir, probs)
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

    def test_charter_missing_project_cli_path(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER.replace(".operator/bin/ops-verdict.sh",
                                   "scripts/ops-verdict.sh"))
        self.assertFires(".operator/bin/ops-verdict.sh")

    def test_charter_missing_adopt_cli_path(self):
        # Every CLI ops-init installs must be reachable from the charter —
        # ops-adopt.sh is the /clear recovery path and was the one most likely
        # to be shipped without a charter reference.
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER.replace(".operator/bin/ops-adopt.sh", "ops-adopt.sh"))
        self.assertFires(".operator/bin/ops-adopt.sh")

    # --- 5. ledger schema ---
    def test_verdicts_header_wrong(self):
        write(self.dir / "templates" / "VERDICTS-header.md",
              "# V\n| Gate | Criterion | Evidence (cmd) | PASS/FAIL |\n")
        self.assertFires("byte-match")

    # --- 6. agents ---
    def test_agent_missing_model(self):
        p = self.dir / "agents" / "op-author.md"
        write(p, p.read_text().replace("model: opus\n", ""))
        self.assertFires("missing 'model:'")

    def test_agent_pinned_model_id(self):
        p = self.dir / "agents" / "op-mechanic.md"
        write(p, p.read_text().replace("model: sonnet", "model: claude-sonnet-4-6"))
        self.assertFires("pinned ID")

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

    def test_sessionstart_hook_missing(self):
        # Without it the agent never learns its session id, so every sentinel
        # is opened unowned and blocks every concurrent session.
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        del d["hooks"]["SessionStart"]
        write(p, json.dumps(d))
        self.assertFires("no SessionStart hook command found")

    def test_sessionstart_hook_not_plugin_root(self):
        p = self.dir / "hooks" / "hooks.json"
        d = json.loads(p.read_text())
        d["hooks"]["SessionStart"][0]["hooks"][0]["command"] = \
            "bash scripts/ops-sessionstart-hook.sh"
        write(p, json.dumps(d))
        self.assertFires("SessionStart command should use")

    # --- 8. scripts ---
    def test_script_syntax_error(self):
        write(self.dir / "scripts" / "ops-init.sh",
              "#!/usr/bin/env bash\nif then fi oops(\n")
        self.assertFires("syntax error")

    def test_script_missing(self):
        (self.dir / "scripts" / "ops-verdict.sh").unlink()
        self.assertFires("scripts/ops-verdict.sh: missing")

    def test_ops_task_missing(self):
        (self.dir / "scripts" / "ops-task.sh").unlink()
        self.assertFires("scripts/ops-task.sh: missing")

    def test_ops_adopt_missing(self):
        (self.dir / "scripts" / "ops-adopt.sh").unlink()
        self.assertFires("scripts/ops-adopt.sh: missing")

    def test_ops_sessionstart_hook_missing(self):
        (self.dir / "scripts" / "ops-sessionstart-hook.sh").unlink()
        self.assertFires("scripts/ops-sessionstart-hook.sh: missing")

    # --- 8b. the statusline manifest ---
    # cc-status discovers the segment ONLY through this manifest and skips an
    # unresolvable renderer silently — no error, the segment just never appears
    # and the bar looks like a project with no open tasks. Nothing else in the
    # build would notice, which is exactly why it is a checked contract.

    def test_statusline_manifest_missing(self):
        (self.dir / ".claude-plugin" / "statusline.json").unlink()
        self.assertFires("statusline.json: missing")

    def test_statusline_render_path_does_not_resolve(self):
        write(self.dir / ".claude-plugin" / "statusline.json", json.dumps({
            "name": "cc-operator", "render": "scripts/moved.sh", "order": 30,
        }))
        self.assertFires("does not resolve")

    def test_statusline_name_mismatch(self):
        write(self.dir / ".claude-plugin" / "statusline.json", json.dumps({
            "name": "cc-operatorr", "render": "scripts/statusline.sh",
        }))
        self.assertFires("the key users toggle")

    def test_statusline_order_not_an_integer(self):
        write(self.dir / ".claude-plugin" / "statusline.json", json.dumps({
            "name": "cc-operator", "render": "scripts/statusline.sh",
            "order": "30",
        }))
        self.assertFires("is not an integer")

    def test_statusline_reader_bound_is_enforced(self):
        # The segment renders on a ~300ms timer, so a lost byte bound is a
        # permanently wedged bar (6.20s per parse on a 64MB single-line
        # sentinel, measured), not merely a slow one. It is registered in
        # check_reader_bounds alongside the three once-per-event readers.
        write(self.dir / "scripts" / "statusline.sh",
              '#!/usr/bin/env bash\nwhile IFS= read -r line; do :; done < "$1"\n')
        self.assertFires("scripts/statusline.sh")

    # --- 9/10. audit guardrails: reader bounds + guard parity ---
    # These enforce cross-file couplings that were previously prose in CLAUDE.md
    # and were still violated: the byte bound reached one of four readers, and a
    # guard applied to the wrong one of two name-checks wedged legacy tasks.

    def _write_readers(self, verdict_body=None, adopt_body=None, hook_body=None):
        """Install minimal but realistic reader scripts into the fixture tree."""
        good_hook = (
            "#!/usr/bin/env bash\n"
            "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
            "case \"$owner\" in */* | .* | *\"|\"* | *[[:space:]]*) owner=\"\" ;; esac\n")
        good_verdict = (
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "while IFS= read -r -n 512 line; do :; done < \"$f\"\n"
            "while IFS= read -r -n 512 row; do :; done < \"$frag\"\n")
        good_adopt = (
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "while IFS= read -r -n 512 line; do :; done < \"$F\"\n")
        write(self.dir / "scripts" / "ops-stop-hook.sh", hook_body or good_hook)
        write(self.dir / "scripts" / "ops-verdict.sh", verdict_body or good_verdict)
        write(self.dir / "scripts" / "ops-adopt.sh", adopt_body or good_adopt)
        write(self.dir / "scripts" / "ops-task.sh",
              "#!/usr/bin/env bash\n"
              "check_bare_name() { case \"$2\" in .*) die x ;; esac; }\n"
              "check_owner_name() { :; }\n")
        write(self.dir / "scripts" / "statusline.sh", GOOD_STATUSLINE)

    def bounds_problems(self):
        probs = []
        vp.check_reader_bounds(self.dir, probs)
        vp.check_guard_parity(self.dir, probs)
        return probs

    def test_reader_bounds_clean_tree_passes(self):
        self._write_readers()
        self.assertEqual(self.bounds_problems(), [])

    def test_unbounded_read_fires(self):
        self._write_readers(verdict_body=(
            "#!/usr/bin/env bash\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "while IFS= read -r line; do :; done < \"$f\"\n"
            "while IFS= read -r -n 512 row; do :; done < \"$frag\"\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("unbounded `read -r`" in p for p in probs), probs)

    def test_comments_mentioning_read_do_not_fire(self):
        # A checker that fires on its own documentation trains the maintainer to
        # ignore the build. This exact bug was introduced and caught in the audit.
        self._write_readers(adopt_body=(
            "#!/usr/bin/env bash\n"
            "# `read -r` is bounded by LINES, not bytes — discussion only.\n"
            "#    a plain read -r would slurp the whole line first\n"
            "check_bare_name() { case \"$2\" in .*) die x ;; esac; }\n"
            "check_owner_name() { :; }\n"
            "while IFS= read -r -n 512 line; do :; done < \"$F\"\n"))
        self.assertEqual(self.bounds_problems(), [])

    def test_missing_guard_in_one_cli_fires(self):
        self._write_readers()
        write(self.dir / "scripts" / "ops-task.sh",
              "#!/usr/bin/env bash\ncheck_bare_name() { case \"$2\" in .*) die x ;; esac; }\n")
        probs = self.bounds_problems()
        self.assertTrue(any("missing check_owner_name()" in p for p in probs), probs)

    def test_hook_dropping_whitespace_reject_fires(self):
        self._write_readers(hook_body=(
            "#!/usr/bin/env bash\n"
            "while IFS= read -r -n 512 line; do :; done < \"$1\"\n"
            "case \"$owner\" in */* | .* | *\"|\"*) owner=\"\" ;; esac\n"))
        probs = self.bounds_problems()
        self.assertTrue(any("whitespace owners" in p for p in probs), probs)

    # --- 11. slash commands ---
    # The plugin's entry points are its slash commands. An empty frontmatter
    # block, a missing key, or a bare scripts/ path are all silent shipping
    # bugs — the command either won't register or will fail in a target project.

    def test_commands_dir_optional(self):
        # A plugin that ships only agents need not have commands/. The good-tree
        # fixture builds one; removing it must stay clean (the check treats
        # absence as "not applicable", not as a defect).
        shutil.rmtree(self.dir / "commands")
        self.assertEqual(self.problems(), [])

    def test_empty_commands_dir_fires(self):
        for f in (self.dir / "commands").glob("*.md"):
            f.unlink()
        self.assertFires("holds no *.md")

    def test_command_without_frontmatter_fires(self):
        write(self.dir / "commands" / "start.md", "Body only, no frontmatter.\n")
        self.assertFires("no `---` frontmatter block")

    def test_command_missing_required_key_fires(self):
        write(self.dir / "commands" / "start.md", textwrap.dedent("""\
            ---
            description: d
            allowed-tools: Bash(bash:*)
            ---
            Body.
            """))
        self.assertFires("missing required key 'argument-hint'")

    def test_command_empty_argument_hint_is_valid(self):
        # argument-hint: [] is a legitimate empty value (handoff.md uses it).
        write(self.dir / "commands" / "handoff.md", textwrap.dedent("""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Read
            ---
            Body.
            """))
        self.assertNotIn("argument-hint", " ".join(self.problems()))

    def test_command_relative_script_path_fires(self):
        write(self.dir / "commands" / "start.md", textwrap.dedent("""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Bash(bash:*)
            ---
            Run `bash scripts/ops-init.sh`.
            """))
        self.assertFires("without ${CLAUDE_PLUGIN_ROOT}")

    def test_command_plugin_root_path_is_valid(self):
        # The layout-independent form must NOT fire — the whole point of the
        # check is to steer toward this, not forbid script invocation outright.
        write(self.dir / "commands" / "start.md", textwrap.dedent("""\
            ---
            description: d
            argument-hint: []
            allowed-tools: Bash(bash:*)
            ---
            Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-init.sh"`.
            """))
        self.assertNotIn("CLAUDE_PLUGIN_ROOT", " ".join(
            p for p in self.problems() if "commands/" in p))

    def test_real_commands_are_clean(self):
        # Guards the shipped tree, not just a fixture.
        probs = []
        vp.check_commands(ROOT, probs)
        self.assertEqual(probs, [])

    # --- 12. workflows: meta-first, ROUTABLE canonical+applied, charset, parity ---
    # check_workflows validates the tier-guard infrastructure per file; the audit
    # (2026-07-30) added BAD_CHARSET so JS and shell agree on the model-id
    # charset (audit F01 — JS ROUTABLE accepted whitespace the shell rejects).
    # check_workflow_parity holds the copy-pasted block together (the sandbox
    # forbids imports, measured), so a regex divergence between workflows fails.

    def _wf(self, name, body_extra=""):
        """A conforming workflow with the shared invariants."""
        return (
            f'export const meta = {{ name: "{name}", description: "d" }};\n'
            'const ROUTABLE = /^glm-|\\/|^claude-/;\n'
            'const BAD_CHARSET = /[^\\w./:@[\\]-]/;\n'
            'for (const [n, id] of Object.entries({JUDGMENT:"claude-opus-5"})) {\n'
            '  if (!ROUTABLE.test(id) || BAD_CHARSET.test(id)) throw new Error("x");\n'
            '}\n' + body_extra
        )

    def test_workflow_missing_meta_first_fires(self):
        write(self.dir / "workflows" / "review.js",
              '// stray comment\n' + self._wf("review"))
        self.assertFires("does not begin with")

    def test_workflow_divergent_routable_fires(self):
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace("const ROUTABLE = /^glm-|\\/|^claude-/;",
                                         "const ROUTABLE = /^glm-5|^claude-5/;"))
        self.assertFires("ROUTABLE regex is")

    def test_workflow_routable_never_applied_fires(self):
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace("ROUTABLE.test(id)", "true"))
        self.assertFires("ROUTABLE is declared but never applied")

    def test_workflow_parity_holds_on_good_tree(self):
        # make_good_tree writes two workflows with identical ROUTABLE/BAD_CHARSET.
        probs = []
        vp.check_workflow_parity(self.dir, probs)
        self.assertEqual(probs, [])

    def test_workflow_parity_diverged_bad_charset_fires(self):
        # Diverge BAD_CHARSET in one workflow only — the audit F01 fix's lock.
        write(self.dir / "workflows" / "review.js",
              self._wf("review").replace("const BAD_CHARSET = /[^\\w./:@[\\]-]/;",
                                         "const BAD_CHARSET = /[^\\w./:@-]/;"))
        probs = []
        vp.check_workflow_parity(self.dir, probs)
        self.assertTrue(any("BAD_CHARSET has diverged" in p for p in probs), probs)

    def test_real_workflows_pass_all_checks(self):
        # Guards the shipped tree, not just a fixture.
        probs = []
        vp.check_workflows(ROOT, probs)
        vp.check_workflow_parity(ROOT, probs)
        vp.check_workflow_tier_namespace(ROOT, probs)
        vp.check_workflow_agent_types(ROOT, probs)
        self.assertEqual(probs, [])

    # --- workflow agentType resolution (F22) ---
    # A workflow agentType resolves against the PLUGIN registry; a rendered
    # project-layer agent cannot be named there. crawl.js shipped dispatching
    # op-scout while claiming op-crawler — which did not exist as an agent.

    def test_workflow_agent_type_unshipped_fires(self):
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              'const KNOWN_TIERS = ["JUDGMENT","IMPLEMENT","MECHANICAL","RECON"];\n'
              'agent("x", { agentType: "cc-operator:op-ghost" });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertTrue(any("op-ghost" in p and "names no shipped agent" in p
                            for p in probs), probs)

    def test_workflow_agent_type_shipped_is_clean(self):
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              'const KNOWN_TIERS = ["JUDGMENT","IMPLEMENT","MECHANICAL","RECON"];\n'
              'agent("x", { agentType: "cc-operator:op-author" });\n')
        probs = []
        vp.check_workflow_agent_types(self.dir, probs)
        self.assertEqual(probs, [])

    # --- charter byte bounds (F19) ---
    # The 150-line cap bounds ALWAYS-ON tokens; a line-count-only gate is
    # gameable by packing prose into one long line (a 286-char line shipped
    # through a green validator). Non-table lines are length-bounded; table
    # rows (|-prefixed) are exempt; the file has a total-bytes ceiling.

    def test_charter_packed_line_fires(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER + "\npacked rule [D:tag-x] " + "y" * 120 + "\n")
        probs = []
        vp.check_charter(self.dir, probs)
        self.assertTrue(any("char line" in p for p in probs), probs)

    def test_charter_long_table_row_is_exempt(self):
        write(self.dir / "templates" / "OPERATOR.md",
              GOOD_CHARTER + "\n| cap | " + "y" * 120 + " | act [D:tag-t] |\n")
        probs = []
        vp.check_charter(self.dir, probs)
        self.assertFalse(any("char line" in p for p in probs), probs)

    def test_charter_byte_ceiling_fires(self):
        filler = "\n".join(f"r{i} [D:tag-f] " + "z" * 90 for i in range(95))
        write(self.dir / "templates" / "OPERATOR.md", GOOD_CHARTER + "\n" + filler)
        probs = []
        vp.check_charter(self.dir, probs)
        self.assertTrue(any("ceiling" in p for p in probs), probs)

    # --- 13. workflow tier namespace: KNOWN_TIERS == resolver TIER_NAMES (F07) ---
    # A workflow must accept every tier the resolver may emit, else forwarding
    # the resolver's full map throws on a valid-but-unused key (F07 — the prior
    # F03 fix removed a workflow's IMPLEMENT declaration and broke this).

    def test_workflow_missing_known_tiers_fires(self):
        # A conforming workflow that omits KNOWN_TIERS entirely.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              'const ROUTABLE = /^glm-|\\/|^claude-/;\n'
              'const BAD_CHARSET = /[^\\w./:@[\\]-]/;\n'
              'for (const [n, id] of Object.entries({JUDGMENT:"claude-opus-5"})) {\n'
              '  if (!ROUTABLE.test(id)) throw new Error("x");\n'
              '}\n')
        probs = []
        vp.check_workflow_tier_namespace(self.dir, probs)
        self.assertTrue(any("no `const KNOWN_TIERS" in p for p in probs), probs)

    def test_workflow_known_tiers_diverges_from_resolver_fires(self):
        # KNOWN_TIERS omits IMPLEMENT, which the resolver's TIER_NAMES emits.
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              'const KNOWN_TIERS = ["JUDGMENT","MECHANICAL","RECON"];\n')
        probs = []
        vp.check_workflow_tier_namespace(self.dir, probs)
        self.assertTrue(any("does not match the resolver's" in p for p in probs), probs)

    def test_workflow_tier_namespace_holds_on_good_tree(self):
        probs = []
        vp.check_workflow_tier_namespace(self.dir, probs)
        self.assertEqual(probs, [])

    def test_resolver_tier_names_unreadable_fails_loud(self):
        # F2/F3 fix: a legal rewrite of TIER_NAMES that the regex can't read must
        # FAIL LOUD, not silently disable the namespace check (fail-open). Single
        # quotes are accepted; a genuinely unreadable form (no assignment) fires.
        write(self.dir / "scripts" / "ops-tiers.sh",
              "TIER_NAMES='JUDGMENT IMPLEMENT MECHANICAL RECON'\n")
        probs = []
        vp.check_workflow_tier_namespace(self.dir, probs)  # single-quote: accepted, no problem
        self.assertFalse(any("unreadable" in p for p in probs), probs)
        # A form the regex cannot read at all → fail loud.
        write(self.dir / "scripts" / "ops-tiers.sh",
              ' tiers=(JUDGMENT IMPLEMENT MECHANICAL RECON)\n')
        probs = []
        vp.check_workflow_tier_namespace(self.dir, probs)
        self.assertTrue(any("unreadable" in p for p in probs), probs)

    def test_known_tiers_only_in_comment_fires(self):
        # F4 fix: a KNOWN_TIERS appearing only in a comment must not satisfy the
        # check (matches check_reader_bounds' code-only convention).
        write(self.dir / "workflows" / "review.js",
              'export const meta = { name: "review", description: "d" };\n'
              '// const KNOWN_TIERS = ["JUDGMENT","IMPLEMENT","MECHANICAL","RECON"];\n')
        probs = []
        vp.check_workflow_tier_namespace(self.dir, probs)
        self.assertTrue(any("no `const KNOWN_TIERS" in p for p in probs), probs)


class RenderTemplateTest(unittest.TestCase):
    """ops-render.sh splices a model id into each template's model: line. A
    template without one produces an agent silently bound to the default
    backend — the splice lands nowhere."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        make_good_tree(self.dir)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_good_tree_templates_clean(self):
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertEqual(probs, [])

    def test_template_without_model_line_fires(self):
        write(self.dir / "agents" / "_templates" / "default.tmpl",
              '---\nname: op-NAME\ntools: Read\n---\nbody\n')
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertTrue(any("no `model:` frontmatter line" in p for p in probs), probs)

    def test_renderer_without_templates_fires(self):
        import shutil as _sh
        _sh.rmtree(self.dir / "agents" / "_templates")
        probs = []
        vp.check_render_templates(self.dir, probs)
        self.assertTrue(any("no *.tmpl found" in p for p in probs), probs)


class LockParityTest(unittest.TestCase):
    """The shared lock block must be identical in both writers.

    The guardrail exists because "keep the two implementations identical" was
    prose for the whole 0.4.0 cycle, and prose does not hold couplings — the
    same lesson `check_reader_bounds` was written for.
    """

    BLOCK = (
        "# >>> LOCK BLOCK\n"
        "LOCK_SPINS=300\n"
        "lock_acquire() {\n"
        '  echo "TOOL: warning — reclaiming" >&2\n'
        "}\n"
        "# <<< LOCK BLOCK\n"
    )

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        (self.dir / "scripts").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _write(self, verdict=None, adopt=None):
        v = self.BLOCK.replace("TOOL:", "ops-verdict:") if verdict is None else verdict
        a = self.BLOCK.replace("TOOL:", "ops-adopt:") if adopt is None else adopt
        write(self.dir / "scripts" / "ops-verdict.sh", "#!/usr/bin/env bash\n" + v)
        write(self.dir / "scripts" / "ops-adopt.sh", "#!/usr/bin/env bash\n" + a)

    def problems(self):
        probs = []
        vp.check_lock_parity(self.dir, probs)
        return probs

    def test_identical_blocks_pass(self):
        # The tool name in warnings is the ONE legitimate difference.
        self._write()
        self.assertEqual(self.problems(), [])

    def test_drifted_logic_fires(self):
        self._write(adopt=self.BLOCK.replace("TOOL:", "ops-adopt:")
                    .replace("LOCK_SPINS=300", "LOCK_SPINS=100"))
        probs = self.problems()
        self.assertTrue(any("drifted" in p for p in probs), probs)
        self.assertTrue(any("LOCK_SPINS" in p for p in probs), probs)

    def test_missing_markers_fire(self):
        self._write(adopt="lock_acquire() { :; }\n")
        probs = self.problems()
        self.assertTrue(any("LOCK BLOCK" in p for p in probs), probs)

    def test_real_scripts_are_in_parity(self):
        # Guards the shipped tree, not just a fixture.
        probs = []
        vp.check_lock_parity(ROOT, probs)
        self.assertEqual(probs, [])


if __name__ == "__main__":
    unittest.main()
