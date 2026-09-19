# Agent Guide

This file is the entry point for AI coding agents working in this repository.
Read the documentation relevant to the change before editing code.

## Start Here

- [Architecture](docs/architecture.md): ownership, data flows, and invariants.
- [Development](docs/development.md): prerequisites, build, run, validation,
  and release procedures.
- [AwoX/Telink Protocol](docs/awox-protocol.md): BLE authentication, packet
  crypto, characteristics, commands, and status parsing.
- [MQTT and Home Assistant](docs/mqtt-home-assistant.md): topic contract,
  payloads, discovery, and broker testing.
- [Security and Privacy](docs/security-and-privacy.md): credentials, local
  storage, logs, and disclosure guidance.
- [Contributing](docs/contributing.md): change discipline and review checklist.

## Project Facts

- This is a native AppKit application for macOS 13 or newer.
- The project is built directly with `xcrun clang` and `xcrun swiftc`; there is
  no Xcode project or Swift package.
- `build.sh` is the canonical build definition and produces an ad-hoc signed
  app in `build/AwoX Mesh Controller.app`.
- `package-release.sh` produces the single GitHub Release ZIP in `dist/`; the
  archive must contain only the app bundle.
- The bundle identifier and Keychain namespace are
  `com.github.bohdandn.awox-mesh-controller`. Changing them loses access to
  existing preferences, Bluetooth authorization, and saved profiles.
- The app has no third-party runtime dependencies. AES uses CommonCrypto
  through `CryptoBridge.c`.

## Source Ownership

- `AppDelegate.swift` owns application lifecycle, AppKit composition,
  serialized BLE operations, and the MQTT-to-BLE bridge.
- `AwoXCrypto.swift` owns Telink authentication, encryption, command packets,
  decryption, and status parsing. Treat byte offsets and byte order as protocol
  contracts.
- `MQTTClient.swift` owns the minimal MQTT 3.1.1 transport.
- `KeychainStore.swift` and `IntegrationStore.swift` own persistent secrets.
- `DeviceCardView.swift` and `IntegrationCardView.swift` own reusable UI cards.
- `AppLogger.swift` owns structured local logs and retention.

## Non-Negotiable Invariants

1. Keep BLE work serialized through the operation queue. CoreBluetooth and UI
   callbacks currently run on the main queue.
2. Authenticate every BLE session before sending encrypted commands.
3. Request and publish fresh device status after a control command; do not
   report an optimistic MQTT state as confirmed hardware state.
4. Subscribe only to `<base-topic>/+/set`. Do not subscribe to `#` or inspect
   unrelated broker traffic.
5. Keep Home Assistant discovery and state retained. Clear both when deleting a
   light or integration.
6. Never log mesh passwords, MQTT passwords, session keys, encrypted packets,
   or complete incoming payloads.
7. Preserve Keychain service names and the bundle identifier unless a migration
   is part of the same change.
8. Do not commit `build/`, logs, credentials, device identifiers, or captured
   Bluetooth/MQTT traffic.

## Working Method

Before editing, identify the owning component and the smallest check that can
falsify the proposed change. After each behavioral edit, run the narrowest
available check, then finish with:

```sh
./build.sh
git diff --check
```

For BLE changes, validate against a compatible physical light. For MQTT
changes, validate the dedicated topic namespace against a local broker and
confirm the entity in Home Assistant. Follow the checklists in
[Development](docs/development.md).

Keep documentation synchronized when changing protocol bytes, persistence,
topic schemas, minimum macOS version, signing, or release behavior.
