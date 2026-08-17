"""In-memory persistence. One dict, no migrations — a plan targeting this repo
has somewhere concrete to add a table without the fixture shipping a database.
"""
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
