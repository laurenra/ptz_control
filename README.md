# PTZ Control

A compact Flutter camera controller for macOS, Windows, iOS, Android, and Linux. The same dark Material interface runs on every target, constrained to a 400 × 800 logical-pixel workspace. Content scrolls on smaller windows and when the debug console is open. Desktop runners start at 400 × 800.

## Run

```sh
flutter pub get
flutter run -d macos
```

Use `flutter devices` to find another target, then `flutter run -d <device-id>`. Build each desktop target on its corresponding OS; mobile builds require the relevant native SDK and signing configuration. This app uses native UDP sockets and does not target web browsers.

## Connect a camera

1. Open **Cameras** → **Add camera**.
2. Enter a name, unicast IPv4 address, and the camera's configured UDP port.
3. Choose the packet format supported by the camera:
   - **Raw VISCA** sends the VISCA bytes directly (default port 1259).
   - **Sony VISCA over IP** prepends the eight-byte payload/length/sequence header (default port 52381). Opening a session sends the sequence-reset control packet. Replies are matched by sequence number.
4. Leave **Local port** at 0 to use an available port. Some cameras require a fixed controller port; enter that value if needed.
5. Save, then select a camera from the dropdown on **Control** or **Image**. Up to eight configurations are stored locally across launches. Saving changes to a camera selects and reconnects it.

The computer or phone must be able to reach the camera's network. Enable VISCA UDP in the camera if necessary and allow UDP replies through your firewall. Android's Internet permission, Apple's local-network usage description, and macOS sandbox networking entitlements are included. Allow local-network access when the OS prompts. The current Flutter Android target is SDK 36; when upgrading to target SDK 37+, add and request Android’s `ACCESS_LOCAL_NETWORK` runtime permission before opening camera sockets ([Android guidance](https://developer.android.com/privacy-and-security/local-network-permission)).

## Controls

- Hold any of eight arrows to pan/tilt; release, drag outside, or cancel the pointer to stop. Focus loss, app backgrounding, tab changes, and camera changes also end a held movement. Only one held movement is accepted at a time. Keyboard users can focus a button and hold Space or Enter; assistive activation makes a brief movement.
- Speeds: pan **1–24** (`01–18` hex), tilt **1–20** (`01–14`), zoom/focus **0–7** (`00–07`). These are dropdowns to enforce valid ranges. A lens speed of zero means the slowest variable speed; it does not mean stop.
- The center button sends **Home**. **Stop all movement** sends pan/tilt, zoom, and focus stops. Stops preempt waiting requests and cancel unsent motion commands.
- Zoom −/+ and focus near/far are also hold controls. Manual focus becomes available when a camera inquiry confirms manual focus mode. Set the mode on **Image**.
- **Image** sends exposure mode, aperture/iris, shutter, gain, white balance, red/blue gain, and autofocus commands. Select Manual or the appropriate priority mode before adjusting exposure, and Manual white balance before adjusting color gains. Mode dropdowns show the last requested choice, not confirmed camera settings. The focus label is read from the camera.
- The overflow menu offers **Debug console**, **Navigation on left**, **Reconnect camera**, and help. The console keeps the latest 200 events with timestamps, command descriptions, camera endpoint, and complete TX/RX hex bytes, including Sony headers. Clear it or hide it at any time. It is hidden on launch.

## Camera status and protocol limits

Selecting a camera opens its UDP socket and queries pan/tilt, zoom, and focus mode. Polling repeats every two seconds, pauses while a movement is held, and resumes afterward. **Connected** requires a valid VISCA reply from the configured camera address and port; sending a UDP datagram does not establish a connection. After five seconds without replies, the UI shows **No response** and clears telemetry. A status refresh button and reconnect action are available.

Pan/tilt use signed 16-bit camera-native position units. Zoom is shown as its raw hexadecimal position. Scaling these values into degrees or optical magnification requires a camera-specific profile. The app deliberately does not assume one universal conversion.

Requests are serialized, time out after 700 ms, and log camera errors. Commands complete from the client's perspective on ACK or completion; an ACK means accepted, not that a physical move has finished. Raw VISCA has no transaction IDs: known inquiry reply lengths are matched, but delayed raw error/ACK replies cannot always be attributed to a particular command. Sony framing provides sequence matching. Delivery and stopping cannot be guaranteed over UDP, and an OS force-quit cannot reliably send a final stop. This version does not automatically retransmit movement commands.

Command support, speed limits, exposure values, and behavior vary by camera model. The common VISCA command set is implemented; model-specific controls and presets can be added in the existing service/controller layers. No physical camera was available during implementation, so verify the chosen packet format, local port, telemetry, and settings with your camera before operational use.

References: [Sony VISCA command list and IP protocol](https://pro.sony/support/res/manuals/E042/3230148ee903c204b912cca5c2c3f5aa/E0421001M.pdf), [PTZOptics movement commands](https://devs.ptzoptics.com/visca-api/movement/), [PTZOptics exposure commands](https://devs.ptzoptics.com/visca-api/exposure/).

## Code and checks

- `lib/models/camera.dart`: validated camera configuration and transport choice.
- `lib/services/camera_store.dart`: local configuration persistence.
- `lib/services/visca_protocol.dart`: packet encoding, framing, and position decoding.
- `lib/services/visca_client.dart`: UDP lifecycle, request serialization, response validation, logging, and stop priority.
- `lib/controller.dart`: selection, polling, status, settings, speeds, and movement state.
- `lib/widgets/`: compact tab shell, setup editor, and hold-to-move buttons.

```sh
flutter analyze
flutter test
flutter build macos --debug
```

Tests cover packet encoding/ranges, signed telemetry, configuration persistence and validation, raw/Sony local UDP peers, source filtering, stop priority, held-button cancellation, and compact layouts with both navigation placements. The macOS debug app has been built and launched locally; other OS builds and physical-camera checks remain to be performed on their target hardware.
