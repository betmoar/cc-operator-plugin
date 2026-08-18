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
import pathlib
import re
import tempfile
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
# The vocabulary the tree scan uses. Module-level so the control below can pass
# the SAME tuple the live assertion uses — a control with its own copy proves
# nothing about the one that runs.
LEAK_VOCAB = ("fixture", "corpus", "column", "aligned", "misaligned",
              "north star", "plan-align", "lens")
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

    @staticmethod
    def _task_leaks(task):
        """Tokens leaked by ONE task object, via the exact serialization a
        dispatch performs. Extracted so the control below runs this, not a
        paraphrase of it."""
        blob = json.dumps(task).lower()
        return [t for t in LEAK_TOKENS if t in blob]

    def test_no_task_object_leaks_its_column(self):
        for label, col in columns():
            for task in col["tasks"]:
                leaks = self._task_leaks(task)
                self.assertEqual(leaks, [],
                                 f"{label}/{task['id']}: leaks {leaks} to a seat — the "
                                 f"task object is what gets serialized into the prompt")

    def test_task_leak_scan_fires_on_a_planted_task(self):
        # Control that RUNS the scan. The version this replaces asserted a
        # hardcoded tuple against a literal it defined two lines earlier, so
        # emptying LEAK_TOKENS or mis-serializing the task left it green.
        self.assertEqual(self._task_leaks({"id": "x", "title": "a clean task"}), [],
                         "a clean task must produce no leaks")
        planted = {"id": "x", "title": "reconcile the MISALIGNED set", "files": ["a"]}
        self.assertTrue(self._task_leaks(planted),
                        "the scan must fire on a task naming its column")

    def test_task_leak_scan_reaches_nested_fields(self):
        # It serializes the whole object, so a leak in a nested list — where a
        # field-by-field scan would miss it — must still trip.
        self.assertTrue(self._task_leaks({"id": "x", "files": ["docs/misaligned.md"]}))

    def test_leak_scanner_would_notice_a_planted_token(self):
        # Control: the scanner reads json.dumps(task), so a token in ANY field
        # must trip it. Without this, a scanner looking at the wrong object
        # reports every column clean.
        planted = {"id": "x", "title": "reconcile the MISALIGNED set", "files": ["a"]}
        blob = json.dumps(planted).lower()
        self.assertTrue(any(t in blob for t in LEAK_TOKENS))

    def test_tree_scan_control_actually_runs_the_scan(self):
        # The real control for _scan_for_leaks: plant a file in a temp tree and
        # require the SCAN — not a literal — to find it, using the SAME vocab the
        # live assertion uses. Both halves matter: it must fire on a plant, and
        # it must stay silent on a clean tree, or "no hits" is indistinguishable
        # from "walked nothing".
        with tempfile.TemporaryDirectory() as td:
            tree = pathlib.Path(td)
            (tree / "clean.py").write_text("def login():\n    return None\n")
            self.assertEqual(self._scan_for_leaks(tree), [],
                             "clean tree must produce no hits")
            (tree / "leak.md").write_text("this is the misaligned column's fixture")
            hits = self._scan_for_leaks(tree)
            self.assertTrue(hits, "the scan must fire on a planted leak")
            self.assertTrue(any(w in ("misaligned", "column", "fixture") for _, w in hits), hits)

    def test_tree_scan_walks_more_than_python_files(self):
        # The original scan walked *.py and therefore could not see the file the
        # leak was actually in. Pin the walk, not just its result.
        with tempfile.TemporaryDirectory() as td:
            tree = pathlib.Path(td)
            (tree / "notes.md").write_text("part of the corpus")
            self.assertTrue(self._scan_for_leaks(tree),
                            "a non-.py file must be reachable by the scan")

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

    @staticmethod
    def _scan_for_leaks(root, vocab=None):
        """Return [(relpath, word)] for every corpus word found under `root`.

        Extracted so the control below can RUN it. The previous control asserted
        a hardcoded tuple against a string literal it defined two lines earlier —
        it never invoked the scan and never referenced `vocab`, so emptying the
        vocabulary or pointing the walk at nothing left it green. A control that
        cannot fail is the defect this whole release has been about, and this one
        was written while fixing three others.
        """
        vocab = LEAK_VOCAB if vocab is None else vocab
        hits = []
        for f in sorted(p for p in pathlib.Path(root).rglob("*") if p.is_file()):
            text = f.read_text(encoding="utf-8").lower()
            hits += [(str(f), w) for w in vocab if w in text]
        return hits

    def test_seat_visible_tree_names_neither_the_corpus_nor_the_answer(self):
        """Nothing under project/ names the corpus or the answer.

        The 2026-08-18 run nearly shipped the answer to the seats. Three
        docstrings said "fixture", and project/README.md stated the
        discriminating property outright — "A plan that never writes that field
        cannot produce a user who signs in", which is `missing-final-step`'s
        defect, written down, in the tree the lens reads. Neutralization in this
        corpus is the claim that nothing a seat can see identifies the column;
        the pins checked the task JSON and never the codebase beside it.

        No file is exempt. An earlier version scanned only `*.py` and excused
        project/README.md on the promise that a dispatch excludes it; nothing
        pinned the promise, so the guard rested on it.
        """
        hits = self._scan_for_leaks(CORPUS / "project")
        self.assertEqual(hits, [], f"a seat reads these files and must not learn "
                                   f"what they are part of: {hits}")

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
