"""Outbound mail. Records instead of sending, so a plan's test cycle can assert
on `sent` without a network."""
sent: list[dict[str, str]] = []


def send_email(to: str, subject: str, body: str) -> None:
    sent.append({"to": to, "subject": subject, "body": body})
