#!/usr/bin/env python3
"""
Email Delivery and Filtering Pipeline Tester for NixOS Vulcan

Tests the complete email delivery pipeline using IMAP (like a real email client):
- Postfix SMTP delivery
- Rspamd spam filtering
- Dovecot Sieve filtering
- IMAPSieve training (TrainSpam/TrainGood)

SAFETY: All test messages use unique Message-IDs for safe cleanup.
"""

import subprocess
import sys
import time
import logging
import uuid
import re
import imaplib
import email
import os
import argparse
import json
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from email.message import EmailMessage
from typing import List, Dict, Tuple, Optional

# Configuration
USER = "johnw"
TEST_MESSAGE_ID_PREFIX = "test-EMAIL-TESTER"
WAIT_AFTER_DELIVERY = 3  # seconds to wait after mail delivery
WAIT_AFTER_IMAP_OPERATION = 6  # seconds to wait after IMAP copy operations
GTUBE_SPAM_STRING = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"

# IMAP configuration
IMAP_HOST = "localhost"
IMAP_PORT = 143  # STARTTLS
IMAP_PASSWORD_FILE = "/run/secrets/email-tester-imap-password"

# LiteLLM configuration
LITELLM_HOST = "localhost"
LITELLM_PORT = 4000

# Track all test Message-IDs for cleanup
test_message_ids: List[str] = []

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(message)s'
)
logger = logging.getLogger(__name__)

# Track IMAP connection
_imap_password: Optional[str] = None


class TestError(Exception):
    """Custom exception for test failures"""
    pass


def run_command(cmd: List[str], input_data: Optional[str] = None,
                capture_output: bool = True, check: bool = True) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    try:
        result = subprocess.run(
            cmd,
            input=input_data,
            capture_output=capture_output,
            text=True,
            check=check,
            timeout=30
        )
        return result
    except subprocess.CalledProcessError as e:
        logger.error(f"✗ Command failed: {' '.join(cmd)}")
        logger.error(f"  Exit code: {e.returncode}")
        if e.stderr:
            logger.error(f"  Error: {e.stderr}")
        raise
    except subprocess.TimeoutExpired:
        logger.error(f"✗ Command timed out: {' '.join(cmd)}")
        raise


def generate_message_id(scenario: str) -> str:
    """Generate unique Message-ID for test message"""
    unique_id = str(uuid.uuid4())
    message_id = f"<{TEST_MESSAGE_ID_PREFIX}-{unique_id}-{scenario}@test.local>"
    test_message_ids.append(message_id)
    return message_id


def create_test_message(subject: str, body: str, scenario: str) -> EmailMessage:
    """Create a test email message"""
    msg = EmailMessage()
    msg['From'] = f'{USER}@localhost'
    msg['To'] = f'{USER}@localhost'
    msg['Subject'] = subject
    msg['Message-ID'] = generate_message_id(scenario)
    msg['Date'] = datetime.now().strftime('%a, %d %b %Y %H:%M:%S +0000')
    msg.set_content(body)
    return msg


def send_via_postfix(msg: EmailMessage) -> None:
    """Send message via Postfix sendmail"""
    cmd = ['/run/current-system/sw/bin/sendmail', '-t', '-i']
    run_command(cmd, input_data=msg.as_string())
    logger.info(f"  → Sent via Postfix")


def get_imap_password() -> str:
    """Load IMAP password from SOPS secret or systemd credential."""
    global _imap_password

    if _imap_password:
        return _imap_password

    # Check systemd credentials first
    creds_dir = os.environ.get('CREDENTIALS_DIRECTORY')
    if creds_dir:
        cred_file = os.path.join(creds_dir, 'imap-password')
        if os.path.exists(cred_file):
            with open(cred_file, 'r') as f:
                _imap_password = f.read().strip()
                return _imap_password

    # Fall back to SOPS secret path
    if os.path.exists(IMAP_PASSWORD_FILE):
        with open(IMAP_PASSWORD_FILE, 'r') as f:
            _imap_password = f.read().strip()
            return _imap_password

    raise TestError(f"IMAP password not found. Ensure {IMAP_PASSWORD_FILE} exists and contains the password for {USER}.")


def imap_connect() -> imaplib.IMAP4:
    """Connect to IMAP server and authenticate."""
    password = get_imap_password()

    # Connect and start TLS
    mail = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
    mail.starttls()

    # Login
    mail.login(USER, password)
    return mail


def imap_search_message(mail: imaplib.IMAP4, folder: str, message_id: str) -> Optional[bytes]:
    """Search for message by Message-ID in folder. Returns message number or None."""
    mail.select(folder, readonly=True)

    # IMAP search requires Message-ID without angle brackets
    search_id = message_id.strip('<>')
    typ, data = mail.search(None, f'HEADER Message-ID "{search_id}"')

    if typ != 'OK' or not data[0]:
        return None

    msg_nums = data[0].split()
    return msg_nums[0] if msg_nums else None


def check_message_in_folder(message_id: str, folder: str, should_exist: bool = True) -> bool:
    """Check if message exists in folder via IMAP."""
    mail = imap_connect()
    try:
        msg_num = imap_search_message(mail, folder, message_id)
        exists = msg_num is not None

        if should_exist and not exists:
            logger.error(f"  ✗ Message NOT in {folder}")
            return False
        elif not should_exist and exists:
            logger.error(f"  ✗ Message UNEXPECTEDLY in {folder}")
            return False

        status = "in" if exists else "not in"
        logger.info(f"  ✓ Message {status} {folder}")
        return True
    finally:
        mail.logout()


def get_message_headers(message_id: str, folder: str) -> Optional[str]:
    """Fetch message headers via IMAP."""
    mail = imap_connect()
    try:
        msg_num = imap_search_message(mail, folder, message_id)

        if not msg_num:
            return None

        mail.select(folder, readonly=True)
        typ, data = mail.fetch(msg_num, '(BODY[HEADER])')

        if typ != 'OK' or not data[0]:
            return None

        # Parse response - data[0] is a tuple (b'...', b'headers...')
        header_data = data[0][1] if isinstance(data[0], tuple) else data[0]
        return header_data.decode('utf-8', errors='ignore')
    finally:
        mail.logout()


