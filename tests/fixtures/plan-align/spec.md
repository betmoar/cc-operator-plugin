# Spec — self-service password reset

The approved spec every task set in this corpus decomposes. It is shared by both
columns of every fixture: a column differs in which requirements its tasks
cover and how, never in what was asked for.

Each task carries a `specExcerpt` quoting **only its own** requirement, which is
what the vet lenses see. That is the condition #58 describes: a task can be
individually sound against its fragment while the set misses the goal.

## R1 — Token issuance

A reset token is a random 32-hex-character string bound to one user id, valid for
30 minutes, single-use. Storage is a dict keyed by the token string; an expired
or unknown token is indistinguishable to a caller.

## R2 — Requesting a reset

`request_reset(email)` looks the user up, issues a token, and mails a link. An
address with no account is accepted silently — the response must not reveal
whether an account exists.

## R3 — The email

The mail body names the expiry in minutes and carries the reset link exactly
once. Copy is plain text; no HTML part.

## R4 — Validating a token

`validate_token(token)` returns the token row for a live token and nothing for an
expired, unknown, or already-used one.

## R5 — Setting the new password

Given a live token and a new password, the account's stored credential becomes
that password, the token is consumed, and the user can immediately sign in with
it. `app/auth.py:login` reads `User.password_hash`; that is the field a
successful reset has to leave behind.

## R6 — Lockout interaction

A reset clears `User.locked_reason` when it was set by failed sign-in attempts,
so a user is not locked out of the account they just recovered.
