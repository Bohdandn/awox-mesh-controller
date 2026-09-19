# MQTT And Home Assistant

## Purpose

Each configured broker exposes saved AwoX lights through a dedicated MQTT
namespace. The app does not subscribe to or inspect unrelated devices.

The default broker is `localhost:1883`, TLS is off, and the default base topic
is `awox-mesh-controller`. Broker settings and credentials are stored in
Keychain.

## Topic Contract

For a lowercased light UUID `<id>` and configured base topic `<base>`:

| Purpose | Topic | Retained |
| --- | --- | --- |
| Command | `<base>/<id>/set` | No requirement |
| State | `<base>/<id>/state` | Yes |
| HA discovery | `homeassistant/light/awox_mesh_controller/<id>/config` | Yes |

The client subscribes at QoS 0 to exactly `<base>/+/set`. It does not subscribe
to `#`, `homeassistant/#`, or another integration's topics.

## Commands

Commands use Home Assistant's MQTT JSON light schema. Fields may be combined:

```json
{"state":"ON"}
```

```json
{"state":"ON","brightness":128,"color":{"r":255,"g":80,"b":0}}
```

```json
{"state":"OFF"}
```

`brightness` is clamped to `0...255` and mapped to the light's `1...100`
percentage range. Zero turns the light off. RGB values are clamped to
`0...255`. Invalid JSON, empty commands, unknown UUIDs, and nested topic paths
are ignored and logged without logging the complete payload.

Commands enter the same serialized BLE queue as UI actions. Confirmed state is
published only after the light responds to the follow-up status request.

## State

State uses retained JSON:

```json
{
  "state": "ON",
  "brightness": 255,
  "color_mode": "rgb",
  "color": {"r": 255, "g": 0, "b": 0}
}
```

The app maps the light's percentage brightness to `0...255`. RGB fields are
included when the light reports color mode.

## Home Assistant Discovery

Discovery is published after MQTT subscription succeeds and whenever a light
is added. The payload uses JSON schema, RGB color mode, a stable unique ID,
command/state topics, and an AwoX/Telink device record. The entity name is null
so the light is represented as the device's main feature without a duplicated
display name.

Known state is republished when an integration connects. Deleting a light or
integration clears its retained discovery and state records before disconnect.

Home Assistant must have its MQTT integration connected to the same broker and
discovery enabled. No YAML entity configuration is required.

## Broker Validation

With Mosquitto command-line clients available, replace `<id>` as needed:

```sh
mosquitto_sub -h localhost -p 1883 \
  -t 'homeassistant/light/awox_mesh_controller/+/config' -v
```

```sh
mosquitto_sub -h localhost -p 1883 \
  -t 'awox-mesh-controller/+/state' -v
```

```sh
mosquitto_pub -h localhost -p 1883 \
  -t 'awox-mesh-controller/<id>/set' \
  -m '{"state":"ON"}'
```

Use an idempotent command during development. Avoid retaining command messages;
a retained command can be replayed whenever the app reconnects. If one is used
for a controlled test, clear it immediately with an empty retained publish.

## Current Transport Limits

- MQTT 3.1.1 only.
- QoS 0 publish and subscribe.
- System trust store only for TLS; no custom CA or client certificate UI.
- No Last Will and Testament or availability topic.
- Reconnect is manual from the integration card.