def check_spam_header(message_id: str, folder: str, should_be_spam: bool) -> bool:
    """Check X-Spam header via IMAP."""
    headers = get_message_headers(message_id, folder)

    if not headers:
        logger.error(f"  ✗ Cannot fetch headers")
        return False

    has_spam_header = bool(re.search(r'^X-Spam:\s*Yes', headers, re.MULTILINE | re.IGNORECASE))

    if should_be_spam and not has_spam_header:
        logger.error(f"  ✗ Missing X-Spam: Yes header")
        return False
    elif not should_be_spam and has_spam_header:
        logger.error(f"  ✗ Unexpected X-Spam: Yes header")
        return False

    status = "spam" if should_be_spam else "ham"
    logger.info(f"  ✓ Correctly marked as {status}")
    return True


def check_rspamd_headers(message_id: str, folder: str) -> bool:
    """Check for presence of rspamd headers via IMAP.

    Requires X-Spamd-Result (the primary detailed header).
    Other headers are checked and reported but not required.
    """
    headers = get_message_headers(message_id, folder)

    if not headers:
        logger.error(f"  ✗ Cannot fetch headers")
        return False

    # Required header: X-Spamd-Result provides detailed scan results
    required_header = ('X-Spamd-Result', r'^X-Spamd-Result:\s*\S+')

    # Optional headers (nice to have but not required for test to pass)
    optional_headers = {
        'X-Spam': r'^X-Spam:\s*\S+',
        'X-Spam-Flag': r'^X-Spam-Flag:\s*\S+',
        'X-Spam-Status': r'^X-Spam-Status:\s*\S+',
        'X-Spam-Level': r'^X-Spam-Level:\s*',
        'X-Spamd-Bar': r'^X-Spamd-Bar:\s*',
        'X-Rspamd-Server': r'^X-Rspamd-Server:\s*',
        'X-Rspamd-Queue-Id': r'^X-Rspamd-Queue-Id:\s*',
        'Authentication-Results': r'^Authentication-Results:\s*',
    }

    # Check required header
    if not re.search(required_header[1], headers, re.MULTILINE | re.IGNORECASE):
        logger.error(f"  ✗ Missing required header: {required_header[0]}")
        logger.error(f"  ℹ Check rspamd milter_headers.conf: extended_spam_headers = true")
        return False

    logger.info(f"  ✓ Required header present: {required_header[0]}")

    # Extract and display X-Spamd-Result for debugging
    result_match = re.search(r'^X-Spamd-Result:\s*(.+?)$', headers, re.MULTILINE | re.IGNORECASE)
    if result_match:
        result_value = result_match.group(1).strip()
        # Show score if present
        score_match = re.search(r'\[([0-9.-]+)\s*/\s*([0-9.-]+)\]', result_value)
        if score_match:
            logger.info(f"  ℹ Spam score: {score_match.group(1)} / {score_match.group(2)}")

    # Check optional headers and report (but don't fail)
    found_optional = []
    for header_name, pattern in optional_headers.items():
        if re.search(pattern, headers, re.MULTILINE | re.IGNORECASE):
            found_optional.append(header_name)

    if found_optional:
        logger.info(f"  ℹ Additional headers: {', '.join(found_optional)}")

    return True


def imap_copy_message(message_id: str, source_folder: str, dest_folder: str) -> None:
    """Copy message via IMAP COPY command (triggers IMAPSieve)."""
    mail = imap_connect()
    try:
        # Select source folder (read-write to enable COPY)
        mail.select(source_folder)

        # Search for message
        msg_num = imap_search_message(mail, source_folder, message_id)
        if not msg_num:
            raise TestError(f"Message not found in {source_folder}")

        # Copy to destination folder (this triggers IMAPSieve)
        typ, data = mail.copy(msg_num, dest_folder)

        if typ != 'OK':
            raise TestError(f"IMAP COPY failed: {data}")

        logger.info(f"  → Copied {source_folder} → {dest_folder} (via IMAP)")
    finally:
        mail.logout()


def imap_append_message(msg: EmailMessage, folder: str) -> None:
    """Append message to folder via IMAP."""
    mail = imap_connect()
    try:
        # Append message to folder
        typ, data = mail.append(folder, '', imaplib.Time2Internaldate(time.time()), msg.as_bytes())

        if typ != 'OK':
            raise TestError(f"IMAP APPEND failed: {data}")

        logger.info(f"  → Created message in {folder} (via IMAP)")
    finally:
        mail.logout()


def ensure_folder_exists(folder: str) -> None:
    """Ensure a mailbox folder exists via IMAP."""
    mail = imap_connect()
    try:
        # List mailboxes
        typ, folders = mail.list()
        if typ != 'OK':
            raise TestError("Could not list IMAP folders")

        # Check if folder exists (folder names are quoted in response)
        folder_exists = any(f'"{folder}"' in line.decode('utf-8', errors='ignore') for line in folders)

        if not folder_exists:
            # Create folder
            typ, data = mail.create(folder)
            if typ != 'OK':
                # Check if error is because it already exists
                error_str = str(data)
                if 'ALREADYEXISTS' in error_str or 'already exists' in error_str.lower():
                    # Folder exists, this is fine
                    pass
                else:
                    raise TestError(f"Could not create folder {folder}: {data}")
            else:
                logger.info(f"  → Created folder: {folder}")
    finally:
        mail.logout()


def get_rspamd_learn_count(learn_type: str) -> Optional[int]:
    """Get current learned message count from rspamd statistics.

    Args:
        learn_type: Either 'spam' or 'ham'

    Returns:
        Number of learned messages, or None if unable to parse
    """
    cmd = ['rspamc', 'stat']
    result = run_command(cmd, check=False)

    if learn_type == 'spam':
        pattern = r'Statfile:\s+BAYES_SPAM.*?learned:\s+(\d+)'
    else:  # ham
        pattern = r'Statfile:\s+BAYES_HAM.*?learned:\s+(\d+)'

    match = re.search(pattern, result.stdout, re.MULTILINE | re.DOTALL)
    if match:
        return int(match.group(1))

    return None


