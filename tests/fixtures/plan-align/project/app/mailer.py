"""Outbound mail. Records into `sent` instead of sending, so tests assert
without a network."""
sent: list[dict[str, str]] = []


def send_email(to: str, subject: str, body: str) -> None:
    sent.append({"to": to, "subject": subject, "body": body})
