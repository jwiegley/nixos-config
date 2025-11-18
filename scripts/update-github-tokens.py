#!/usr/bin/env python3
"""
Bulk update GitHub tokens for all Gitea push and pull mirrors.

This script updates the GitHub authentication credentials for all mirrored
repositories in Gitea, both for push mirrors (bidirectional sync) and pull
mirrors (GitHub -> Gitea).

Usage:
    update-github-tokens.py <new-github-token> [--dry-run] [--verbose]
    update-github-tokens.py --help

Examples:
    # Test what would be updated without making changes
    update-github-tokens.py ghp_newtoken123 --dry-run

    # Update all mirrors with new token
    sudo update-github-tokens.py ghp_newtoken123 --verbose

    # Pipe token from stdin for security
    echo "ghp_newtoken123" | sudo update-github-tokens.py --stdin --verbose
"""

import argparse
import json
import logging
import ssl
import sys
from dataclasses import dataclass
from http.client import HTTPResponse
from pathlib import Path
from typing import Dict, List, Optional, Union
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen


# Configuration constants
GITEA_URL = "https://gitea.vulcan.lan"
GITEA_USER = "johnw"
GITHUB_USER = "jwiegley"
GITEA_TOKEN_PATH = "/run/secrets/gitea-mirror-token"


@dataclass
class UpdateStats:
    """Track statistics for the update operation."""
    total_repos: int = 0
    push_mirrors_updated: int = 0
    pull_mirrors_updated: int = 0
    push_mirrors_failed: int = 0
    pull_mirrors_failed: int = 0
    skipped_repos: int = 0

    def summary(self) -> str:
        """Generate a summary report."""
        return f"""
========================================
Update Summary
========================================
Repositories processed:     {self.total_repos}
Push mirrors updated:       {self.push_mirrors_updated}
Pull mirrors updated:       {self.pull_mirrors_updated}
Push mirrors failed:        {self.push_mirrors_failed}
Pull mirrors failed:        {self.pull_mirrors_failed}
Repositories skipped:       {self.skipped_repos}
========================================
Total mirrors updated:      {self.push_mirrors_updated + self.pull_mirrors_updated}
Total failures:             {self.push_mirrors_failed + self.pull_mirrors_failed}
========================================
"""


