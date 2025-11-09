#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python3Packages.requests
"""
Paperless-ngx Metadata Deletion Script

This script deletes all tags and document types from a paperless-ngx instance.
It uses the REST API and includes safety features like dry-run mode and confirmation prompts.

Usage:
    # Dry-run mode (default) - shows what would be deleted
    ./paperless-delete-metadata.py

    # Actually delete (requires confirmation)
    ./paperless-delete-metadata.py --execute

    # Delete only tags
    ./paperless-delete-metadata.py --execute --tags-only

    # Delete only document types
    ./paperless-delete-metadata.py --execute --document-types-only

    # Non-interactive mode (dangerous!)
    ./paperless-delete-metadata.py --execute --yes

    # Use custom CA certificate
    ./paperless-delete-metadata.py --ca-cert /path/to/ca.crt

    # Disable SSL verification (insecure!)
    ./paperless-delete-metadata.py --insecure

Environment variables:
    PAPERLESS_URL: Base URL of paperless-ngx instance (e.g., https://paperless.vulcan.lan)
    PAPERLESS_TOKEN: API authentication token
"""

import argparse
import os
import sys
import time
from typing import List, Dict, Tuple
from urllib.parse import urljoin, urlparse

try:
    import requests
except ImportError:
    print("Error: 'requests' library not found. Install with: pip install requests")
    sys.exit(1)


class PaperlessAPI:
    """Client for interacting with the paperless-ngx REST API."""

    def __init__(self, base_url: str, token: str, verify=True):
        """
        Initialize the API client.

        Args:
            base_url: Base URL of the paperless-ngx instance
            token: API authentication token
            verify: SSL certificate verification. Can be True (verify with system certs),
                   False (disable verification), or a path to a CA bundle file
        """
        self.base_url = base_url.rstrip('/')
        self.token = token
        self.verify = verify
        self.session = requests.Session()
        self.session.headers.update({
            'Authorization': f'Token {token}',
            'Content-Type': 'application/json',
        })

    def _make_request(self, method: str, endpoint: str, **kwargs) -> requests.Response:
        """
        Make an HTTP request to the API.

        Args:
            method: HTTP method (GET, DELETE, etc.)
            endpoint: API endpoint path
            **kwargs: Additional arguments to pass to requests

        Returns:
            Response object

        Raises:
            requests.RequestException: If the request fails
        """
        url = urljoin(self.base_url, endpoint)
        # Set verify parameter if not already specified in kwargs
        if 'verify' not in kwargs:
            kwargs['verify'] = self.verify
        response = self.session.request(method, url, **kwargs)
        response.raise_for_status()
        return response

    def get_tags(self) -> List[Dict]:
        """
        Get all tags from paperless-ngx (handles pagination).

        Returns:
            List of tag dictionaries with 'id', 'name', etc.
        """
        all_tags = []
        url = '/api/tags/'

        while url:
            response = self._make_request('GET', url)
            data = response.json()
            all_tags.extend(data.get('results', []))

            # Get the next page URL (relative to base URL)
            next_url = data.get('next')
            if next_url:
                # Extract the path and query from the full URL
                parsed = urlparse(next_url)
                url = f"{parsed.path}?{parsed.query}" if parsed.query else parsed.path
            else:
                url = None

        return all_tags

    def delete_tag(self, tag_id: int) -> bool:
        """
        Delete a tag by ID.

        Args:
            tag_id: ID of the tag to delete

        Returns:
            True if successful, False otherwise
        """
        try:
            self._make_request('DELETE', f'/api/tags/{tag_id}/')
            return True
        except requests.RequestException as e:
            print(f"  Error deleting tag {tag_id}: {e}")
            return False

    def get_document_types(self) -> List[Dict]:
        """
        Get all document types from paperless-ngx (handles pagination).

        Returns:
            List of document type dictionaries with 'id', 'name', etc.
        """
        all_doc_types = []
        url = '/api/document_types/'

        while url:
            response = self._make_request('GET', url)
            data = response.json()
            all_doc_types.extend(data.get('results', []))

            # Get the next page URL (relative to base URL)
            next_url = data.get('next')
            if next_url:
                # Extract the path and query from the full URL
                parsed = urlparse(next_url)
                url = f"{parsed.path}?{parsed.query}" if parsed.query else parsed.path
            else:
                url = None

        return all_doc_types

    def delete_document_type(self, doc_type_id: int) -> bool:
        """
        Delete a document type by ID.

        Args:
            doc_type_id: ID of the document type to delete

        Returns:
            True if successful, False otherwise
        """
        try:
            self._make_request('DELETE', f'/api/document_types/{doc_type_id}/')
            return True
        except requests.RequestException as e:
            print(f"  Error deleting document type {doc_type_id}: {e}")
            return False