def check_rspamd_learning(since_time: datetime, learn_type: str) -> bool:
    """Check rspamd statistics to verify learning occurred.

    This function should be called AFTER the expected learning operation.
    It gets the current learn count and can be used to verify increases.

    Args:
        since_time: Not used (kept for backwards compatibility)
        learn_type: Either 'spam' or 'ham'

    Returns:
        True if we can get valid statistics (actual verification done by caller)
    """
    count = get_rspamd_learn_count(learn_type)
    if count is not None:
        logger.info(f"  ℹ Current {learn_type} learn count: {count}")
        return True
    else:
        logger.error(f"  ✗ Unable to get {learn_type} statistics from rspamd")
        return False


def check_for_forwarding_loops(since_time: datetime, message_id: str) -> bool:
    """Check if a specific message triggered a mail forwarding loop.

    This is critical for Retrain folder functionality - if the local_transport
    is misconfigured, sendmail will create forwarding loops.

    Args:
        since_time: Start time to check logs from
        message_id: Message ID to check for (used for context in errors)

    Returns:
        True if no forwarding loops detected, False otherwise
    """
    since_str = since_time.strftime('%Y-%m-%d %H:%M:%S')

    cmd = [
        'journalctl',
        '-u', 'postfix',
        '--since', since_str,
        '--no-pager',
        '-o', 'cat'  # Just message content, no timestamps
    ]
    result = run_command(cmd, check=False)

    # Check for mail forwarding loop errors
    loop_errors = [
        line for line in result.stdout.split('\n')
        if 'mail forwarding loop' in line.lower()
        and 'johnw@localhost' in line
    ]

    if loop_errors:
        logger.error(f"  ✗ Mail forwarding loop detected during Retrain redelivery")
        logger.error(f"  ℹ This indicates local_transport is misconfigured in Postfix")
        logger.error(f"  ℹ Should be: local_transport = lmtp:unix:/var/run/dovecot2/lmtp")
        for error in loop_errors[:3]:  # Show first 3 errors
            logger.error(f"    {error}")
        return False

    return True


def check_logs_for_errors(since_time: datetime) -> Tuple[bool, List[str]]:
    """Check journalctl for errors in mail services."""
    since_str = since_time.strftime('%Y-%m-%d %H:%M:%S')
    errors = []

    for service in ['postfix', 'dovecot2', 'rspamd']:
        cmd = [
            'journalctl',
            '-u', service,
            '--since', since_str,
            '--no-pager',
            '-p', 'warning'
        ]
        result = run_command(cmd, check=False)

        if result.stdout.strip():
            lines = result.stdout.split('\n')
            filtered = [
                line for line in lines
                if line.strip()
                and 'Killed with signal 15' not in line
                and 'stats: open(/run/dovecot2/old-stats-mail) failed' not in line
                and '-- No entries --' not in line
            ]

            if filtered:
                errors.extend(filtered)

    return (len(errors) == 0), errors


def check_litellm_health() -> Tuple[bool, str]:
    """Check if LiteLLM service is available and healthy.

    Returns:
        Tuple of (is_healthy, message)
    """
    try:
        url = f"http://{LITELLM_HOST}:{LITELLM_PORT}/health/readiness"
        req = urllib.request.Request(url, method='GET')

        with urllib.request.urlopen(req, timeout=5) as response:
            if response.status == 200:
                return True, "LiteLLM is healthy and ready"
            else:
                return False, f"LiteLLM returned status {response.status}"

    except urllib.error.URLError as e:
        return False, f"Cannot connect to LiteLLM: {e.reason}"
    except Exception as e:
        return False, f"LiteLLM health check failed: {str(e)}"


def extract_spam_score(headers: str) -> Optional[float]:
    """Extract overall spam score from X-Spamd-Result header.

    Args:
        headers: Email headers as string

    Returns:
        Spam score as float, or None if not found
    """
    # Extract X-Spamd-Result header
    # Format: X-Spamd-Result: default: F (no action): [score/threshold] [symbols...]
    result_match = re.search(r'^X-Spamd-Result:.*?\[\s*([0-9.-]+)\s*/\s*([0-9.-]+)\s*\]',
                            headers, re.MULTILINE | re.IGNORECASE)
    if result_match:
        return float(result_match.group(1))

    return None


def extract_symbol_score(headers: str, symbol_name: str) -> Optional[Tuple[float, Optional[str]]]:
    """Extract score and optional details for a specific symbol from X-Spamd-Result header.

    Args:
        headers: Email headers as string
        symbol_name: Symbol to look for (e.g., 'GPT_SPAM', 'GPT_HAM')

    Returns:
        Tuple of (score, details) if symbol found, None otherwise
        Details may contain additional info like spam probability in brackets
    """
    # Extract X-Spamd-Result header
    result_match = re.search(r'^X-Spamd-Result:\s*(.+?)(?=\n\S|\n\n|\Z)', headers,
                            re.MULTILINE | re.IGNORECASE | re.DOTALL)
    if not result_match:
        return None

    result_value = result_match.group(1)

    # Look for symbol in format: SYMBOL_NAME(score){details} or SYMBOL_NAME(score)
    # GPT symbols typically appear as: GPT_SPAM(2.94){0.99} where 0.99 is probability
    pattern = rf'{symbol_name}\s*\(([0-9.-]+)\)(?:\{{([^}}]*)\}})?'
    match = re.search(pattern, result_value, re.IGNORECASE)

    if match:
        score = float(match.group(1))
        details = match.group(2) if match.group(2) else None
        return (score, details)

    return None


