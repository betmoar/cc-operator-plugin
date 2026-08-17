"""Domain types. Deliberately small: a fixture project exists so a feasibility
lens can answer "does this path exist / will this signature fit", nothing more.
"""
from dataclasses import dataclass


@dataclass
class User:
    id: int
    email: str
    password_hash: str
    # Set when the account is locked out; None otherwise.
    locked_reason: str | None = None
