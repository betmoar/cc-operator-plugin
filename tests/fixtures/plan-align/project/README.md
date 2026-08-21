# accounts

A small password-authenticated accounts service, mid-feature.

## Modules

- `app/models.py` — `User` (id, email, password_hash, locked_reason).
- `app/store.py` — persistence. One dict per index; a new table is a new dict.
- `app/auth.py` — `hash_password`, `verify_password`, `login`, `session_user`.
  `login` is the only place a session is created.
- `app/mailer.py` — `send_email` records into `sent` rather than sending, so
  assertions need no network.

## Running the tests

There is no `tests/` directory yet. Test paths that appear in planned work are
files that work would create.