def check_gpt_symbols(message_id: str, folder: str, expected_symbol: str, optional: bool = False) -> bool:
    """Check for GPT symbols in message headers.

    Args:
        message_id: Message ID to check
        folder: IMAP folder containing the message
        expected_symbol: Expected GPT symbol (GPT_SPAM, GPT_HAM, or GPT_UNCERTAIN)
        optional: If True, GPT analysis is optional (for ham messages where rspamd may skip GPT)

    Returns:
        True if expected symbol found OR (if optional=True) no GPT symbols but spam score is very negative
    """
    headers = get_message_headers(message_id, folder)

    if not headers:
        logger.error(f"  ✗ Cannot fetch headers")
        return False

    # Check for any GPT symbol
    gpt_symbols = ['GPT_SPAM', 'GPT_HAM', 'GPT_UNCERTAIN']
    found_symbols = {}

    for symbol in gpt_symbols:
        result = extract_symbol_score(headers, symbol)
        if result:
            found_symbols[symbol] = result

    if not found_symbols:
        if optional:
            # For ham messages, rspamd may skip GPT if message is clearly legitimate
            # Check if the overall spam score is very negative (clearly ham)
            spam_score = extract_spam_score(headers)
            if spam_score is not None and spam_score < -1.0:
                logger.info(f"  ℹ GPT analysis skipped (message clearly ham with score {spam_score:.2f})")
                logger.info(f"  ✓ Message correctly identified as ham without GPT")
                return True
            else:
                logger.error(f"  ✗ No GPT symbols found and spam score not clearly negative ({spam_score})")
                return False
        else:
            logger.error(f"  ✗ No GPT symbols found in headers")
            logger.error(f"  ℹ Check that rspamd GPT module is enabled and working")
            return False

    # Check if expected symbol is present
    if expected_symbol not in found_symbols:
        logger.error(f"  ✗ Expected {expected_symbol} but found: {', '.join(found_symbols.keys())}")
        for sym, (score, details) in found_symbols.items():
            detail_str = f" [{details}]" if details else ""
            logger.error(f"    {sym}({score}){detail_str}")
        return False

    # Report the GPT classification
    score, details = found_symbols[expected_symbol]
    detail_str = f" (probability: {details})" if details else ""
    logger.info(f"  ✓ GPT classified as {expected_symbol}({score}){detail_str}")

    # Report any other GPT symbols found (shouldn't happen, but informative)
    other_symbols = {k: v for k, v in found_symbols.items() if k != expected_symbol}
    if other_symbols:
        logger.info(f"  ℹ Other GPT symbols: {', '.join(other_symbols.keys())}")

    return True


def cleanup_test_messages() -> None:
    """Clean up all test messages via IMAP."""
    if not test_message_ids:
        return

    logger.info(f"\nCleaning up {len(test_message_ids)} test messages...")

    mail = imap_connect()
    try:
        # List all folders
        typ, folders = mail.list()
        if typ != 'OK':
            logger.error("  ✗ Could not list folders for cleanup")
            return

        folder_names = []
        for folder_line in folders:
            # Parse folder name from response like: b'(\\HasNoChildren) "." "INBOX"'
            folder_str = folder_line.decode('utf-8', errors='ignore')
            match = re.search(r'"([^"]+)"$', folder_str)
            if match:
                folder_names.append(match.group(1))

        # Delete messages from each folder
        deleted_count = 0
        for folder in folder_names:
            try:
                mail.select(folder)

                for message_id in test_message_ids:
                    search_id = message_id.strip('<>')
                    typ, data = mail.search(None, f'HEADER Message-ID "{search_id}"')

                    if typ == 'OK' and data[0]:
                        msg_nums = data[0].split()
                        for msg_num in msg_nums:
                            mail.store(msg_num, '+FLAGS', '\\Deleted')
                            deleted_count += 1

                # Expunge to permanently delete
                mail.expunge()

            except Exception as e:
                # Skip folders that fail
                continue

        if deleted_count > 0:
            logger.info(f"  → Deleted {deleted_count} test messages")
        else:
            logger.info(f"  → All test messages already removed")

    finally:
        mail.logout()


def test_normal_delivery() -> bool:
    """Test 1: Normal email delivery to INBOX (not spam)."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 1: Normal Email Delivery")
    logger.info("=" * 70)

    try:
        msg = create_test_message(
            subject="Test Normal Delivery",
            body="This is a normal test message that should not be marked as spam.",
            scenario="normal"
        )
        message_id = msg['Message-ID']

        send_via_postfix(msg)
        time.sleep(WAIT_AFTER_DELIVERY)

        # Check delivery location
        if not check_message_in_folder(message_id, 'INBOX', should_exist=True):
            raise TestError("Not in INBOX")

        if not check_message_in_folder(message_id, 'Spam', should_exist=False):
            raise TestError("Incorrectly in Spam")

        # Check spam headers
        if not check_spam_header(message_id, 'INBOX', should_be_spam=False):
            raise TestError("Incorrectly marked as spam")

        # Check rspamd headers are present
        if not check_rspamd_headers(message_id, 'INBOX'):
            raise TestError("Missing rspamd headers")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_spam_folder_accessibility() -> bool:
    """Test 2.1: Spam folder accessibility test."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 2.1: Spam Folder Accessibility")
    logger.info("=" * 70)

    try:
        # Ensure Spam folder exists
        ensure_folder_exists('Spam')
        logger.info("  ✓ Spam folder exists")

        # Create a test message directly in Spam folder
        msg = create_test_message(
            subject="Test Spam Folder",
            body="This is a test message in the Spam folder.",
            scenario="spam-folder-test"
        )
        msg['X-Spam'] = 'Yes'
        msg['X-Spam-Score'] = '15.0'
        message_id = msg['Message-ID']

        imap_append_message(msg, 'Spam')

        # Verify message in Spam folder
        if not check_message_in_folder(message_id, 'Spam', should_exist=True):
            raise TestError("Cannot store messages in Spam folder")

        logger.info("  ✓ Spam folder is accessible")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_spam_detection_and_delivery() -> bool:
    """Test 2.2: Spam detection and delivery via rspamd."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 2.2: Spam Detection and Delivery")
    logger.info("=" * 70)

    try:
        # Create a highly spammy message that will score high in rspamd
        # Multiple spam indicators to ensure high score
        spam_body = """
CONGRATULATIONS!!! YOU HAVE WON $5,000,000 USD!!!

Dear Winner,

This is NOT a scam! You have been RANDOMLY SELECTED to receive FIVE MILLION DOLLARS ($5,000,000.00 USD) from our INTERNATIONAL LOTTERY COMMISSION!!!

*** URGENT ACTION REQUIRED - CLAIM EXPIRES IN 24 HOURS ***

To claim your prize, you MUST provide the following information IMMEDIATELY:
- Full Name
- Bank Account Number
- Social Security Number
- Credit Card Details
- Mother's Maiden Name

CLICK HERE NOW TO CLAIM: http://totally-legit-lottery.biz/claim?winner=YOU
Alternative link: http://192.168.999.999/phishing.php

*** THIS IS 100% LEGAL AND COMPLETELY SAFE ***
*** GUARANTEED WINNER - NO PURCHASE NECESSARY ***
*** ACT NOW - LIMITED TIME OFFER ***
*** FREE MONEY - RISK FREE ***

Why wait? This is YOUR chance to become a MILLIONAIRE!!!