class GiteaAPIClient:
    """Client for interacting with Gitea API."""

    def __init__(self, base_url: str, token: str, dry_run: bool = False):
        """
        Initialize Gitea API client.

        Args:
            base_url: Base URL for Gitea instance (e.g., https://gitea.vulcan.lan)
            token: Gitea API token for authentication
            dry_run: If True, don't make any actual changes
        """
        self.base_url = base_url.rstrip('/')
        self.token = token
        self.dry_run = dry_run
        self.headers = {
            'Authorization': f'token {token}',
            'Content-Type': 'application/json'
        }
        # Create SSL context that doesn't verify certificates for internal .lan domains
        self.ssl_context = ssl.create_default_context()
        self.ssl_context.check_hostname = False
        self.ssl_context.verify_mode = ssl.CERT_NONE
        self.logger = logging.getLogger(__name__)

    def _make_request(
        self,
        method: str,
        endpoint: str,
        data: Optional[Dict] = None,
        params: Optional[Dict] = None
    ) -> Dict:
        """
        Make an API request to Gitea.

        Args:
            method: HTTP method (GET, POST, PATCH, etc.)
            endpoint: API endpoint (e.g., /api/v1/users/johnw/repos)
            data: JSON data for POST/PATCH requests
            params: Query parameters

        Returns:
            Dictionary with 'ok' (bool), 'status' (int), 'data' (parsed JSON or text)

        Raises:
            URLError: On network errors
        """
        # Build URL with query parameters
        url = urljoin(self.base_url, endpoint)
        if params:
            from urllib.parse import urlencode
            url = f"{url}?{urlencode(params)}"

        self.logger.debug(f"{method} {url}")

        # Prepare request body
        body = json.dumps(data).encode('utf-8') if data else None

        # Create request
        request = Request(url, data=body, headers=self.headers, method=method)

        try:
            with urlopen(request, context=self.ssl_context, timeout=30) as response:
                response_data = response.read().decode('utf-8')
                try:
                    parsed_data = json.loads(response_data) if response_data else {}
                except json.JSONDecodeError:
                    parsed_data = response_data

                return {
                    'ok': True,
                    'status': response.status,
                    'data': parsed_data
                }

        except HTTPError as e:
            error_body = e.read().decode('utf-8') if e.fp else ''
            self.logger.error(
                f"API request failed: {method} {endpoint} "
                f"(HTTP {e.code}): {error_body}"
            )
            return {
                'ok': False,
                'status': e.code,
                'data': error_body
            }
        except URLError as e:
            self.logger.error(f"Network error: {method} {endpoint}: {e.reason}")
            return {
                'ok': False,
                'status': 0,
                'data': str(e.reason)
            }

    def get_user_repos(self, username: str) -> List[Dict]:
        """
        Fetch all repositories for a user with pagination.

        Args:
            username: Gitea username

        Returns:
            List of repository objects
        """
        repos = []
        page = 1

        while True:
            self.logger.info(f"Fetching repositories (page {page})...")
            response = self._make_request(
                'GET',
                f'/api/v1/users/{username}/repos',
                params={'page': page, 'limit': 50}
            )

            if not response['ok']:
                self.logger.error(f"Failed to fetch repositories page {page}")
                break

            page_repos = response['data']
            if not page_repos or not isinstance(page_repos, list):
                break

            repos.extend(page_repos)
            self.logger.debug(f"Found {len(page_repos)} repositories on page {page}")
            page += 1

        self.logger.info(f"Total repositories found: {len(repos)}")
        return repos

    def get_push_mirrors(self, owner: str, repo_name: str) -> List[Dict]:
        """
        Get all push mirrors for a repository.

        Args:
            owner: Repository owner username
            repo_name: Repository name

        Returns:
            List of push mirror objects
        """
        response = self._make_request(
            'GET',
            f'/api/v1/repos/{owner}/{repo_name}/push_mirrors'
        )

        if not response['ok']:
            return []

        data = response['data']

        # Debug: log what we received
        if data and not isinstance(data, list):
            self.logger.debug(f"Unexpected push_mirrors response type: {type(data)}")
            self.logger.debug(f"Response data: {data}")

        return data if isinstance(data, list) else []

    def update_push_mirror(
        self,
        owner: str,
        repo_name: str,
        mirror_info: dict,
        new_password: str,
        github_username: str = "jwiegley"
    ) -> bool:
        """
        Update the password for a push mirror by deleting and recreating it.

        Gitea 1.25.0 doesn't support PATCH for push mirrors, so we must
        delete and recreate the mirror with new credentials.

        Args:
            owner: Repository owner username
            repo_name: Repository name
            mirror_info: Full mirror object from GET /push_mirrors (contains all settings)
            new_password: New GitHub token
            github_username: GitHub username for authentication

        Returns:
            True if successful, False otherwise
        """
        mirror_name = mirror_info.get('remote_name')
        remote_address = mirror_info.get('remote_address', '')
        interval = mirror_info.get('interval', '8h0m0s')
        sync_on_commit = mirror_info.get('sync_on_commit', False)

        if self.dry_run:
            self.logger.info(
                f"[DRY RUN] Would delete and recreate push mirror {mirror_name} "
                f"for {owner}/{repo_name}"
            )
            return True

        # Step 1: Delete the existing push mirror
        self.logger.debug(f"  Deleting existing push mirror {mirror_name}...")
        delete_response = self._make_request(
            'DELETE',
            f'/api/v1/repos/{owner}/{repo_name}/push_mirrors/{mirror_name}'
        )

        if not delete_response['ok']:
            self.logger.error(f"  Failed to delete push mirror: {delete_response.get('error')}")
            return False

        # Step 2: Recreate with new credentials
        self.logger.debug(f"  Creating push mirror with new credentials...")
        payload = {
            'remote_address': remote_address,
            'remote_username': github_username,
            'remote_password': new_password,
            'interval': interval,
            'sync_on_commit': sync_on_commit
        }

        create_response = self._make_request(
            'POST',
            f'/api/v1/repos/{owner}/{repo_name}/push_mirrors',
            data=payload
        )

        if not create_response['ok']:
            self.logger.error(f"  Failed to recreate push mirror: {create_response.get('error')}")
            return False

        return True

    def update_pull_mirror(
        self,
        owner: str,
        repo_name: str,
        new_password: str
    ) -> bool:
        """
        Update the authentication for a pull mirror.

        For pull mirrors, we need to update the repository's mirror settings
        by patching the repository itself.

        Args:
            owner: Repository owner username
            repo_name: Repository name
            new_password: New GitHub token

        Returns:
            True if successful, False otherwise
        """
        if self.dry_run:
            self.logger.info(
                f"[DRY RUN] Would update pull mirror credentials "
                f"for {owner}/{repo_name}"
            )
            return True

        # Get current repo details to preserve settings
        response = self._make_request(
            'GET',
            f'/api/v1/repos/{owner}/{repo_name}'
        )

        if not response['ok']:
            self.logger.error(f"Failed to fetch repo details for {owner}/{repo_name}")
            return False

        repo_data = response['data']

        # Update mirror authentication
        payload = {
            'mirror_password': new_password
        }

        response = self._make_request(
            'PATCH',
            f'/api/v1/repos/{owner}/{repo_name}',
            data=payload
        )

        return response['ok']


