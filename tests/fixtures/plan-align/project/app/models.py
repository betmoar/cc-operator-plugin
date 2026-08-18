"""Domain types for the accounts service."""
from dataclasses import dataclass


@dataclass
class User:
    id: int
    email: str
    password_hash: str
    # Set when the account is locked out; None otherwise.
    locked_reason: str | None = None