def print_header(text: str):
    """Print a formatted section header."""
    print(f"\n{'=' * 70}")
    print(f"  {text}")
    print('=' * 70)


def confirm_deletion(item_count: int, item_type: str) -> bool:
    """
    Ask user for confirmation before deletion.

    Args:
        item_count: Number of items to delete
        item_type: Type of item (e.g., "tags", "document types")

    Returns:
        True if user confirms, False otherwise
    """
    print(f"\n⚠️  WARNING: You are about to delete {item_count} {item_type}.")
    print("This action is IRREVERSIBLE and will remove these metadata items from all documents.")
    print("\nDocuments themselves will NOT be deleted, but their metadata associations will be lost.")

    response = input(f"\nType 'DELETE {item_count} {item_type.upper()}' to confirm: ")
    expected = f"DELETE {item_count} {item_type.upper()}"

    return response.strip() == expected


def delete_all_tags(api: PaperlessAPI, dry_run: bool, auto_yes: bool) -> Tuple[int, int]:
    """
    Delete all tags from paperless-ngx.

    Args:
        api: PaperlessAPI client instance
        dry_run: If True, only show what would be deleted
        auto_yes: If True, skip confirmation prompt

    Returns:
        Tuple of (successful_deletes, failed_deletes)
    """
    print_header("TAGS")

    print("Fetching all tags...")
    tags = api.get_tags()

    if not tags:
        print("No tags found.")
        return 0, 0

    print(f"Found {len(tags)} tags:")
    for tag in tags:
        print(f"  - [{tag['id']}] {tag['name']}")

    if dry_run:
        print(f"\n[DRY-RUN] Would delete {len(tags)} tags (use --execute to actually delete)")
        return 0, 0

    if not auto_yes:
        if not confirm_deletion(len(tags), "tags"):
            print("Deletion cancelled by user.")
            return 0, 0

    print(f"\nDeleting {len(tags)} tags...")
    success_count = 0
    fail_count = 0

    for i, tag in enumerate(tags, 1):
        print(f"[{i}/{len(tags)}] Deleting tag '{tag['name']}' (ID: {tag['id']})...", end=' ')
        if api.delete_tag(tag['id']):
            print("✓ Success")
            success_count += 1
        else:
            print("✗ Failed")
            fail_count += 1
        time.sleep(0.1)  # Brief delay to avoid overwhelming the API

    return success_count, fail_count


def delete_all_document_types(api: PaperlessAPI, dry_run: bool, auto_yes: bool) -> Tuple[int, int]:
    """
    Delete all document types from paperless-ngx.

    Args:
        api: PaperlessAPI client instance
        dry_run: If True, only show what would be deleted
        auto_yes: If True, skip confirmation prompt

    Returns:
        Tuple of (successful_deletes, failed_deletes)
    """
    print_header("DOCUMENT TYPES")

    print("Fetching all document types...")
    doc_types = api.get_document_types()

    if not doc_types:
        print("No document types found.")
        return 0, 0

    print(f"Found {len(doc_types)} document types:")
    for doc_type in doc_types:
        print(f"  - [{doc_type['id']}] {doc_type['name']}")

    if dry_run:
        print(f"\n[DRY-RUN] Would delete {len(doc_types)} document types (use --execute to actually delete)")
        return 0, 0

    if not auto_yes:
        if not confirm_deletion(len(doc_types), "document types"):
            print("Deletion cancelled by user.")
            return 0, 0

    print(f"\nDeleting {len(doc_types)} document types...")
    success_count = 0
    fail_count = 0

    for i, doc_type in enumerate(doc_types, 1):
        print(f"[{i}/{len(doc_types)}] Deleting document type '{doc_type['name']}' (ID: {doc_type['id']})...", end=' ')
        if api.delete_document_type(doc_type['id']):
            print("✓ Success")
            success_count += 1
        else:
            print("✗ Failed")
            fail_count += 1
        time.sleep(0.1)  # Brief delay to avoid overwhelming the API

    return success_count, fail_count


