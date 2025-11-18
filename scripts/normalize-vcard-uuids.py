#!/usr/bin/env python3
"""
Normalize vCard files by ensuring filenames and UID fields use proper UUID format.

This script scans vCard files in the Radicale contacts directory and normalizes
any files that don't follow the UUID naming convention by:
1. Generating a new UUID v4 for the file
2. Renaming the file to match the UUID pattern
3. Updating the UID field within the vCard content

Author: Generated for NixOS system management
License: MIT
"""

import argparse
import re
import sys
import uuid
from pathlib import Path
from typing import List, Tuple, Optional


# UUID pattern for filenames: 8-4-4-4-12 hexadecimal format
UUID_PATTERN = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.vcf$',
    re.IGNORECASE
)

# Pattern to match UID line in vCard
UID_LINE_PATTERN = re.compile(r'^UID:(.+)$', re.MULTILINE)

# Pattern to match FN (formatted name) line in vCard
# Handles both simple FN: and parameterized FN;CHARSET=...:
FN_LINE_PATTERN = re.compile(r'^FN(?:;[^:]*)?:(.+)$', re.MULTILINE)


class VCardNormalizer:
    """Handles normalization of vCard files with UUID-based naming."""

    def __init__(
        self,
        directory: Path,
        dry_run: bool = False,
        verbose: bool = False
    ) -> None:
        """
        Initialize the vCard normalizer.

        Args:
            directory: Path to the directory containing vCard files
            dry_run: If True, only show what would be done without making changes
            verbose: If True, show detailed progress information
        """
        self.directory = directory
        self.dry_run = dry_run
        self.verbose = verbose
        self.stats = {
            'total_files': 0,
            'renamed': 0,
            'skipped': 0,
            'errors': 0
        }

    def log(self, message: str, force: bool = False) -> None:
        """
        Print a log message.

        Args:
            message: The message to print
            force: If True, print even if not in verbose mode
        """
        if self.verbose or force:
            prefix = "[DRY RUN] " if self.dry_run else ""
            print(f"{prefix}{message}")

    def is_uuid_filename(self, filename: str) -> bool:
        """
        Check if filename matches UUID pattern.

        Args:
            filename: The filename to check

        Returns:
            True if filename matches UUID pattern, False otherwise
        """
        return bool(UUID_PATTERN.match(filename))

    def generate_unique_uuid(self, existing_files: set[str]) -> str:
        """
        Generate a UUID that doesn't collide with existing files.

        Args:
            existing_files: Set of existing filenames (without extension)

        Returns:
            A unique UUID string in lowercase
        """
        max_attempts = 100
        for _ in range(max_attempts):
            new_uuid = str(uuid.uuid4())
            if new_uuid not in existing_files:
                return new_uuid

        raise RuntimeError(
            f"Failed to generate unique UUID after {max_attempts} attempts"
        )

    def read_vcard_content(self, file_path: Path) -> Optional[str]:
        """
        Read vCard file content.

        Args:
            file_path: Path to the vCard file

        Returns:
            File content as string, or None if read fails
        """
        try:
            return file_path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            # Try with latin-1 as fallback
            try:
                return file_path.read_text(encoding='latin-1')
            except Exception as e:
                self.log(f"Error reading {file_path.name}: {e}", force=True)
                return None
        except Exception as e:
            self.log(f"Error reading {file_path.name}: {e}", force=True)
            return None

    def extract_formatted_name(self, content: str) -> str:
        """
        Extract the FN (formatted name) field from vCard content.

        Handles multi-line values (line folding) and various encodings.
        vCard 3.0 spec allows continuation lines that start with space or tab.

        Args:
            content: The vCard content

        Returns:
            The formatted name, or "Unknown Contact" if not found
        """
        # First, unfold any folded lines (lines continuing with space/tab)
        # This handles cases like:
        # FN:John
        #  Doe
        unfolded = re.sub(r'\r?\n[ \t]', '', content)

        # Now search for FN field
        match = FN_LINE_PATTERN.search(unfolded)
        if not match:
            return "Unknown Contact"

        # Extract the name value
        name = match.group(1).strip()

        # Handle empty FN field
        if not name:
            return "Unknown Contact"

        return name

    def update_uid_in_content(
        self,
        content: str,
        new_uuid: str
    ) -> Tuple[str, bool]:
        """
        Update the UID field in vCard content.

        Args:
            content: The vCard content
            new_uuid: The new UUID to use

        Returns:
            Tuple of (updated_content, uid_found)
        """
        match = UID_LINE_PATTERN.search(content)
        if not match:
            return content, False

        new_uid_line = f"UID:{new_uuid}"
        updated_content = UID_LINE_PATTERN.sub(new_uid_line, content, count=1)

        return updated_content, True

    def normalize_file(
        self,
        file_path: Path,
        existing_uuids: set[str]
    ) -> bool:
        """
        Normalize a single vCard file.

        Args:
            file_path: Path to the file to normalize
            existing_uuids: Set of existing UUID filenames (without extension)

        Returns:
            True if file was successfully normalized, False otherwise
        """
        old_name = file_path.name

        # Read file content
        content = self.read_vcard_content(file_path)
        if content is None:
            self.stats['errors'] += 1
            return False

        # Extract contact name for verbose output
        contact_name = None
        if self.verbose:
            contact_name = self.extract_formatted_name(content)

        # Generate new UUID
        try:
            new_uuid = self.generate_unique_uuid(existing_uuids)
        except RuntimeError as e:
            self.log(f"Error: {e}", force=True)
            self.stats['errors'] += 1
            return False

        # Update UID in content
        updated_content, uid_found = self.update_uid_in_content(
            content,
            new_uuid
        )

        if not uid_found:
            self.log(
                f"Warning: No UID field found in {old_name}, "
                "proceeding with rename only",
                force=True
            )

        # Prepare new filename
        new_name = f"{new_uuid}.vcf"
        new_path = file_path.parent / new_name

        # Show what we're doing
        if self.verbose and contact_name:
            # Verbose mode: single line with contact name
            prefix = "[DRY RUN] " if self.dry_run else ""
            print(f"{prefix}Renaming: {old_name} → {new_name} (FN: {contact_name})")
        else:
            # Normal mode: simple arrow notation
            self.log(f"{old_name} → {new_name}", force=True)

        # Perform operations (unless dry run)
        if not self.dry_run:
            try:
                # Write updated content to new file
                new_path.write_text(updated_content, encoding='utf-8')

                # Copy permissions and ownership from original
                stat_info = file_path.stat()
                new_path.chmod(stat_info.st_mode)

                # Remove old file
                file_path.unlink()

                self.stats['renamed'] += 1
                existing_uuids.add(new_uuid)
                return True

            except PermissionError:
                self.log(
                    f"Error: Permission denied when processing {old_name}. "
                    "Try running with sudo.",
                    force=True
                )
                # Clean up new file if it was created
                if new_path.exists():
                    try:
                        new_path.unlink()
                    except Exception:
                        pass
                self.stats['errors'] += 1
                return False

            except Exception as e:
                self.log(f"Error processing {old_name}: {e}", force=True)
                # Clean up new file if it was created
                if new_path.exists():
                    try:
                        new_path.unlink()
                    except Exception:
                        pass
                self.stats['errors'] += 1
                return False
        else:
            # Dry run - just update stats
            self.stats['renamed'] += 1
            return True

    def process_directory(self) -> int:
        """
        Process all vCard files in the directory.

        Returns:
            Exit code (0 for success, 1 for errors)
        """
        # Validate directory
        if not self.directory.exists():
            print(f"Error: Directory does not exist: {self.directory}", file=sys.stderr)
            return 1

        if not self.directory.is_dir():
            print(f"Error: Not a directory: {self.directory}", file=sys.stderr)
            return 1

        # Get all .vcf files
        vcf_files = list(self.directory.glob('*.vcf'))
        self.stats['total_files'] = len(vcf_files)

        if self.stats['total_files'] == 0:
            print(f"No .vcf files found in {self.directory}")
            return 0

        self.log(f"Found {self.stats['total_files']} vCard files", force=True)
        self.log("", force=True)

        # Build set of existing UUID filenames
        existing_uuids = {
            f.stem for f in vcf_files if self.is_uuid_filename(f.name)
        }

        # Process files that need normalization
        files_to_normalize = [
            f for f in vcf_files if not self.is_uuid_filename(f.name)
        ]

        if not files_to_normalize:
            print("All files already have UUID-formatted names. Nothing to do.")
            return 0

        self.log(
            f"Processing {len(files_to_normalize)} files that need normalization:",
            force=True
        )
        self.log("", force=True)

        # Normalize each file
        for file_path in files_to_normalize:
            self.normalize_file(file_path, existing_uuids)

        # Print summary
        self.print_summary()

        return 0 if self.stats['errors'] == 0 else 1

    def print_summary(self) -> None:
        """Print summary statistics."""
        print()
        print("=" * 60)
        print("SUMMARY")
        print("=" * 60)
        print(f"Total files found:    {self.stats['total_files']}")
        print(f"Files renamed:        {self.stats['renamed']}")
        print(f"Files skipped:        {self.stats['skipped']}")
        print(f"Errors:               {self.stats['errors']}")

        if self.dry_run:
            print()
            print("This was a dry run. No changes were made.")
            print("Run without --dry-run to apply these changes.")


