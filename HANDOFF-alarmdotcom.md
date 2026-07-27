# Alarm.com integration — work-in-progress handoff

> **Archival — 2026-05-22.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `overlays/default.nix`).

**Date:** 2026-05-22
**Status:** Changes staged on disk and in `/etc/nixos`. Awaiting `nixos-rebuild
switch` from `/etc/nixos` (the main worktree, not water-attribution) to bring
HA back to a working state.

## TL;DR

The Home Assistant `alarmdotcom` integration (HACS-managed) for ADT Control /
Alarm.com is being moved from v3.0.15 + pyalarmdotcomajax 0.5.13 to
v4.0.1-beta.2 + pyalarmdotcomajax 0.6.0b9. Auth has already been completed
successfully on the older line, so the existing session/cookie should let the
new line skip the broken initial-OTP flow.

**Until the rebuild runs, HA is in a broken state for `alarmdotcom`**: the
on-disk integration files require `pyalarmdotcomajax` 0.6.x but the live Python
env still has 0.5.13. HA will log `ModuleNotFoundError: cannot import name
'AlarmBridge' from 'pyalarmdotcomajax'` (or similar) until the rebuild swaps in
0.6.0b9. The rest of HA is unaffected.

## What's staged

1. **`/etc/nixos/overlays/default.nix`** — `pyalarmdotcomajax` Python package
   pinned to **0.6.0b9** (PyPI sdist). Includes `setuptools-scm` build dep with
   `SETUPTOOLS_SCM_PRETEND_VERSION` and `pythonRelaxDeps = [ "pyhumps" ]` to
   bridge an upstream `~=3.8.0` pin against nixpkgs's 3.9.0. Sits in
   `haPackageOverrides` after the `aiopnsense` block.

2. **`/etc/nixos/modules/services/home-assistant.nix`** — `ps.pyalarmdotcomajax`
   added to `services.home-assistant.extraPackages` (near `ps.awsiotpythonsdk`).

3. **`/var/lib/hass/custom_components/alarmdotcom/`** — files swapped from
   v3.0.15 to v4.0.1-beta.2. Backups on disk:
   - `/var/lib/hass/custom_components/.alarmdotcom-3.0.15.bak` (currently
     swapped out; the v3.0.15 line that *was* working for auth but whose
     entities crash with `AttributeError: 'BinarySensor' object has no
     attribute '_friendly_name_internal'` on HA 2026.5.x)
   - The earlier `/var/lib/hass/custom_components/.alarmdotcom-4.0.1-beta.2.bak`
     was renamed back into the active spot, so that backup is gone.

   HACS's view of the installed version is unchanged (it already had
   v4.0.1-beta.2 listed before the v3.0.15 detour) so no HACS tracker repair
   needed.

The HA config entry for `Alarm.com:jwiegley@gmail.com` exists in
`.storage/core.config_entries` with a successfully-authenticated session from
the v3.0.15 attempt — that's what we're counting on v4.0.1-beta.2 to inherit.

## What the other process needs to do

