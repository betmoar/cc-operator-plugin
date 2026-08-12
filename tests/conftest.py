"""pytest bootstrap: no bytecode from a test run.

`PYTHONDONTWRITEBYTECODE` has to be set before the interpreter starts, so
neither `pyproject.toml` nor a fixture can apply it — by the time any config is
read, python is already running. conftest.py is imported before the test
modules are, and `sys.dont_write_bytecode` is consulted per import, so setting
it here suppresses the writes that would otherwise happen when the test modules
and the `scripts/` modules they import get compiled.

Why bother: a pytest run leaves `__pycache__` in `tests/` and `scripts/`, both
gitignored, so `git status` reports a clean tree that is not one. Stale
bytecode is the canonical example of build state a tracked-tree check cannot
see — the class the `#23` case in `tests/test-scripts.sh` demonstrates, where a
`__pycache__` the builder left makes a broken commit verify green in-tree and
fail in a clean checkout of the same commit.

Scope, stated so nobody reads more into it — measured, 2 __pycache__ dirs
before:

- `pytest` (either shape): 1 file left, and it is THIS module's own .pyc.
  conftest is compiled before the line below runs; nothing inside the process
  can prevent its own bytecode. Only the environment variable, set before the
  interpreter starts, gets to 0.
- `python3 -m unittest discover -s tests`: unchanged at 2. That shape reads no
  config file at all. CI sets the env var at job level, which covers the build;
  a hand-run needs the prefix.
- `bash tests/test-scripts.sh`: 0 — it exports the variable for its ~43
  python3 calls.
- `python3 scripts/validate_plugin.py`: 0 already. It is run as a script, not
  imported, so nothing was ever cached for it.

So the honest summary is "the suites no longer contaminate the tree, except
this file's own .pyc under a bare pytest". Prefixing `PYTHONDONTWRITEBYTECODE=1`
closes that last one.
"""

import sys

sys.dont_write_bytecode = True