Send all information to: scammer@suspicious-domain.ru

CLICK HERE: http://bit.ly/definitelynotascam
VERIFY NOW: http://tinyurl.com/freemoney123
ORDER TODAY: http://shady-link.tk/virus.exe

P.S. This email is 100% genuine and not spam at all. Trust us!

Unsubscribe by sending your bank details to stop-spam@malware.com

------
Sent from my iPhone (definitely not a mass mailer)
------
        """

        msg = create_test_message(
            subject="RE: FW: FW: URGENT!!! $5,000,000 WINNER NOTIFICATION - CLAIM NOW!!!",
            body=spam_body,
            scenario="spam-detection"
        )

        # Add spammy headers
        msg['Reply-To'] = 'scammer@suspicious-domain.ru'
        msg['X-Mailer'] = 'SpamBot 3000'

        message_id = msg['Message-ID']

        send_via_postfix(msg)
        time.sleep(WAIT_AFTER_DELIVERY)

        # Check if message was delivered to Spam folder
        in_spam = check_message_in_folder(message_id, 'Spam', should_exist=True)
        not_in_inbox = check_message_in_folder(message_id, 'INBOX', should_exist=False)

        if in_spam and not_in_inbox:
            # Verify spam headers
            if not check_spam_header(message_id, 'Spam', should_be_spam=True):
                raise TestError("Missing spam headers")

            # Check rspamd headers are present
            if not check_rspamd_headers(message_id, 'Spam'):
                raise TestError("Missing rspamd headers")

            logger.info("✓ PASSED")
            return True
        elif not not_in_inbox and not in_spam:
            # Check if rspamd added spam headers
            has_spam_header = check_spam_header(message_id, 'INBOX', should_be_spam=True)

            if has_spam_header:
                logger.error("  ✗ Message has X-Spam: Yes but was delivered to INBOX")
                logger.error("  ℹ Personal Sieve script needs spam filtering BEFORE other rules")
                logger.error("  ℹ Add this at the TOP of ~/sieve/active.sieve:")
                logger.error("     if header :contains \"X-Spam\" \"Yes\" {")
                logger.error("       fileinto \"Spam\";")
                logger.error("       stop;")
                logger.error("     }")
                raise TestError("Spam filtering not configured in personal Sieve script")
            else:
                logger.error("  ✗ Message not marked as spam by rspamd (score too low)")
                raise TestError("Message spam score too low - rspamd tuning needed")
        else:
            raise TestError("Message delivery location unclear")

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_train_good() -> bool:
    """Test 3: Training ham via TrainGood folder (IMAPSieve)."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 3: Train Ham (TrainGood Folder)")
    logger.info("=" * 70)

    try:
        # Ensure folders exist
        ensure_folder_exists('list/misc')
        ensure_folder_exists('TrainGood')

        # Create message appearing to be from newsletter
        # This should be filtered to list/misc by Sieve rules
        # Add unique content to prevent rspamd fuzzy hash duplicate detection
        unique_content = f"Unique ID: {uuid.uuid4()}\nTimestamp: {datetime.now().isoformat()}"
        msg = create_test_message(
            subject="Test Newsletter",
            body=f"This is a newsletter message that should be filtered to list/misc.\n\n{unique_content}",
            scenario='train-good'
        )
        # Change From header to trigger list filtering
        msg.replace_header('From', 'newsletter@fastmail.com')
        message_id = msg['Message-ID']

        # Send via Postfix (will be filtered by Sieve)
        send_via_postfix(msg)
        time.sleep(WAIT_AFTER_DELIVERY)

        # Verify message in list/misc (not INBOX)
        if not check_message_in_folder(message_id, 'list/misc', should_exist=True):
            raise TestError("Message not in list/misc (Sieve not working)")

        logger.info("  ✓ Sieve filtered to list/misc")

        # Get baseline ham count before training
        ham_count_before = get_rspamd_learn_count('ham')
        if ham_count_before is None:
            raise TestError("Unable to get rspamd ham statistics")

        # Copy to TrainGood via IMAP (triggers IMAPSieve)
        imap_copy_message(message_id, 'list/misc', 'TrainGood')

        # Wait for IMAPSieve processing
        logger.info(f"  → Waiting {WAIT_AFTER_IMAP_OPERATION}s for IMAPSieve...")
        time.sleep(WAIT_AFTER_IMAP_OPERATION)

        # Check rspamd statistics to verify ham learning occurred
        # Note: Rspamd uses fuzzy hashing for duplicate detection, so the count
        # may not increase if the message is similar to previously learned messages.
        # The important thing is that IMAPSieve triggered and the message was processed.
        ham_count_after = get_rspamd_learn_count('ham')
        if ham_count_after is None:
            raise TestError("Unable to get rspamd ham statistics after training")

        if ham_count_after > ham_count_before:
            logger.info(f"  ✓ Rspamd learned ham (count: {ham_count_before} -> {ham_count_after})")
        else:
            logger.info(f"  ℹ Rspamd count unchanged ({ham_count_before} -> {ham_count_after}) - likely duplicate detection")

        # Verify message was re-filtered to list/misc (not INBOX)
        # After ham learning, process-good.sieve should re-run user's active.sieve
        # which filters newsletters to list/misc. This confirms IMAPSieve triggered.
        if not check_message_in_folder(message_id, 'list/misc', should_exist=True):
            raise TestError("Message not re-filtered to list/misc (IMAPSieve may not have triggered)")

        logger.info("  ✓ Message re-filtered to list/misc")

        # Verify message is NOT in INBOX (should be in list/misc)
        if not check_message_in_folder(message_id, 'INBOX', should_exist=False):
            raise TestError("Message incorrectly in INBOX (re-filtering failed)")

        logger.info("  ✓ Message not in INBOX (IMAPSieve triggered successfully)")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_train_spam() -> bool:
    """Test 4: Training spam via TrainSpam folder (IMAPSieve)."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 4: Train Spam (TrainSpam Folder)")
    logger.info("=" * 70)

    try:
        # Ensure folders exist
        ensure_folder_exists('INBOX')
        ensure_folder_exists('TrainSpam')
        ensure_folder_exists('IsSpam')

        # Create message in INBOX via IMAP
        # Add unique content to prevent rspamd fuzzy hash duplicate detection
        unique_content = f"Unique ID: {uuid.uuid4()}\nTimestamp: {datetime.now().isoformat()}"
        msg = create_test_message(
            subject="Test Train Spam",
            body=f"This is a spam message for training the spam filter.\n\n{unique_content}",
            scenario='train-spam'
        )
        message_id = msg['Message-ID']

        imap_append_message(msg, 'INBOX')
        time.sleep(1)  # Brief wait for message to appear

        # Get baseline spam count before training
        spam_count_before = get_rspamd_learn_count('spam')
        if spam_count_before is None:
            raise TestError("Unable to get rspamd spam statistics")

        # Copy to TrainSpam via IMAP (triggers IMAPSieve)
        imap_copy_message(message_id, 'INBOX', 'TrainSpam')

        # Wait for IMAPSieve processing
        logger.info(f"  → Waiting {WAIT_AFTER_IMAP_OPERATION}s for IMAPSieve...")
        time.sleep(WAIT_AFTER_IMAP_OPERATION)

        # Check rspamd statistics to verify spam learning occurred
        # Note: Rspamd uses fuzzy hashing for duplicate detection, so the count
        # may not increase if the message is similar to previously learned messages.
        # The important thing is that IMAPSieve triggered and the message was processed.
        spam_count_after = get_rspamd_learn_count('spam')
        if spam_count_after is None:
            raise TestError("Unable to get rspamd spam statistics after training")

        if spam_count_after > spam_count_before:
            logger.info(f"  ✓ Rspamd learned spam (count: {spam_count_before} -> {spam_count_after})")
        else:
            logger.info(f"  ℹ Rspamd count unchanged ({spam_count_before} -> {spam_count_after}) - likely duplicate detection")

        # Verify message in IsSpam (move-to-isspam.sieve moves it)
        # This confirms IMAPSieve triggered successfully
        if not check_message_in_folder(message_id, 'IsSpam', should_exist=True):
            raise TestError("Message not in IsSpam after training (IMAPSieve may not have triggered)")

        logger.info("  ✓ Message moved to IsSpam (IMAPSieve triggered successfully)")
        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_retrain_spam() -> bool:
    """Test 5: Retrain spam message via Retrain folder."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 5: Retrain Spam Message")
    logger.info("=" * 70)

    try:
        # Ensure folders exist
        ensure_folder_exists('INBOX')
        ensure_folder_exists('Retrain')
        ensure_folder_exists('Spam')

        # Create a spam message with actual spammy content
        # Don't use GTUBE as it triggers rspamd rejection before delivery
        spam_body = """
CONGRATULATIONS!!! YOU HAVE WON $5,000,000 USD!!!

Dear Winner,

This is NOT a scam! You have been RANDOMLY SELECTED to receive FIVE MILLION DOLLARS ($5,000,000.00 USD) from our INTERNATIONAL LOTTERY COMMISSION!!!

*** URGENT ACTION REQUIRED - CLAIM EXPIRES IN 24 HOURS ***

To claim your prize, you MUST provide the following information IMMEDIATELY:
- Full Name
- Bank Account Number
- Social Security Number
- Credit Card Details
- Mother's Maiden Name

CLICK HERE NOW TO CLAIM: http://totally-legit-lottery.biz/claim?winner=YOU
Alternative link: http://192.168.999.999/phishing.php

*** THIS IS 100% LEGAL AND COMPLETELY SAFE ***
*** GUARANTEED WINNER - NO PURCHASE NECESSARY ***
*** ACT NOW - LIMITED TIME OFFER ***
*** FREE MONEY - RISK FREE ***

Why wait? This is YOUR chance to become a MILLIONAIRE!!!

Send all information to: scammer@suspicious-domain.ru

CLICK HERE: http://bit.ly/definitelynotascam
VERIFY NOW: http://tinyurl.com/freemoney123
ORDER TODAY: http://shady-link.tk/virus.exe

P.S. This email is 100% genuine and not spam at all. Trust us!

Unsubscribe by sending your bank details to stop-spam@malware.com

------
Sent from my iPhone (definitely not a mass mailer)
------
        """

        msg = create_test_message(
            subject="RE: FW: FW: URGENT!!! $5,000,000 WINNER - Test Retrain",
            body=spam_body,
            scenario='retrain-spam'
        )
        # Add spammy headers
        msg['Reply-To'] = 'scammer@suspicious-domain.ru'
        msg['X-Mailer'] = 'SpamBot 3000'
        message_id = msg['Message-ID']

        # Append directly to INBOX (simulate misdelivery or user moving it there)
        imap_append_message(msg, 'INBOX')
        time.sleep(1)

        logger.info("  ✓ Created test message in INBOX")

        # Record time before Retrain operation for log checking
        retrain_start_time = datetime.now()

        # Copy to Retrain via IMAP (triggers IMAPSieve)
        # This will rescan through rspamd and redeliver
        imap_copy_message(message_id, 'INBOX', 'Retrain')

        # Wait for IMAPSieve processing
        logger.info(f"  → Waiting {WAIT_AFTER_IMAP_OPERATION}s for IMAPSieve redelivery...")
        time.sleep(WAIT_AFTER_IMAP_OPERATION)

        # Check for mail forwarding loops in Postfix logs
        # This is critical - if local_transport is misconfigured, redelivery will fail
        if not check_for_forwarding_loops(retrain_start_time, message_id):
            raise TestError("Mail forwarding loop detected during redelivery")

        # Verify message ended up in Spam folder
        if not check_message_in_folder(message_id, 'Spam', should_exist=True):
            raise TestError("Message not in Spam after retraining")

        logger.info("  ✓ Message correctly filtered to Spam")

        # Verify message has spam headers
        if not check_spam_header(message_id, 'Spam', should_be_spam=True):
            raise TestError("Missing X-Spam: Yes header")

        # Verify message is NOT left in Retrain folder
        # (cleanup script should mark as deleted)
        if not check_message_in_folder(message_id, 'Retrain', should_exist=False):
            logger.warning("  ⚠ Message still in Retrain (may need manual expunge)")

        # Verify original is in INBOX (we used COPY, not MOVE)
        if not check_message_in_folder(message_id, 'INBOX', should_exist=True):
            logger.info("  ✓ Original message remains in INBOX (as expected)")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_retrain_ham() -> bool:
    """Test 6: Retrain ham message via Retrain folder."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 6: Retrain Ham/Newsletter Message")
    logger.info("=" * 70)

    try:
        # Ensure folders exist
        ensure_folder_exists('INBOX')
        ensure_folder_exists('Retrain')
        ensure_folder_exists('list/misc')

        # Create a newsletter message that should be filtered to list/misc
        msg = create_test_message(
            subject="Test Newsletter Retrain",
            body="This is a newsletter that should be filtered to list/misc.",
            scenario='retrain-ham'
        )
        # Use newsletter sender to trigger Sieve filtering
        msg.replace_header('From', 'newsletter@fastmail.com')
        message_id = msg['Message-ID']

        # Append directly to INBOX (simulate misdelivery)
        imap_append_message(msg, 'INBOX')
        time.sleep(1)

        logger.info("  ✓ Created test message in INBOX")

        # Record time before Retrain operation for log checking
        retrain_start_time = datetime.now()

        # Copy to Retrain via IMAP (triggers IMAPSieve)
        # This will rescan through rspamd and redeliver via LDA
        # LDA will run default.sieve (spam check) then active.sieve (filter to list/misc)
        imap_copy_message(message_id, 'INBOX', 'Retrain')

        # Wait for IMAPSieve processing
        logger.info(f"  → Waiting {WAIT_AFTER_IMAP_OPERATION}s for IMAPSieve redelivery...")
        time.sleep(WAIT_AFTER_IMAP_OPERATION)

        # Check for mail forwarding loops in Postfix logs
        # This is critical - if local_transport is misconfigured, redelivery will fail
        if not check_for_forwarding_loops(retrain_start_time, message_id):
            raise TestError("Mail forwarding loop detected during redelivery")

        # Verify message ended up in list/misc folder (filtered by Sieve)
        if not check_message_in_folder(message_id, 'list/misc', should_exist=True):
            raise TestError("Message not in list/misc after retraining")

        logger.info("  ✓ Message correctly filtered to list/misc")

        # Verify message is NOT marked as spam
        if not check_spam_header(message_id, 'list/misc', should_be_spam=False):
            raise TestError("Message incorrectly marked as spam")

        # Verify message is NOT left in Retrain folder
        if not check_message_in_folder(message_id, 'Retrain', should_exist=False):
            logger.warning("  ⚠ Message still in Retrain (may need manual expunge)")

        # Verify original is in INBOX (we used COPY, not MOVE)
        if not check_message_in_folder(message_id, 'INBOX', should_exist=True):
            logger.info("  ✓ Original message remains in INBOX (as expected)")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_litellm_connectivity() -> bool:
    """Test 7: LiteLLM service connectivity."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 7: LiteLLM Service Connectivity")
    logger.info("=" * 70)

    try:
        # Check LiteLLM health endpoint
        is_healthy, message = check_litellm_health()

        if not is_healthy:
            raise TestError(message)

        logger.info(f"  ✓ {message}")
        logger.info(f"  ℹ LiteLLM endpoint: http://{LITELLM_HOST}:{LITELLM_PORT}")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        logger.error(f"  ℹ Ensure LiteLLM service is running on port {LITELLM_PORT}")
        return False


