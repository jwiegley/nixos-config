"""MCP server exposing email (IMAP/SMTP) and contact (khard) tools.

Designed to run inside the OpenClaw microVM where:
  - Dovecot IMAPS is reachable at imap.vulcan.lan:993 via DNAT
  - Postfix plain SMTP is reachable at smtp.vulcan.lan:2525 via DNAT
  - khard is in PATH with pre-synced vCard contacts

Environment variables (all optional, sensible defaults for the VM):
  IMAP_HOST          default: imap.vulcan.lan
  IMAP_PORT          default: 993
  SMTP_HOST          default: smtp.vulcan.lan
  SMTP_PORT          default: 2525
  EMAIL_ADDRESS      default: johnw@vulcan.lan
  EMAIL_USERNAME     default: johnw
  EMAIL_PASSWORD_FILE  path to file containing the password
  KHARD_CMD          default: khard
"""

import imaplib
import smtplib
import email as email_mod
import subprocess
import os
import ssl
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import decode_header
from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

IMAP_HOST = os.getenv("IMAP_HOST", "imap.vulcan.lan")
IMAP_PORT = int(os.getenv("IMAP_PORT", "993"))
SMTP_HOST = os.getenv("SMTP_HOST", "smtp.vulcan.lan")
SMTP_PORT = int(os.getenv("SMTP_PORT", "2525"))
EMAIL_ADDRESS = os.getenv("EMAIL_ADDRESS", "johnw@vulcan.lan")
EMAIL_USERNAME = os.getenv("EMAIL_USERNAME", "johnw")
KHARD_CMD = os.getenv("KHARD_CMD", "khard")

_password_cache: str | None = None


def _get_password() -> str:
    global _password_cache
    if _password_cache is None:
        pf = os.getenv("EMAIL_PASSWORD_FILE", "")
        if pf:
            with open(pf) as f:
                _password_cache = f.read().strip()
        else:
            _password_cache = os.getenv("EMAIL_PASSWORD", "")
    return _password_cache


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _imap_connect() -> imaplib.IMAP4_SSL:
    ctx = ssl.create_default_context()
    mail = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT, ssl_context=ctx)
    mail.login(EMAIL_USERNAME, _get_password())
    return mail


def _smtp_connect() -> smtplib.SMTP:
    s = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15)
    s.ehlo()
    # Port 2525 is plain SMTP in mynetworks — no TLS needed.
    s.login(EMAIL_USERNAME, _get_password())
    return s


def _decode_header(header: str | None) -> str:
    if header is None:
        return ""
    parts = []
    for content, charset in decode_header(header):
        if isinstance(content, bytes):
            parts.append(content.decode(charset or "utf-8", errors="replace"))
        else:
            parts.append(content)
    return " ".join(parts)


def _body_text(msg: email_mod.message.Message) -> str:
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                payload = part.get_payload(decode=True)
                if payload:
                    return payload.decode(errors="replace")
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            return payload.decode(errors="replace")
    return ""


# ---------------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------------

mcp = FastMCP("email-contacts")


@mcp.tool()
def check_email(num_emails: int = 10, folder: str = "INBOX") -> str:
    """Retrieve recent emails.

    Args:
        num_emails: How many recent messages to return (default 10, max 50).
        folder: IMAP folder to read (default INBOX).
    """
    num_emails = min(num_emails, 50)
    try:
        mail = _imap_connect()
        mail.select(folder, readonly=True)
        _, data = mail.search(None, "ALL")
        ids = data[0].split()
        if not ids:
            mail.logout()
            return "No emails found."

        results = []
        for eid in reversed(ids[-num_emails:]):
            _, msg_data = mail.fetch(eid, "(RFC822)")
            msg = email_mod.message_from_bytes(msg_data[0][1])
            body = _body_text(msg)
            results.append(
                f"ID: {eid.decode()}\n"
                f"From: {_decode_header(msg['From'])}\n"
                f"Date: {msg['Date']}\n"
                f"Subject: {_decode_header(msg['Subject'])}\n"
                f"Body: {body[:800]}\n"
                f"{'=' * 60}"
            )
        mail.logout()
        return "\n".join(results)
    except Exception as e:
        return f"Error checking email: {e}"


