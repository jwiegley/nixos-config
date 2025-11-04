#!/usr/bin/env python3
"""
VCF Validator and Fixer
Ensures all vCard entries have required FN (Formatted Name) field

Usage:
    ./vcf_fixer.py input.vcf [output.vcf] [--dry-run] [--verbose]

RFC 6350: Every vCard MUST contain exactly one FN (Formatted Name) property.
This script automatically generates missing FN fields from available data.
"""

import sys
import re
import argparse
from typing import List, Tuple, Optional
from pathlib import Path


class VCardFixer:
    """Fixes vCard entries missing required FN (Formatted Name) field"""

    def __init__(self, input_file: str, output_file: Optional[str] = None,
                 dry_run: bool = False, verbose: bool = False):
        self.input_file = Path(input_file)
        self.output_file = Path(output_file) if output_file else self.input_file.with_stem(f"{self.input_file.stem}_fixed")
        self.dry_run = dry_run
        self.verbose = verbose

        # Statistics
        self.stats = {
            'total': 0,
            'valid': 0,
            'fixed': 0,
            'unfixable': 0,
            'errors': 0
        }
        self.fixed_details = []

    def log(self, message: str, level: str = 'INFO'):
        """Print log message if verbose mode enabled"""
        if self.verbose or level == 'ERROR':
            prefix = f"[{level}]"
            print(f"{prefix} {message}")

    def unfold_lines(self, text: str) -> str:
        """
        Unfold vCard lines according to RFC 6350
        Long lines are folded by inserting CRLF followed by space or tab
        """
        # Replace CRLF + space/tab with nothing (unfold)
        text = re.sub(r'\r?\n[ \t]', '', text)
        return text

    def parse_vcf(self, content: str) -> List[str]:
        """Split VCF file into individual vCard entries"""
        # Split on BEGIN:VCARD, keeping the delimiter
        vcards = re.split(r'(BEGIN:VCARD)', content, flags=re.IGNORECASE)

        # Reconstruct vCards
        result = []
        for i in range(1, len(vcards), 2):
            if i + 1 < len(vcards):
                vcard = vcards[i] + vcards[i + 1]
                if 'END:VCARD' in vcard.upper():
                    result.append(vcard)

        return result

    def extract_field(self, vcard: str, field_name: str) -> Optional[str]:
        """
        Extract value of a specific field from vCard
        Handles both simple fields (FN:value) and parameterized fields (FN;CHARSET=UTF-8:value)
        """
        # Unfold the vcard first for easier parsing
        unfolded = self.unfold_lines(vcard)

        # Match field name with optional parameters, then colon and value
        pattern = rf'^{field_name}(?:[;:].*?):(.*)$'
        match = re.search(pattern, unfolded, re.MULTILINE | re.IGNORECASE)

        if match:
            value = match.group(1).strip()
            # Unescape vCard escaped characters
            value = value.replace('\\n', '\n').replace('\\,', ',').replace('\\;', ';')
            return value
        return None

    def has_fn_field(self, vcard: str) -> bool:
        """Check if vCard has FN field"""
        unfolded = self.unfold_lines(vcard)
        return bool(re.search(r'^FN[;:]', unfolded, re.MULTILINE | re.IGNORECASE))

    def generate_fn_from_n(self, n_value: str) -> Optional[str]:
        """
        Generate FN from N field
        N format: LastName;FirstName;MiddleName;Prefix;Suffix
        Returns formatted name like "Prefix FirstName MiddleName LastName Suffix"
        """
        if not n_value:
            return None

        # Split N field into components
        parts = n_value.split(';')

        # Pad with empty strings if needed
        while len(parts) < 5:
            parts.append('')

        last_name = parts[0].strip()
        first_name = parts[1].strip()
        middle_name = parts[2].strip()
        prefix = parts[3].strip()
        suffix = parts[4].strip()

        # Build formatted name
        name_parts = []

        if prefix:
            name_parts.append(prefix)
        if first_name:
            name_parts.append(first_name)
        if middle_name:
            name_parts.append(middle_name)
        if last_name:
            name_parts.append(last_name)
        if suffix:
            name_parts.append(suffix)

        if name_parts:
            return ' '.join(name_parts)

        return None

    def generate_fn_fallback(self, vcard: str) -> Optional[str]:
        """
        Generate FN from alternative fields when N is missing or empty
        Priority: NICKNAME > EMAIL > ORG
        """
        # Try NICKNAME
        nickname = self.extract_field(vcard, 'NICKNAME')
        if nickname and nickname.strip():
            return nickname.strip()

        # Try EMAIL (use part before @)
        email = self.extract_field(vcard, 'EMAIL')
        if email and email.strip():
            email_name = email.split('@')[0]
            # Convert dots/underscores to spaces, capitalize
            email_name = email_name.replace('.', ' ').replace('_', ' ')
            email_name = ' '.join(word.capitalize() for word in email_name.split())
            if email_name:
                return email_name

        # Try ORG (organization)
        org = self.extract_field(vcard, 'ORG')
        if org and org.strip():
            # ORG can have semicolons for hierarchy, take first part
            return org.split(';')[0].strip()

        # Try TEL (just use "Contact" + phone number)
        tel = self.extract_field(vcard, 'TEL')
        if tel and tel.strip():
            return f"Contact {tel.strip()}"

        return None

    def add_fn_field(self, vcard: str, fn_value: str) -> str:
        """
        Add FN field to vCard
        Insert after VERSION field or at the beginning after BEGIN:VCARD
        """
        lines = vcard.split('\n')
        insert_index = 1  # Default: after BEGIN:VCARD

        # Find best position to insert (after VERSION or N field)
        for i, line in enumerate(lines):
            if re.match(r'^VERSION[;:]', line, re.IGNORECASE):
                insert_index = i + 1
                break
            elif re.match(r'^N[;:]', line, re.IGNORECASE):
                insert_index = i + 1

        # Create FN line (escape special characters)
        fn_value_escaped = fn_value.replace('\n', '\\n').replace(',', '\\,').replace(';', '\\;')
        fn_line = f"FN:{fn_value_escaped}"

        # Insert FN field
        lines.insert(insert_index, fn_line)

        return '\n'.join(lines)

    def process_vcard(self, vcard: str, index: int) -> Tuple[str, bool]:
        """
        Process a single vCard entry
        Returns: (processed_vcard, was_modified)
        """
        self.stats['total'] += 1

        try:
            # Check if FN already exists
            if self.has_fn_field(vcard):
                self.log(f"vCard #{index}: Already has FN field, skipping", 'DEBUG')
                self.stats['valid'] += 1
                return vcard, False

            # Try to generate FN from N field
            n_value = self.extract_field(vcard, 'N')
            fn_value = None
            source = None

            if n_value:
                fn_value = self.generate_fn_from_n(n_value)
                source = "N field"

            # If N didn't work, try fallback methods
            if not fn_value:
                fn_value = self.generate_fn_fallback(vcard)
                if fn_value:
                    source = "fallback fields"

            # If still no FN, mark as unfixable
            if not fn_value:
                self.log(f"vCard #{index}: Cannot generate FN - no usable data found", 'ERROR')
                self.stats['unfixable'] += 1
                # Use a generic placeholder
                fn_value = f"Unknown Contact {index}"
                source = "placeholder"

            # Add FN field
            modified_vcard = self.add_fn_field(vcard, fn_value)
            self.stats['fixed'] += 1
            self.fixed_details.append(f"  #{index}: Added FN='{fn_value}' (from {source})")
            self.log(f"vCard #{index}: Added FN='{fn_value}' (from {source})")

            return modified_vcard, True

        except Exception as e:
            self.log(f"vCard #{index}: Error processing - {e}", 'ERROR')
            self.stats['errors'] += 1
            return vcard, False

    def process_file(self) -> bool:
        """
        Process entire VCF file
        Returns True if successful
        """
        try:
            # Read input file
            self.log(f"Reading input file: {self.input_file}")
            with open(self.input_file, 'r', encoding='utf-8') as f:
                content = f.read()

            # Parse into individual vCards
            vcards = self.parse_vcf(content)
            self.log(f"Found {len(vcards)} vCard entries")

            if not vcards:
                self.log("No vCards found in file", 'ERROR')
                return False

            # Process each vCard
            processed_vcards = []
            for i, vcard in enumerate(vcards, 1):
                processed_vcard, modified = self.process_vcard(vcard, i)
                processed_vcards.append(processed_vcard)

            # Write output file (unless dry-run)
            if not self.dry_run:
                self.log(f"Writing output file: {self.output_file}")
                output_content = '\n'.join(processed_vcards)

                # Ensure file ends with newline
                if not output_content.endswith('\n'):
                    output_content += '\n'

                with open(self.output_file, 'w', encoding='utf-8') as f:
                    f.write(output_content)
            else:
                self.log("DRY RUN - No files written")

            return True

        except FileNotFoundError:
            self.log(f"Input file not found: {self.input_file}", 'ERROR')
            return False
        except Exception as e:
            self.log(f"Error processing file: {e}", 'ERROR')
            return False

    def generate_report(self):
        """Print summary report"""
        print("\n" + "=" * 60)
        print("VCF FIXER REPORT")
        print("=" * 60)
        print(f"Input file:  {self.input_file}")
        print(f"Output file: {self.output_file}")
        print()
        print(f"Total vCards:        {self.stats['total']}")
        print(f"Already valid:       {self.stats['valid']}")
        print(f"Fixed (FN added):    {self.stats['fixed']}")
        print(f"Unfixable:           {self.stats['unfixable']}")
        print(f"Errors:              {self.stats['errors']}")
        print()

        if self.fixed_details and self.verbose:
            print("Fixed vCards:")
            for detail in self.fixed_details[:20]:  # Show first 20
                print(detail)
            if len(self.fixed_details) > 20:
                print(f"  ... and {len(self.fixed_details) - 20} more")
            print()

        if self.dry_run:
            print("DRY RUN MODE - No files were modified")
        else:
            print(f"✓ Fixed VCF saved to: {self.output_file}")
        print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description='Fix vCard entries missing required FN (Formatted Name) field',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s contacts.vcf                    # Fix and save to contacts_fixed.vcf
  %(prog)s contacts.vcf fixed.vcf          # Fix and save to fixed.vcf
  %(prog)s contacts.vcf --dry-run          # Preview changes without writing
  %(prog)s contacts.vcf --verbose          # Show detailed processing log
        """
    )

    parser.add_argument('input_file', help='Input VCF file to fix')
    parser.add_argument('output_file', nargs='?', help='Output VCF file (default: input_fixed.vcf)')
    parser.add_argument('--dry-run', action='store_true', help='Preview changes without writing output')
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose logging')

    args = parser.parse_args()

    # Create fixer instance
    fixer = VCardFixer(
        args.input_file,
        args.output_file,
        dry_run=args.dry_run,
        verbose=args.verbose
    )

    # Process file
    success = fixer.process_file()

    # Generate report
    fixer.generate_report()

    # Exit with appropriate code
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