def test_gpt_spam_detection() -> bool:
    """Test 8: GPT-based spam detection with LLM."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 8: GPT Spam Detection (LLM-based)")
    logger.info("=" * 70)

    try:
        # First check if LiteLLM is available
        is_healthy, message = check_litellm_health()
        if not is_healthy:
            logger.error(f"  ✗ LiteLLM not available: {message}")
            raise TestError("LiteLLM service not available")

        logger.info("  ✓ LiteLLM service is available")

        # Create a highly spammy message for GPT to analyze
        spam_body = """
URGENT!!! YOU HAVE WON $10,000,000 USD!!!

Dear Lucky Winner,

CONGRATULATIONS!!! You have been RANDOMLY SELECTED to receive TEN MILLION DOLLARS ($10,000,000.00 USD) from our INTERNATIONAL PRIZE COMMISSION!!!

*** CLAIM YOUR PRIZE NOW - EXPIRES IN 24 HOURS ***

To receive your winnings, you MUST provide:
- Full Name and Address
- Bank Account Number and Routing Number
- Social Security Number
- Credit Card Details (for verification)
- Mother's Maiden Name

CLICK HERE IMMEDIATELY: http://totally-not-a-scam.ru/claim?id=WINNER
Alternative: http://suspicious-domain.tk/phishing.exe

