# Development

## Prerequisites

- macOS 13 or newer.
- Xcode Command Line Tools (`xcode-select --install`).
- Bluetooth hardware and a compatible AwoX/Telink light for device tests.
- Optional: Mosquitto and Home Assistant for bridge tests.

The project intentionally has no `Package.swift` or Xcode project. The build
script is the complete compiler and linker definition.

## Build And Run

From the repository root:

```sh
chmod +x build.sh
./build.sh
open "build/AwoX Mesh Controller.app"
```

`build.sh` compiles the CommonCrypto bridge, compiles all Swift files, creates
the app bundle and icon, copies `Info.plist`, injects the current commit hash
and UTC build date into the generated bundle plist, and applies an ad-hoc
signature. Compiler and icon intermediates use a temporary directory, so
`build/` contains only `AwoX Mesh Controller.app`. Build output is disposable
and excluded from Git.

## Package A Release

GitHub Release assets must be files, while a macOS `.app` is a directory. Create
the minimal uploadable archive with:

```sh
chmod +x package-release.sh
./package-release.sh
```

The script rebuilds and verifies the app, reads the version from `Info.plist`,
and creates `dist/AwoX-Mesh-Controller-<version>-macos.zip`. The archive contains
only `AwoX Mesh Controller.app` and preserves macOS metadata. Do not upload
compiler objects, icon intermediates, or the unpacked `build/` directory.

The `Release` GitHub Actions workflow runs only when a `v1.0.0`-style tag is
pushed. It creates a draft release titled `1.0.0`, generates GitHub release
notes, writes the tag version to both version fields in the checked-out
`Info.plist`, builds the ZIP on a macOS runner, uploads the ZIP and
`sha256sums.txt`, then publishes the release. The committed `Info.plist` is
not changed by the workflow.

Uploads deliberately do not overwrite existing assets, and pushing the same
tag again cannot create a second release with the same tag. The SHA-256 digest
is printed in the workflow summary and included in `sha256sums.txt`.

The package and checksum are immutable through this workflow after upload.
GitHub repository administrators can still edit or delete releases unless the
repository's GitHub release protection or immutable-release setting is enabled.

An ad-hoc rebuild can change the identity macOS associates with Bluetooth or
Keychain access. A permission prompt after rebuilding is expected. This project
intentionally distributes ad-hoc-signed releases and does not use Developer ID
signing or notarization.

## Project Layout

```text
Assets/                         Application icon source
Sources/AwoXMeshController/     Swift and C implementation
Info.plist                      Bundle metadata and privacy descriptions
build.sh                        Canonical build
package-release.sh              Minimal GitHub release archive
docs/                           Maintainer documentation
```

## Validation

There is no automated test target yet. Every change must at least pass:

```sh
plutil -lint Info.plist
./build.sh
codesign --verify --deep --strict "build/AwoX Mesh Controller.app"
git diff --check
```

Use the smallest relevant runtime checks as well:

- UI: resize the main window, inspect both tabs, open Settings and Logs, and
  verify the menu-bar controls.
- Persistence: restart the app and confirm saved profiles remain available.
- Bluetooth: refresh a light, issue the changed control, and verify reported
  state matches the physical device.
- MQTT: test only the controller topic namespace, verify retained discovery and
  state, then confirm the entity in Home Assistant.
- Deletion: verify retained discovery/state are cleared and the matching
  Keychain item is removed.

Never validate destructive controls against an occupied or safety-critical
environment without the operator's approval.

## Logs

Runtime logs are stored at:

```text
~/Library/Application Support/AwoX Mesh Controller/controller.log
```

Logs use `timestamp|level|message`. Do not add secrets or full protocol payloads
to them. The app exposes log level and retention controls in Settings.

## Release Checklist

1. Choose a release tag such as `v1.0.0`.
2. Review user-facing and protocol documentation.
3. Run the full validation list on the oldest supported macOS version when
   possible.
4. Test BLE control and the Home Assistant MQTT round trip with real hardware.
5. Build from a clean checkout.
6. Push a tag such as `v1.0.0`. The `Release` workflow creates the versioned
  release, generates notes, and attaches the ZIP and its SHA-256 checksum
  automatically.
7. Run `./package-release.sh` locally when inspecting the archive contents.
8. Record user-visible changes in the GitHub release notes.