1. Run `sudo nixos-rebuild switch --flake '.#vulcan'` **from `/etc/nixos`**, not
   from `/etc/nixos.worktrees/water-attribution`. (Earlier in the session a
   rebuild from the water-attribution worktree rolled back the overlay change
   because that branch doesn't have it. See "Worktree gotcha" below.)

2. HA will restart automatically as part of the switch. Give it ~60 seconds to
   fully come up.

## Verification — what to check after the rebuild

### 1. Confirm the integration loads cleanly

```
sudo journalctl -u home-assistant --since "5 minutes ago" --no-pager \
  | grep -iE "alarmdotcom|pyalarmdotcomajax" \
  | grep -v "not been tested"
```

**Expected:** the only `alarmdotcom` lines should be info-level (`Setup of
domain alarmdotcom took X seconds`, etc.). No `ModuleNotFoundError`. No
`AttributeError`.

**If you see `Config entry ... could not authenticate: Authentication failed`**
→ the v0.6.x rewrite is rejecting the inherited cookie. This means the
workaround didn't pan out and we need to revert (see Rollback).

### 2. Confirm sensors are populating

In HA UI: **Settings → Devices & Services → Alarm.com → Devices**. Click on
"Master Window" (or any door/window/motion sensor). The state should be `On`
(open) or `Off` (closed), not `Unknown` or `Unavailable`.

Also from the journal — the v4.0.1-beta.2 integration is push-based, so look
for connection-established messages and per-device state events:

```
sudo journalctl -u home-assistant --since "5 minutes ago" --no-pager \
  | grep -iE "alarmdotcom" \
  | grep -iE "websocket|push|connect|state" \
  | head -20
```

### 3. Sanity check the Python env

```
ls /nix/store | grep "pyalarmdotcomajax-0.6.0b9" | grep -v drv | grep -v "\.lock"
```

Should list at least one populated `python3.14-pyalarmdotcomajax-0.6.0b9`
directory.

## Known issues with v4.0.1-beta.2 (watch for these later)

1. **MFA cookie acquisition bug**
   ([upstream issue #534](https://github.com/pyalarmdotcom/alarmdotcom/issues/534)):
   affects only *fresh* OTP submission. Our existing session should sidestep
   it. **If at any point HA prompts for re-auth** (e.g. session cookie
   eventually expires server-side), the OTP step will fail with
   `UnexpectedResponse: Could not find MFA cookie after submitting OTP`. That
   would force us back through the v3.0.15-as-intermediate dance.

2. **Push-connection disconnects without auto-recovery**: reported in the same
   issue thread. Symptom is sensor states freezing after a few hours, with
   stale data until something kicks the integration. Workaround if it bites: a
   scheduled HA restart automation (`automation: trigger: time at 03:00 ->
   action: homeassistant.restart`).

## Rollback procedure (if v4.0.1-beta.2 doesn't pan out)

This puts us back where we are right now — auth works, but sensor entities
crash on HA 2026.5.x. Not ideal, but stable until upstream fixes things.

```bash
# 1. Swap files back
sudo mv /var/lib/hass/custom_components/alarmdotcom \
        /var/lib/hass/custom_components/.alarmdotcom-4.0.1-beta.2.bak
sudo mv /var/lib/hass/custom_components/.alarmdotcom-3.0.15.bak \
        /var/lib/hass/custom_components/alarmdotcom
sudo chown -R hass:hass /var/lib/hass/custom_components/alarmdotcom
```

Then revert the `pyalarmdotcomajax` block in `/etc/nixos/overlays/default.nix`
to **0.5.13** (PyPI sdist, hash `sha256-uCtNurYbONs07bJ1ZwM+KSnfhknFhLv0QMCLbLRa5r0=`,
no `setuptools-scm`, no `pythonRelaxDeps`, deps just `aiohttp`,
`beautifulsoup4`, `python-dateutil`, `termcolor`). Re-run `nixos-rebuild switch`.

## Worktree gotcha

The user has `/etc/nixos.worktrees/water-attribution` checked out for unrelated
work. Earlier in this session, an `nixos-rebuild switch` from that worktree
silently rolled back the `pyalarmdotcomajax` overlay change because the change
hadn't been committed and the worktree branch doesn't have it. The current
state is: changes are present in `/etc/nixos` working tree (uncommitted).

**Options to make this durable:**
- Commit the overlay change on `main` and merge it into water-attribution, or
- Cherry-pick the two file changes (`overlays/default.nix`,
  `modules/services/home-assistant.nix`) onto the water-attribution branch.

Until then: **always rebuild from `/etc/nixos`**, never from the worktree, or
the next switch from water-attribution will revert pyalarmdotcomajax to "not
present" and break HA's `alarmdotcom` integration again.

## Background — full history of this session for context

1. **Original symptom**: HA UI showed `Config flow could not be loaded: Invalid
   handler specified` when trying to Add Integration → Alarm.com. Root cause:
   `pyalarmdotcomajax` not in HA's Python env (HA runs with `--skip-pip` on
   NixOS, so HACS can't pip-install the integration's Python deps).

2. **First fix**: added `pyalarmdotcomajax` 0.6.0b9 to the overlay and to
   `extraPackages`. Build + switch. Integration loaded. User attempted config
   flow with username + password + Google Authenticator OTP.

3. **Hit upstream issue #534**: `UnexpectedResponse: Could not find MFA cookie
   after submitting OTP`. The v0.6.x rewrite of `pyalarmdotcomajax` has a bug
   in initial MFA cookie acquisition.

4. **Workaround attempt — went to v3.0.15 / 0.5.13 line**: I downgraded the
   Python package in the overlay and swapped the on-disk integration files to
   v3.0.15. First auth attempt got HTTP 422 "Wrong code" from Alarm.com's API.
   Subsequent retries got HTTP 403 (account lockout from too many failed 2FA
   attempts).

5. **Diagnosed 2FA root cause**: user's Google Authenticator entry for
   Alarm.com was stale — account settings showed authenticator-app 2FA as
   enabled, but the web didn't actually prompt for it (the seed on the phone
   and the seed Alarm.com expected had diverged). User re-enrolled the
   authenticator app at control.adt.com, scanned a fresh QR code, and then auth
   succeeded in HA on the v3.0.15 line.

6. **Discovered v3.0.15 is silently broken on HA 2026.5.x**: integration loads
   and auth works, but every `binary_sensor` (windows/doors/motion) entity
   crashes during add with `AttributeError: 'BinarySensor' object has no
   attribute '_friendly_name_internal'` — that's a private HA Entity API that
   was removed in 2026.5. User saw the entities listed but with no state.

7. **Confirmed v4.0.1-beta.2 doesn't use that removed API** → no
   `_friendly_name_internal` references in the backup. Decision: move to
   v4.0.1-beta.2 + 0.6.0b9, relying on the existing session to skip the broken
   MFA flow from step 3.

8. **Current state** = end of step 7. Staged. Awaiting your rebuild.