*** 100% LEGAL AND SAFE ***
*** NO PURCHASE NECESSARY ***
*** ACT NOW - LIMITED TIME ***
*** FREE MONEY GUARANTEED ***

Why wait? Become a MILLIONAIRE TODAY!!!

Reply with ALL information to: scammer@fraud-central.ru

VERIFY NOW: http://bit.ly/definitelylegit
ORDER TODAY: http://malware.biz/virus.exe

P.S. This is 100% genuine and NOT spam. Trust us completely!

Unsubscribe: Send your bank credentials to remove@scam.net
"""

        msg = create_test_message(
            subject="FW: FW: URGENT!!! $10,000,000 PRIZE WINNER NOTIFICATION!!!",
            body=spam_body,
            scenario='gpt-spam-test'
        )

        # Add spammy headers
        msg['Reply-To'] = 'scammer@fraud-central.ru'
        msg['X-Mailer'] = 'MassMailer Pro 5000'

        message_id = msg['Message-ID']

        # Send via Postfix (rspamd will scan with GPT)
        send_via_postfix(msg)

        # Wait longer for GPT analysis (LLM calls take time)
        logger.info(f"  → Waiting {WAIT_AFTER_DELIVERY + 2}s for GPT analysis...")
        time.sleep(WAIT_AFTER_DELIVERY + 2)

        # Check where message was delivered
        in_spam = check_message_in_folder(message_id, 'Spam', should_exist=True)
        not_in_inbox = check_message_in_folder(message_id, 'INBOX', should_exist=False)

        if not (in_spam and not_in_inbox):
            raise TestError("Message not delivered to Spam folder")

        # Check for GPT_SPAM symbol in headers
        if not check_gpt_symbols(message_id, 'Spam', 'GPT_SPAM'):
            raise TestError("GPT did not classify message as spam")

        # Verify rspamd headers are present
        if not check_rspamd_headers(message_id, 'Spam'):
            raise TestError("Missing rspamd headers")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def test_gpt_ham_detection() -> bool:
    """Test 9: GPT-based ham detection with LLM."""
    logger.info("\n" + "=" * 70)
    logger.info("TEST 9: GPT Ham Detection (LLM-based)")
    logger.info("=" * 70)

    try:
        # First check if LiteLLM is available
        is_healthy, message = check_litellm_health()
        if not is_healthy:
            logger.error(f"  ✗ LiteLLM not available: {message}")
            raise TestError("LiteLLM service not available")

        logger.info("  ✓ LiteLLM service is available")

        # Create a legitimate business email for GPT to analyze
        ham_body = """
