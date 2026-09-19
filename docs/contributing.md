# Contributing

## Before A Change

1. Read `AGENTS.md` and the relevant design document.
2. Identify whether the change belongs to UI, BLE orchestration, protocol,
   persistence, MQTT transport, or Home Assistant behavior.
3. Define the smallest build or runtime check that can disprove the approach.

Keep changes focused. Preserve existing bundle, Keychain, MQTT, and protocol
contracts unless the change includes a documented migration.

## Code Style

- Follow the existing Swift and AppKit style.
- Keep UI updates and CoreBluetooth coordination on the main queue.
- Use descriptive names and short functions around state transitions.
- Add comments only for protocol constraints or non-obvious invariants.
- Prefer platform frameworks over dependencies for small capabilities.
- Keep secrets and full payloads out of logs and error messages.

## Review Checklist

- The app builds with `./build.sh`.
- `plutil -lint Info.plist` and `git diff --check` pass.
- The app launches and affected UI remains usable at its minimum window size.
- BLE changes were tested on compatible physical hardware.
- MQTT changes were tested only against the controller namespace and verified
  in Home Assistant when applicable.
- Persistence changes preserve or deliberately migrate existing Keychain data.
- User-facing behavior and changed contracts are documented.
- Build products, logs, credentials, and device data are absent from the diff.

## Pull Requests

Describe the user-visible result, implementation constraints, and exact checks
performed. Call out hardware or Home Assistant testing that could not be run.
Protocol changes should explain the evidence for byte offsets, opcodes, and
byte order without publishing sensitive captures.
