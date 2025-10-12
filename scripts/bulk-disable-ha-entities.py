#!/usr/bin/env python3
"""
Bulk disable Home Assistant entities matching specific patterns.
Disables Enphase individual inverter sensors and Dreame vacuum room entities.

Usage:
    nix-shell -p python3Packages.websockets --run bash
    export HASS_TOKEN="your_long_lived_access_token"
    python3 bulk-disable-ha-entities.py "$HASS_TOKEN" [--dry-run]
"""

import asyncio
import json
import os
import sys
import re

try:
    import websockets
except ImportError:
    print("Error: websockets library not found")
    print("Install with: pip install websockets")
    sys.exit(1)


# Home Assistant WebSocket URL
HA_URL = "ws://127.0.0.1:8123/api/websocket"

# Entity patterns to disable (regex patterns)
PATTERNS_TO_DISABLE = [
    r"^sensor\.inverter_",           # Enphase individual inverter sensors
    r"^select\..*_room_",            # Dreame vacuum room select entities
    r"^switch\..*_room_",            # Dreame vacuum room switches
]


async def authenticate(websocket, token: str) -> bool:
    """Authenticate with Home Assistant WebSocket API."""
    # Receive auth_required message
    msg = await websocket.recv()
    print(f"Connected: {json.loads(msg)['type']}")

    # Send auth message
    await websocket.send(json.dumps({
        "type": "auth",
        "access_token": token
    }))

    # Receive auth result
    msg = await websocket.recv()
    auth_result = json.loads(msg)
    if auth_result["type"] != "auth_ok":
        print(f"Authentication failed: {auth_result}")
        return False
    print("Authenticated successfully")
    return True


async def fetch_entity_registry(websocket):
    """Fetch the entity registry from Home Assistant."""
    # Request entity registry list
    await websocket.send(json.dumps({
        "id": 1,
        "type": "config/entity_registry/list"
    }))

    # Receive entity list
    msg = await websocket.recv()
    response = json.loads(msg)

    if not response.get("success"):
        print(f"Failed to get entity list: {response}")
        return None

    return response["result"]


def filter_entities_to_disable(entities):
    """Filter entities that match patterns and are not already disabled."""
    entities_to_disable = []
    for entity in entities:
        entity_id = entity["entity_id"]
        disabled_by = entity.get("disabled_by")

        # Check if entity matches any pattern
        for pattern in PATTERNS_TO_DISABLE:
            if re.match(pattern, entity_id):
                # Only process if not already disabled
                if not disabled_by:
                    entities_to_disable.append(entity)
                break

    return entities_to_disable


def group_entities_by_pattern(entities_to_disable):
    """Group entities by their matching pattern for display."""
    by_pattern = {}
    for entity in entities_to_disable:
        entity_id = entity["entity_id"]
        for pattern in PATTERNS_TO_DISABLE:
            if re.match(pattern, entity_id):
                if pattern not in by_pattern:
                    by_pattern[pattern] = []
                by_pattern[pattern].append(entity_id)
                break
    return by_pattern


def display_entities_summary(entities_to_disable):
    """Display summary of entities to be disabled."""
    print(f"\nFound {len(entities_to_disable)} entities to disable:")
    print("-" * 80)

    by_pattern = group_entities_by_pattern(entities_to_disable)
    for pattern, entity_ids in by_pattern.items():
        print(f"\nPattern: {pattern}")
        print(f"  Count: {len(entity_ids)}")
        print(f"  Examples: {', '.join(entity_ids)}")


async def perform_entity_disable(websocket, entities_to_disable):
    """Disable each entity via WebSocket API."""
    print("\nDisabling entities...")
    msg_id = 2
    disabled_count = 0

    for entity in entities_to_disable:
        entity_id = entity["entity_id"]

        # Send disable command
        await websocket.send(json.dumps({
            "id": msg_id,
            "type": "config/entity_registry/update",
            "entity_id": entity_id,
            "disabled_by": "user"
        }))

        # Wait for response
        msg = await websocket.recv()
        result = json.loads(msg)

        if result.get("success"):
            disabled_count += 1
            if disabled_count % 10 == 0:
                print(f"  Disabled {disabled_count}/{len(entities_to_disable)}...")
        else:
            print(f"  Failed to disable {entity_id}: {result}")

        msg_id += 1

    print(f"\nSuccessfully disabled {disabled_count} entities!")
    print("\nNote: You may need to reload integrations or restart Home Assistant")
    print("for all changes to take effect.")


async def disable_entities(token: str, dry_run: bool = False):
    """Connect to Home Assistant and disable matching entities."""
    async with websockets.connect(HA_URL) as websocket:
        # Step 1-3: Authenticate
        if not await authenticate(websocket, token):
            return

        # Step 4-5: Fetch entity registry
        entities = await fetch_entity_registry(websocket)
        if entities is None:
            return

        print(f"Total entities in registry: {len(entities)}")

        # Step 6: Filter entities matching our patterns
        entities_to_disable = filter_entities_to_disable(entities)

        # Display summary
        display_entities_summary(entities_to_disable)

        if dry_run:
            print("\n[DRY RUN] No entities were actually disabled.")
            return

        # Step 7: Confirm before proceeding
        print("\n" + "=" * 80)
        user_response = input(f"Disable {len(entities_to_disable)} entities? [y/N]: ")
        if user_response.lower() != 'y':
            print("Cancelled.")
            return

        # Step 8: Disable each entity
        await perform_entity_disable(websocket, entities_to_disable)


def main():
    """Main entry point."""
    # Get token from environment or command line
    token = os.getenv("HASS_TOKEN")
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        token = sys.argv[1]

    if not token:
        print("Error: No access token provided")
        print("\nUsage:")
        print("  export HASS_TOKEN='your_long_lived_access_token'")
        print("  python3 bulk-disable-ha-entities.py")
        print("\nOr:")
        print("  python3 bulk-disable-ha-entities.py 'your_token_here'")
        print("\nTo create a long-lived access token:")
        print("  1. Go to your Home Assistant profile (click your name in sidebar)")
        print("  2. Scroll to 'Long-Lived Access Tokens'")
        print("  3. Click 'Create Token'")
        print("  4. Give it a name like 'Bulk Entity Disable'")
        print("  5. Copy the token")
        sys.exit(1)

    # Check for dry-run flag
    dry_run = "--dry-run" in sys.argv or "-n" in sys.argv
    if dry_run:
        print("Running in DRY RUN mode - no changes will be made\n")

    # Debug: Show token info (but not the actual token)
    print(f"Token length: {len(token)} characters")
    print(f"Token starts with: {token[:20]}..." if len(token) > 20 else f"Token: {token}")
    print()

    # Run async function
    asyncio.run(disable_entities(token, dry_run))


if __name__ == "__main__":
    main()
