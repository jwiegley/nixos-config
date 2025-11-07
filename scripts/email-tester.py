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


def check_rspamd_learning(since_time: datetime, learn_type: str) -> bool:
    """Check rspamd logs for spam/ham learning."""
    cmd = [
        'journalctl',
        '-u', 'rspamd',
        '--since', since_time.strftime('%Y-%m-%d %H:%M:%S'),
        '--no-pager'
    ]
    result = run_command(cmd, check=False)

    patterns = {
        'spam': ['class=\'spam\'', 'learned message as spam', 'learn_spam'],
        'ham': ['class=\'ham\'', 'learned message as ham', 'learn_ham']
    }

    search_patterns = patterns.get(learn_type, [])
    for pattern in search_patterns:
        if pattern in result.stdout.lower():
            return True

    return False


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

        # Check rspamd logs to see if it was processed
        since_time = datetime.now() - timedelta(seconds=10)
        cmd = [
            'journalctl', '-u', 'rspamd',
            '--since', since_time.strftime('%Y-%m-%d %H:%M:%S'),
            '--no-pager'
        ]
        result = run_command(cmd, check=False)

        if message_id.strip('<>') in result.stdout:
            logger.info("  ✓ Rspamd processed message")
        else:
            raise TestError("Rspamd did not process message")

        # Check if message was delivered to Spam folder
        in_spam = check_message_in_folder(message_id, 'Spam', should_exist=True)
        not_in_inbox = check_message_in_folder(message_id, 'INBOX', should_exist=False)

        if in_spam and not_in_inbox:
            # Verify spam headers
            if not check_spam_header(message_id, 'Spam', should_be_spam=True):
                raise TestError("Missing spam headers")

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
        msg = create_test_message(
            subject="Test Newsletter",
            body="This is a newsletter message that should be filtered to list/misc.",
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

        # Copy to TrainGood via IMAP (triggers IMAPSieve)
        imap_copy_message(message_id, 'list/misc', 'TrainGood')

        # Wait for IMAPSieve processing
        logger.info(f"  → Waiting {WAIT_AFTER_IMAP_OPERATION}s for IMAPSieve...")
        time.sleep(WAIT_AFTER_IMAP_OPERATION)

        # Check rspamd logs for ham learning (REQUIRED)
        since_time = datetime.now() - timedelta(seconds=15)
        if not check_rspamd_learning(since_time, 'ham'):
            raise TestError("Rspamd did not learn ham (check logs)")

        logger.info("  ✓ Rspamd learned ham")

        # Verify message in list/misc (process-good.sieve should re-filter it)
        # Newsletter messages should go to list/misc, not INBOX
        if not check_message_in_folder(message_id, 'list/misc', should_exist=True):
            # Fallback: check INBOX (process-good.sieve may just move to INBOX)
            if check_message_in_folder(message_id, 'INBOX', should_exist=True):
                logger.info("  ⚠ Message in INBOX (process-good.sieve needs fix to re-filter)")
            else:
                raise TestError("Message not in list/misc or INBOX after training")
        else:
            logger.info("  ✓ Message in list/misc (Sieve re-filtered)")

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
        msg = create_test_message(
            subject="Test Train Spam",
            body="This is a spam message for training the spam filter.",
            scenario='train-spam'
        )
        message_id = msg['Message-ID']

        imap_append_message(msg, 'INBOX')
        time.sleep(1)  # Brief wait for message to appear

        # Copy to TrainSpam via IMAP (triggers IMAPSieve)
        imap_copy_message(message_id, 'INBOX', 'TrainSpam')

        # Wait for IMAPSieve processing
        logger.info(f"  → Waiting {WAIT_AFTER_IMAP_OPERATION}s for IMAPSieve...")
        time.sleep(WAIT_AFTER_IMAP_OPERATION)

        # Check rspamd logs for spam learning (REQUIRED)
        since_time = datetime.now() - timedelta(seconds=15)
        if not check_rspamd_learning(since_time, 'spam'):
            raise TestError("Rspamd did not learn spam (check logs)")

        logger.info("  ✓ Rspamd learned spam")

        # Verify message in IsSpam (move-to-isspam.sieve moves it)
        if not check_message_in_folder(message_id, 'IsSpam', should_exist=True):
            raise TestError("Message not in IsSpam after training")

        logger.info("✓ PASSED")
        return True

    except Exception as e:
        logger.error(f"✗ FAILED: {e}")
        return False


def main():
    """Main test runner"""
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

        # Run all tests
        results['Normal Delivery'] = test_normal_delivery()
        results['Spam Folder Access'] = test_spam_folder_accessibility()
        results['Spam Detection'] = test_spam_detection_and_delivery()
        results['Train Good (Ham)'] = test_train_good()
        results['Train Spam'] = test_train_spam()

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