def parse_arguments() -> argparse.Namespace:
    """
    Parse command-line arguments.

    Returns:
        Parsed arguments namespace
    """
    parser = argparse.ArgumentParser(
        description='Normalize vCard files to use UUID-based filenames and UID fields.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry run to see what would be changed
  sudo %(prog)s --dry-run

  # Actually perform the normalization
  sudo %(prog)s

  # Verbose output with dry run
  sudo %(prog)s -v --dry-run

  # Process a different directory
  sudo %(prog)s -d /path/to/contacts
        """
    )

    parser.add_argument(
        '-d', '--directory',
        type=Path,
        default=Path('/var/lib/radicale/collections/collection-root/johnw/contacts'),
        help='Directory containing vCard files (default: %(default)s)'
    )

    parser.add_argument(
        '-n', '--dry-run',
        action='store_true',
        help='Show what would be done without making changes'
    )

    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Show detailed progress information'
    )

    return parser.parse_args()


def main() -> int:
    """
    Main entry point.

    Returns:
        Exit code
    """
    args = parse_arguments()

    normalizer = VCardNormalizer(
        directory=args.directory,
        dry_run=args.dry_run,
        verbose=args.verbose
    )

    return normalizer.process_directory()


if __name__ == '__main__':
    sys.exit(main())