@mcp.tool()
def search_email(
    subject: str | None = None,
    sender: str | None = None,
    since_date: str | None = None,
    before_date: str | None = None,
    body: str | None = None,
    folder: str = "INBOX",
    max_results: int = 20,
) -> str:
    """Search emails by criteria.

    Args:
        subject: Search in subjects.
        sender: Search by sender address or name.
        since_date: Emails since this date (DD-Mon-YYYY, e.g. 01-Mar-2026).
        before_date: Emails before this date (DD-Mon-YYYY).
        body: Search in message body.
        folder: IMAP folder (default INBOX).
        max_results: Maximum results to return (default 20, max 50).
    """
    max_results = min(max_results, 50)
    criteria: list[str] = []
    if subject:
        criteria.append(f'SUBJECT "{subject}"')
    if sender:
        criteria.append(f'FROM "{sender}"')
    if since_date:
        criteria.append(f"SINCE {since_date}")
    if before_date:
        criteria.append(f"BEFORE {before_date}")
    if body:
        criteria.append(f'BODY "{body}"')

    search_str = " ".join(criteria) if criteria else "ALL"
    try:
        mail = _imap_connect()
        mail.select(folder, readonly=True)
        _, data = mail.search(None, search_str)
        ids = data[0].split()
        if not ids:
            mail.logout()
            return "No emails found matching the criteria."

        results = []
        for eid in reversed(ids[-max_results:]):
            _, msg_data = mail.fetch(eid, "(RFC822)")
            msg = email_mod.message_from_bytes(msg_data[0][1])
            body_text = _body_text(msg)
            results.append(
                f"ID: {eid.decode()}\n"
                f"From: {_decode_header(msg['From'])}\n"
                f"Date: {msg['Date']}\n"
                f"Subject: {_decode_header(msg['Subject'])}\n"
                f"Body: {body_text[:800]}\n"
                f"{'=' * 60}"
            )
        mail.logout()
        return "\n".join(results)
    except Exception as e:
        return f"Error searching email: {e}"


@mcp.tool()
def read_email(message_id: str, folder: str = "INBOX") -> str:
    """Read a single email by its IMAP sequence ID.

    Args:
        message_id: The numeric ID of the message (from check_email / search_email output).
        folder: IMAP folder (default INBOX).
    """
    try:
        mail = _imap_connect()
        mail.select(folder, readonly=True)
        _, msg_data = mail.fetch(message_id.encode(), "(RFC822)")
        if not msg_data or not msg_data[0]:
            mail.logout()
            return f"Message {message_id} not found."
        msg = email_mod.message_from_bytes(msg_data[0][1])
        body = _body_text(msg)
        result = (
            f"From: {_decode_header(msg['From'])}\n"
            f"To: {_decode_header(msg['To'])}\n"
            f"Date: {msg['Date']}\n"
            f"Subject: {_decode_header(msg['Subject'])}\n"
            f"\n{body}"
        )
        mail.logout()
        return result
    except Exception as e:
        return f"Error reading email: {e}"


@mcp.tool()
def send_email(to: str, subject: str, body: str) -> str:
    """Compose and send an email.

    Args:
        to: Recipient email address.
        subject: Email subject line.
        body: Plain-text email body.
    """
    try:
        msg = MIMEMultipart()
        msg["From"] = EMAIL_ADDRESS
        msg["To"] = to
        msg["Subject"] = subject
        msg.attach(MIMEText(body, "plain"))

        s = _smtp_connect()
        s.send_message(msg)
        s.quit()
        return f"Email sent successfully to {to}"
    except Exception as e:
        return f"Error sending email: {e}"


@mcp.tool()
def search_contacts(query: str) -> str:
    """Search contacts by name or email address.

    Args:
        query: Name or email to search for.
    """
    try:
        result = subprocess.run(
            [KHARD_CMD, "list", "--search-in-source-files", "-p", query],
            capture_output=True, text=True, timeout=10,
        )
        output = result.stdout.strip()
        if not output:
            return f"No contacts found matching '{query}'."
        return output
    except Exception as e:
        return f"Error searching contacts: {e}"


@mcp.tool()
def get_contact_details(name: str) -> str:
    """Get full details for a contact by name.

    Args:
        name: Contact name to look up (partial match).
    """
    try:
        result = subprocess.run(
            [KHARD_CMD, "show", "--search-in-source-files", name],
            capture_output=True, text=True, timeout=10,
        )
        output = result.stdout.strip()
        if not output:
            return f"No contact found matching '{name}'."
        return output
    except Exception as e:
        return f"Error getting contact details: {e}"


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