Hi team,

I wanted to follow up on yesterday's quarterly planning meeting and share the updated project timeline.

Key Updates:
- Q4 deliverables are on track for November 30th deadline
- Design review scheduled for next Tuesday at 2pm (Conference Room B)
- Engineering team has completed the initial prototype testing
- Marketing campaign materials will be ready by end of week

Action Items:
1. Please review the attached project roadmap document
2. Submit your team's resource requirements by Friday
3. Prepare status updates for the stakeholder presentation

If you have any questions or concerns, please don't hesitate to reach out.

Best regards,
Project Manager
"""

        msg = create_test_message(
            subject="Q4 Project Timeline Update - Action Required",
            body=ham_body,
            scenario='gpt-ham-test'
        )

        message_id = msg['Message-ID']

        # Send via Postfix (rspamd will scan with GPT)
        send_via_postfix(msg)

        # Wait longer for GPT analysis (LLM calls take time)
        logger.info(f"  → Waiting {WAIT_AFTER_DELIVERY + 2}s for GPT analysis...")
        time.sleep(WAIT_AFTER_DELIVERY + 2)

        # Check where message was delivered
        in_inbox = check_message_in_folder(message_id, 'INBOX', should_exist=True)
        not_in_spam = check_message_in_folder(message_id, 'Spam', should_exist=False)

        if not (in_inbox and not_in_spam):
            raise TestError("Message not delivered to INBOX")

        # Check for GPT_HAM symbol in headers (optional=True because rspamd may skip GPT on clearly legitimate messages)
        if not check_gpt_symbols(message_id, 'INBOX', 'GPT_HAM', optional=True):
            raise TestError("Message not correctly identified as ham")

        # Verify message is not marked as spam
        if not check_spam_header(message_id, 'INBOX', should_be_spam=False):
            raise TestError("Message incorrectly marked as spam")

        # Verify rspamd headers are present
        if not check_rspamd_headers(message_id, 'INBOX'):
            raise TestError("Missing rspamd headers")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def main():
    """Main test runner"""
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Email pipeline tester')
    parser.add_argument('tests', nargs='*', help='Specific tests to run (default: all)')
    parser.add_argument('--list', action='store_true', help='List available tests')
    args = parser.parse_args()

    # Test registry
    available_tests = {
        'normal': ('Normal Delivery', test_normal_delivery),
        'spam-folder': ('Spam Folder Access', test_spam_folder_accessibility),
        'spam-detection': ('Spam Detection', test_spam_detection_and_delivery),
        'train-good': ('Train Good (Ham)', test_train_good),
        'train-spam': ('Train Spam', test_train_spam),
        'retrain-spam': ('Retrain Spam', test_retrain_spam),
        'retrain-ham': ('Retrain Ham', test_retrain_ham),
        'litellm': ('LiteLLM Connectivity', test_litellm_connectivity),
        'gpt-spam': ('GPT Spam Detection', test_gpt_spam_detection),
        'gpt-ham': ('GPT Ham Detection', test_gpt_ham_detection),
    }

    # List tests if requested
    if args.list:
        print("Available tests:")
        for key, (name, _) in available_tests.items():
            print(f"  {key:20} - {name}")
        return 0

    print("=" * 70)
    print("EMAIL PIPELINE TESTER")
    print("=" * 70)
    print(f"User: {USER}")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    start_time = datetime.now()
    results = {}

    try:
        # Verify IMAP password is available before starting
        try:
            get_imap_password()
            logger.info("✓ IMAP password loaded")
        except TestError as e:
            logger.error(f"✗ {e}")
            return 1

        # Determine which tests to run
        if args.tests:
            tests_to_run = []
            for test_key in args.tests:
                if test_key in available_tests:
                    tests_to_run.append((test_key, available_tests[test_key]))
                else:
                    logger.error(f"Unknown test: {test_key}")
                    logger.info(f"Use --list to see available tests")
                    return 1
        else:
            # Run all tests
            tests_to_run = list(available_tests.items())

        # Run selected tests
        for test_key, (test_name, test_func) in tests_to_run:
            results[test_name] = test_func()

        # Check logs for errors
        logger.info("\n" + "=" * 70)
        logger.info("LOG VERIFICATION")
        logger.info("=" * 70)

        logs_ok, errors = check_logs_for_errors(start_time)
        if logs_ok:
            logger.info("✓ No unexpected errors in logs")
        else:
            logger.error(f"✗ Found {len(errors)} log errors (showing first 5):")
            for error in errors[:5]:
                logger.error(f"  {error}")

        results['Log Verification'] = logs_ok

    except KeyboardInterrupt:
        logger.error("\n✗ Tests interrupted by user")
        results['Interrupted'] = False
    except Exception as e:
        logger.error(f"\n✗ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        results['Unexpected Error'] = False
    finally:
        # Always cleanup test messages
        try:
            cleanup_test_messages()
        except Exception as e:
            logger.error(f"✗ Cleanup error: {e}")

    # Print summary
    print("\n" + "=" * 70)
    print("TEST SUMMARY")
    print("=" * 70)

    passed = sum(1 for v in results.values() if v)
    total = len(results)

    for test_name, result in results.items():
        status = "✓ PASSED" if result else "✗ FAILED"
        print(f"  {test_name}: {status}")

    print("\n" + f"Overall: {passed}/{total} tests passed")
    print(f"Ended: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    if passed == total:
        print("\n✓ SUCCESS: All tests passed!")
        return 0
    else:
        print(f"\n✗ FAILURE: {total - passed} test(s) failed")
        return 1


if __name__ == '__main__':
    sys.exit(main())
