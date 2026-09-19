# Security And Privacy

## Sensitive Data

Light profiles contain a CoreBluetooth identifier, display name, mesh name,
mesh password, and protocol address. MQTT profiles contain the broker address,
topic, username, password, and TLS preference.

Profiles are JSON-encoded and stored as individual macOS generic-password
Keychain items under these services:

```text
com.github.bohdandn.awox-mesh-controller.devices
com.github.bohdandn.awox-mesh-controller.integrations.mqtt
```

Items use `kSecAttrAccessibleAfterFirstUnlock`. The bundle identifier is
`com.github.bohdandn.awox-mesh-controller`; changing identifiers requires an
explicit data migration plan.

## Other Local Data

Refresh interval, maximum log size, and minimum log level use `UserDefaults`.
Runtime logs are stored at:

```text
~/Library/Application Support/AwoX Mesh Controller/controller.log
```

Logs may contain light names, broker names and addresses, command descriptions,
and operational errors. They must never contain passwords, session keys,
complete MQTT payloads, or raw BLE packets. Logs are size-limited by the app.

The repository must not contain real profiles, logs, device identifiers,
credentials, broker captures, or Bluetooth packet captures.

## Network And Trust

Plain MQTT sends credentials and device state without transport encryption and
should be limited to a trusted local network. Enable TLS for untrusted networks.
TLS currently uses the macOS system trust store and does not support custom CA
selection or mutual TLS.

Home Assistant discovery and state are retained on the broker. Deletion clears
the controller's retained records, but broker backups may retain historical
data according to broker policy.

## Reporting A Vulnerability

Once the GitHub repository is public, report vulnerabilities through a private
GitHub Security Advisory when available. Do not include credentials, session
keys, device identifiers, or packet captures in a public issue.