def load_gitea_token(token_path: Path) -> str:
    """
    Load Gitea token from SOPS secrets.

    Args:
        token_path: Path to the secret file

    Returns:
        Token string

    Raises:
        FileNotFoundError: If token file doesn't exist
        PermissionError: If unable to read token file
        ValueError: If token is empty
    """
    try:
        token = token_path.read_text().strip()
        if not token:
            raise ValueError("Token file is empty")
        return token
    except PermissionError:
        raise PermissionError(
            f"Permission denied reading {token_path}. "
            "This script must be run as root or with appropriate permissions."
        )


def update_all_mirrors(
    client: GiteaAPIClient,
    github_token: str,
    gitea_user: str,
    github_user: str,
    repo_filter: Optional[str] = None
) -> UpdateStats:
    """
    Update GitHub tokens for all push and pull mirrors.

    Args:
        client: Initialized GiteaAPIClient
        github_token: New GitHub token to use
        gitea_user: Gitea username
        github_user: GitHub username
        repo_filter: If provided, only process this specific repository

    Returns:
        UpdateStats object with operation statistics
    """
    logger = logging.getLogger(__name__)
    stats = UpdateStats()

    # Get all repositories
    repos = client.get_user_repos(gitea_user)

    for repo in repos:
        repo_name = repo['name']
        is_mirror = repo.get('mirror', False)

        # If repo filter is set, skip repos that don't match
        if repo_filter and repo_name != repo_filter:
            continue

        stats.total_repos += 1

        # Skip the "org" repository (not a GitHub mirror)
        if repo_name == 'org':
            logger.info(f"→ Skipping: {repo_name} (not a GitHub mirror)")
            stats.skipped_repos += 1
            continue

        logger.info(f"Processing: {repo_name}")

        # Check for push mirrors on ALL repositories (not just mirrors)
        # Regular repos like nixos-config may have push mirrors to GitHub
        push_mirrors = client.get_push_mirrors(gitea_user, repo_name)

        if push_mirrors:
            logger.debug(f"  Found {len(push_mirrors)} push mirror(s)")
            for mirror in push_mirrors:
                # Validate mirror structure
                if not isinstance(mirror, dict):
                    logger.warning(f"  → Skipping invalid push mirror (not a dict): {mirror}")
                    continue

                # Use remote_name as the identifier (Gitea's API uses this)
                mirror_name = mirror.get('remote_name')
                if not mirror_name:
                    logger.warning(f"  → Skipping push mirror without remote_name: {mirror}")
                    continue

                remote_addr = mirror.get('remote_address', '')

                # Only update GitHub push mirrors
                if github_user not in remote_addr and 'github.com' not in remote_addr:
                    logger.debug(
                        f"  → Skipping push mirror {mirror_name} "
                        f"(not a GitHub mirror: {remote_addr})"
                    )
                    continue

                logger.info(f"  → Updating push mirror: {repo_name}")
                success = client.update_push_mirror(
                    gitea_user,
                    repo_name,
                    mirror,  # Pass full mirror object
                    github_token,
                    github_user
                )

                if success:
                    logger.info(f"  ✓ Updated push mirror")
                    stats.push_mirrors_updated += 1
                else:
                    logger.error(f"  ✗ Failed to update push mirror")
                    stats.push_mirrors_failed += 1
        else:
            logger.debug(f"  → No push mirrors found for {repo_name}")

        # Update pull mirror credentials (only for actual mirrors)
        if is_mirror:
            logger.info(f"  → Updating pull mirror credentials...")
            success = client.update_pull_mirror(gitea_user, repo_name, github_token)

            if success:
                logger.info(f"  ✓ Updated pull mirror credentials")
                stats.pull_mirrors_updated += 1
            else:
                logger.error(f"  ✗ Failed to update pull mirror credentials")
                stats.pull_mirrors_failed += 1
        else:
            logger.debug(f"  → Not a pull mirror, skipping pull mirror credential update")

    return stats


