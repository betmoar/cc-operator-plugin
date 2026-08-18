"""In-memory persistence: one dict per index, no migrations. A new table is a
new dict."""
from .models import User

_USERS: dict[int, User] = {}
_BY_EMAIL: dict[str, int] = {}


def save_user(user: User) -> None:
    _USERS[user.id] = user
    _BY_EMAIL[user.email] = user.id


def get_user(user_id: int) -> User | None:
    return _USERS.get(user_id)


def get_user_by_email(email: str) -> User | None:
    uid = _BY_EMAIL.get(email)
    return None if uid is None else _USERS.get(uid)
