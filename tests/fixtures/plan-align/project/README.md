# Fixture project — a password-authenticated app, mid-feature

Four modules and no reset flow. This is the codebase every task set in
`tests/fixtures/plan-align/` targets, and it is **identical for both columns of
every fixture** — the only thing that varies between columns is the task set,
which reaches a seat as inline JSON.

What matters for judging feasibility:

- `app/auth.py:login` reads `User.password_hash` and nothing else. A plan that
  never writes that field cannot produce a user who signs in, however many of
  its own tests pass.
- `app/store.py` is a dict. Adding a table means adding a dict, so "is this
  task implementable" is never blocked on infrastructure here.
- `app/mailer.py` records into `sent`, so an email assertion needs no network.
- There is no `tests/` directory. Test paths named in a task's `testCycle` are
  files that task would create; a feasibility lens should read them as such and
  not as missing dependencies.

Nothing here is executable, imported by the plugin, or run by any suite.