def setup_logging(verbose: bool) -> None:
    """
    Configure logging based on verbosity level.

    Args:
        verbose: If True, enable DEBUG logging
    """
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format='%(message)s',
        handlers=[logging.StreamHandler(sys.stdout)]
    )


def parse_args() -> argparse.Namespace:
    """
    Parse command-line arguments.

    Returns:
        Parsed arguments namespace
    """
    parser = argparse.ArgumentParser(
        description='Bulk update GitHub tokens for all Gitea push and pull mirrors',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Test what would be updated without making changes
  %(prog)s ghp_newtoken123 --dry-run

  # Update all mirrors with new token
  sudo %(prog)s ghp_newtoken123 --verbose

  # Read token from stdin for security
  echo "ghp_newtoken123" | sudo %(prog)s --stdin --verbose

Configuration:
  Gitea URL:    {gitea_url}
  Gitea user:   {gitea_user}
  GitHub user:  {github_user}
  Token source: {token_path}
        """.format(
            gitea_url=GITEA_URL,
            gitea_user=GITEA_USER,
            github_user=GITHUB_USER,
            token_path=GITEA_TOKEN_PATH
        )
    )

    token_group = parser.add_mutually_exclusive_group(required=True)
    token_group.add_argument(
        'github_token',
        nargs='?',
        help='New GitHub token (use --stdin to read from stdin instead)'
    )
    token_group.add_argument(
        '--stdin',
        action='store_true',
        help='Read GitHub token from stdin (more secure)'
    )

    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be updated without making changes'
    )

    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Enable verbose output with DEBUG logging'
    )

    parser.add_argument(
        '--repo',
        metavar='NAME',
        help='Only update a specific repository (useful for testing)'
    )

    args = parser.parse_args()

    # Validate token input
    if args.stdin:
        args.github_token = sys.stdin.read().strip()
        if not args.github_token:
            parser.error("No token provided via stdin")
    elif not args.github_token:
        parser.error("GitHub token is required (use positional argument or --stdin)")

    return args


def main() -> int:
    """
    Main entry point.

    Returns:
        Exit code (0 for success, 1 for failure)
    """
    args = parse_args()
    setup_logging(args.verbose)
    logger = logging.getLogger(__name__)

    # Print header
    print("=========================================")
    print("GitHub Token Update for Gitea Mirrors")
    print("=========================================")
    print(f"Gitea user:   {GITEA_USER}")
    print(f"GitHub user:  {GITHUB_USER}")
    print(f"Gitea URL:    {GITEA_URL}")
    if args.dry_run:
        print("\n*** DRY RUN MODE - No changes will be made ***")
    print()

    try:
        # Load Gitea token
        gitea_token = load_gitea_token(Path(GITEA_TOKEN_PATH))
        logger.debug("Successfully loaded Gitea token")

        # Initialize API client
        client = GiteaAPIClient(GITEA_URL, gitea_token, dry_run=args.dry_run)

        # Update all mirrors (or just one if --repo specified)
        if args.repo:
            logger.info(f"Filtering to repository: {args.repo}\n")

        stats = update_all_mirrors(
            client, args.github_token, GITEA_USER, GITHUB_USER, args.repo
        )

        # Print summary
        print(stats.summary())

        # Exit with error if any failures occurred
        if stats.push_mirrors_failed > 0 or stats.pull_mirrors_failed > 0:
            logger.error("Some mirrors failed to update")
            return 1

        logger.info("All mirrors updated successfully!")
        return 0

    except FileNotFoundError as e:
        logger.error(f"ERROR: {e}")
        logger.error(f"Gitea token not found at {GITEA_TOKEN_PATH}")
        return 1
    except PermissionError as e:
        logger.error(f"ERROR: {e}")
        return 1
    except ValueError as e:
        logger.error(f"ERROR: {e}")
        return 1
    except KeyboardInterrupt:
        logger.warning("\nOperation cancelled by user")
        return 130
    except Exception as e:
        logger.exception(f"Unexpected error: {e}")
        return 1


if __name__ == '__main__':
    sys.exit(main())
