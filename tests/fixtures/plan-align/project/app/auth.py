"""Password hashing, verification, and sign-in.

`login` is the only way a session comes into existence, and it reads
`User.password_hash` and nothing else. Any plan claiming a user can "sign in
with the new password" has to end up writing that field.
"""
import hashlib
import secrets

from . import store

_SESSIONS: dict[str, int] = {}


def hash_password(plaintext: str) -> str:
    return hashlib.sha256(plaintext.encode("utf-8")).hexdigest()


def verify_password(plaintext: str, password_hash: str) -> bool:
    return secrets.compare_digest(hash_password(plaintext), password_hash)


def login(email: str, password: str) -> str | None:
    """Return a session token, or None when the credentials do not match."""
    user = store.get_user_by_email(email)
    if user is None or user.locked_reason is not None:
        return None
    if not verify_password(password, user.password_hash):
        return None
    token = secrets.token_hex(16)
    _SESSIONS[token] = user.id
    return token


def session_user(token: str) -> int | None:
    return _SESSIONS.get(token)