def main():
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(
        description="Delete all tags and document types from paperless-ngx",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry-run mode (shows what would be deleted)
  %(prog)s

  # Actually delete all tags and document types
  %(prog)s --execute

  # Delete only tags
  %(prog)s --execute --tags-only

  # Delete only document types
  %(prog)s --execute --document-types-only

  # Non-interactive deletion (dangerous!)
  %(prog)s --execute --yes

  # Use custom CA certificate
  %(prog)s --ca-cert /path/to/ca.crt

  # Disable SSL verification (not recommended)
  %(prog)s --insecure

Environment Variables:
  PAPERLESS_URL    Base URL of paperless-ngx (e.g., https://paperless.vulcan.lan)
  PAPERLESS_TOKEN  API authentication token
        """
    )

    parser.add_argument(
        '--url',
        default=os.environ.get('PAPERLESS_URL', 'https://paperless.vulcan.lan'),
        help='Paperless-ngx base URL (default: $PAPERLESS_URL or https://paperless.vulcan.lan)'
    )

    parser.add_argument(
        '--token',
        default=os.environ.get('PAPERLESS_TOKEN'),
        help='API authentication token (default: $PAPERLESS_TOKEN)'
    )

    parser.add_argument(
        '--execute',
        action='store_true',
        help='Actually delete items (default is dry-run mode)'
    )

    parser.add_argument(
        '--yes', '-y',
        action='store_true',
        help='Skip confirmation prompts (DANGEROUS!)'
    )

    parser.add_argument(
        '--tags-only',
        action='store_true',
        help='Delete only tags (not document types)'
    )

    parser.add_argument(
        '--document-types-only',
        action='store_true',
        help='Delete only document types (not tags)'
    )

    parser.add_argument(
        '--ca-cert',
        help='Path to CA certificate bundle for SSL verification (default: auto-detect /etc/ssl/certs/vulcan-ca.crt)'
    )

    parser.add_argument(
        '--insecure',
        action='store_true',
        help='Disable SSL certificate verification (NOT RECOMMENDED)'
    )

    args = parser.parse_args()

    # Validate inputs
    if not args.token:
        print("Error: API token is required. Provide via --token or PAPERLESS_TOKEN environment variable.")
        print("\nTo get an API token:")
        print("1. Log in to paperless-ngx web interface")
        print("2. Go to Settings → API Tokens")
        print("3. Create a new token and copy it")
        sys.exit(1)

    # Determine what to delete
    delete_tags = not args.document_types_only
    delete_doc_types = not args.tags_only

    # Determine SSL certificate verification setting
    if args.insecure:
        verify_ssl = False
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    elif args.ca_cert:
        verify_ssl = args.ca_cert
        if not os.path.exists(verify_ssl):
            print(f"Error: CA certificate file not found: {verify_ssl}")
            sys.exit(1)
    else:
        # Auto-detect Step-CA certificate on vulcan
        vulcan_ca = '/etc/ssl/certs/vulcan-ca.crt'
        if os.path.exists(vulcan_ca):
            verify_ssl = vulcan_ca
        else:
            verify_ssl = True  # Use system default CA bundle

    # Print execution mode
    mode = "DRY-RUN MODE" if not args.execute else "EXECUTION MODE"
    print_header(f"Paperless-ngx Metadata Deletion - {mode}")
    print(f"URL: {args.url}")
    print(f"Delete tags: {'Yes' if delete_tags else 'No'}")
    print(f"Delete document types: {'Yes' if delete_doc_types else 'No'}")

    # Print SSL verification status
    if verify_ssl is False:
        print(f"SSL verification: DISABLED (insecure)")
    elif verify_ssl is True:
        print(f"SSL verification: Enabled (system CA bundle)")
    else:
        print(f"SSL verification: Enabled (CA: {verify_ssl})")

    if not args.execute:
        print("\n⚠️  Running in DRY-RUN mode. No changes will be made.")
        print("Use --execute flag to actually delete items.")

    # Initialize API client
    try:
        api = PaperlessAPI(args.url, args.token, verify=verify_ssl)
    except Exception as e:
        print(f"\nError initializing API client: {e}")
        sys.exit(1)

    # Track statistics
    total_success = 0
    total_failed = 0

    # Delete tags
    if delete_tags:
        try:
            success, failed = delete_all_tags(api, not args.execute, args.yes)
            total_success += success
            total_failed += failed
        except requests.RequestException as e:
            print(f"\nError fetching or deleting tags: {e}")
            sys.exit(1)
        except KeyboardInterrupt:
            print("\n\nOperation cancelled by user (Ctrl+C).")
            sys.exit(130)

    # Delete document types
    if delete_doc_types:
        try:
            success, failed = delete_all_document_types(api, not args.execute, args.yes)
            total_success += success
            total_failed += failed
        except requests.RequestException as e:
            print(f"\nError fetching or deleting document types: {e}")
            sys.exit(1)
        except KeyboardInterrupt:
            print("\n\nOperation cancelled by user (Ctrl+C).")
            sys.exit(130)

    # Print final summary
    if args.execute:
        print_header("SUMMARY")
        print(f"Successfully deleted: {total_success}")
        print(f"Failed to delete: {total_failed}")
        print(f"Total processed: {total_success + total_failed}")

        if total_failed > 0:
            print("\n⚠️  Some items failed to delete. Check error messages above.")
            sys.exit(1)
        elif total_success > 0:
            print("\n✓ All items deleted successfully!")
    else:
        print_header("DRY-RUN COMPLETE")
        print("No changes were made. Use --execute to perform actual deletion.")

    sys.exit(0)


if __name__ == '__main__':
    main()
