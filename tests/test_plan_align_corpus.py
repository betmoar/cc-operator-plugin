"""Pins the discriminating property of the plan-alignment corpus (#58).

The corpus measures whether a per-task vet lens can notice that a task SET
misses a stated goal. That question is only asked if every individual task is
sound — a misaligned column containing an infeasible or untestable task would be
measuring what `plan.js` already blocks, and would score a "detection" that is
really the existing gate firing. So the top-left cell of the corpus's 2x2 ("every
task feasible / testable: yes, in BOTH columns") is not an assertion in a README,
it is enforced here.

Read `tests/fixtures/plan-align/README.md` first; this file enforces what that
one claims. Every check carries a control, because a scanner that cannot see a
violation reports every column clean — the same value that means correct.
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "tests" / "fixtures" / "plan-align"
CONTROL = CORPUS / "aligned.json"
# Generated from the control by the same script, so their shared prefix is
# byte-identical BY CONSTRUCTION. adjacent-deliverable is hand-written (its tasks
# are a different flow entirely) and is deliberately absent from this list.
GENERATED = ("missing-final-step", "unverifiable-goal")
SHARED_PREFIX = ("reset-token-store", "reset-request", "reset-email-copy",
                 "reset-token-validate")
# A task reaches a lens as inline JSON, so no task object may name its own
# column — that would tell the seat the answer, which is what the other two
# corpora spend a whole neutralization step avoiding.
LEAK_TOKENS = ("aligned", "misaligned", "fixture", "northstar", "north star")
REQUIRED_NONEMPTY = ("id", "title", "files", "produces", "specExcerpt", "testCycle")
# An identifier a `consumes` may legitimately name: `foo(` in a produces string,
# or a name defined in the fixture project.
IDENT_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\b")


def columns():
    """(label, parsed) for the control and every misaligned column."""
    out = [("aligned", json.loads(CONTROL.read_text(encoding="utf-8")))]
    for d in sorted(p for p in CORPUS.iterdir() if p.is_dir() and p.name != "project"):
        f = d / "misaligned.json"
        if f.is_file():
            out.append((d.name, json.loads(f.read_text(encoding="utf-8"))))
    return out


def project_identifiers():
    """Names defined in the fixture project — the dependencies a first task may
    consume without any earlier task producing them."""
    names = set()
    for py in sorted((CORPUS / "project").rglob("*.py")):
        for m in re.finditer(r"^\s*(?:def|class)\s+([A-Za-z_]\w*)", py.read_text(encoding="utf-8"), re.M):
            names.add(m.group(1))
        for m in re.finditer(r"^\s{4}([a-z_]\w*)\s*:", py.read_text(encoding="utf-8"), re.M):
            names.add(m.group(1))  # dataclass fields
    return names


class PlanAlignCorpusTest(unittest.TestCase):

    def test_corpus_exists_with_a_control_and_misaligned_columns(self):
        # Guards against the whole file passing vacuously if the corpus moves:
        # every loop below iterates columns(), and an empty corpus satisfies
        # "all tasks are sound" perfectly.
        cols = columns()
        labels = [c[0] for c in cols]
        self.assertIn("aligned", labels)
        self.assertGreaterEqual(len(cols), 4, labels)
        for _, col in cols:
            self.assertTrue(col.get("tasks"), labels)

    def test_every_task_in_every_column_is_individually_sound(self):
        for label, col in columns():
            for task in col["tasks"]:
                for field in REQUIRED_NONEMPTY:
                    self.assertTrue(task.get(field),
                                    f"{label}/{task.get('id')}: empty {field}")
                self.assertTrue(task.get("steps"),
                                f"{label}/{task.get('id')}: no steps")

    def test_every_testcycle_names_a_command_and_an_expected_output(self):
        # `testable` is exactly this question, and the corpus needs the answer to
        # be yes in both columns: a vague criterion would be caught by the
        # shipped testability lens and score as a false detection.
        for label, col in columns():
            for task in col["tasks"]:
                tc = task["testCycle"]
                self.assertIn("python3", tc, f"{label}/{task['id']}: no command in testCycle")
                self.assertIn("→", tc, f"{label}/{task['id']}: no expected output in testCycle")
                self.assertTrue(tc.split("→", 1)[1].strip(),
                                f"{label}/{task['id']}: expected-output side is empty")

    def test_every_consumes_resolves_to_the_project_or_an_earlier_task(self):
        # A dangling dependency is `feasibility`'s existing question ("is the
        # dependency it consumes actually produced by an earlier task?"), so a
        # column containing one is not measuring alignment.
        known = project_identifiers()
        for label, col in columns():
            available = set(known)
            for task in col["tasks"]:
                consumes = (task.get("consumes") or "").strip()
                if consumes:
                    named = set(IDENT_RE.findall(consumes))
                    self.assertTrue(named & available,
                                    f"{label}/{task['id']}: consumes names nothing produced "
                                    f"earlier or present in project/: {consumes!r}")
                available |= set(IDENT_RE.findall(task["produces"]))

    def test_generated_columns_share_a_byte_identical_prefix_with_the_control(self):
        ctl = {t["id"]: t for t in json.loads(CONTROL.read_text(encoding="utf-8"))["tasks"]}
        for shape in GENERATED:
            got = {t["id"]: t for t in json.loads(
                (CORPUS / shape / "misaligned.json").read_text(encoding="utf-8"))["tasks"]}
            for tid in SHARED_PREFIX:
                self.assertIn(tid, got, f"{shape}: missing shared task {tid}")
                self.assertEqual(json.dumps(got[tid], sort_keys=True),
                                 json.dumps(ctl[tid], sort_keys=True),
                                 f"{shape}/{tid} diverged from the control — the corpus's "
                                 f"claim that per-task verdicts are identical across columns "
                                 f"by construction no longer holds")

    def test_identity_check_would_notice_a_real_difference(self):
        # Control for the test above: if the comparison could not see a change,
        # it would report every column identical, which is also what clean looks
        # like. Mutate in memory and require the comparison to fail.
        ctl = {t["id"]: t for t in json.loads(CONTROL.read_text(encoding="utf-8"))["tasks"]}
        mutated = json.loads(json.dumps(ctl["reset-request"]))
        mutated["produces"] = mutated["produces"] + " (mutant)"
        self.assertNotEqual(json.dumps(mutated, sort_keys=True),
                            json.dumps(ctl["reset-request"], sort_keys=True))

    def test_no_task_object_leaks_its_column(self):
        for label, col in columns():
            for task in col["tasks"]:
                blob = json.dumps(task).lower()
                for token in LEAK_TOKENS:
                    self.assertNotIn(token, blob,
                                     f"{label}/{task['id']}: leaks {token!r} to a seat — the "
                                     f"task object is what gets serialized into the prompt")

    def test_leak_scanner_would_notice_a_planted_token(self):
        # Control: the scanner reads json.dumps(task), so a token in ANY field
        # must trip it. Without this, a scanner looking at the wrong object
        # reports every column clean.
        planted = {"id": "x", "title": "reconcile the MISALIGNED set", "files": ["a"]}
        blob = json.dumps(planted).lower()
        self.assertTrue(any(t in blob for t in LEAK_TOKENS))

    def test_column_and_shape_keys_live_outside_the_task_objects(self):
        # The neutralization argument in the README depends on this: `column`
        # and `shape` are top-level keys, never task fields, because only the
        # task object is serialized into a prompt.
        for label, col in columns():
            if label != "aligned":
                self.assertIn("shape", col, label)
            self.assertIn("column", col, label)
            for task in col["tasks"]:
                self.assertNotIn("column", task, f"{label}/{task['id']}")
                self.assertNotIn("shape", task, f"{label}/{task['id']}")

    def test_corpus_is_inert(self):
        for p in sorted(CORPUS.rglob("*")):
            if p.is_file():
                self.assertFalse(p.stat().st_mode & 0o111,
                                 f"{p.relative_to(ROOT)} carries an execute bit")

    def test_project_is_parseable_python(self):
        # The feasibility lens reads this tree to answer "does the path exist,
        # will the signature fit". A syntactically broken fixture project would
        # make it answer a different question.
        import ast
        for py in sorted((CORPUS / "project").rglob("*.py")):
            ast.parse(py.read_text(encoding="utf-8"), filename=str(py))


if __name__ == "__main__":
    unittest.main()
