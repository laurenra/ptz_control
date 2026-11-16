# PTZ Control

A compact Flutter camera controller for macOS, Windows, iOS, Android, and Linux. The same dark Material interface runs on every target, constrained to a 400 × 800 logical-pixel workspace. Content scrolls on smaller windows and when the debug console is open. Desktop runners start at 400 × 800.

## Run

```sh
flutter pub get
flutter run -d macos
```

Use `flutter devices` to find another target, then `flutter run -d <device-id>`. Build each desktop target on its corresponding OS; mobile builds require the relevant native SDK and signing configuration. This app uses native UDP sockets and does not target web browsers.

## Build

Release builds package the application for use outside the development environment. Run the build commands from the project folder.

### macOS

Build on a Mac with Flutter and Xcode installed:

```sh
flutter pub get
flutter build macos --release
```

The standalone application is created at:

```text
build/macos/Build/Products/Release/ptz_control.app
```

The currently verified release supports **Intel and Apple Silicon Macs running macOS 13 or later**. Flutter and the required frameworks are included in the app, so the receiving Mac does **not** need Flutter, Dart, or Xcode. App Store publishing is not required.

To use the app locally, open the output folder and drag **ptz_control.app** into **Applications**, then double-click it to launch:

```sh
open build/macos/Build/Products/Release
```

To package the complete app bundle for copying to another Mac:

```sh
ditto -c -k --sequesterRsrc --keepParent \
  build/macos/Build/Products/Release/ptz_control.app \
  build/ptz_control-macos.zip
```

Copy **build/ptz_control-macos.zip** to the other Mac, unzip it, drag **ptz_control.app** into **Applications**, and double-click it. Copy the entire `.app` bundle rather than just the executable inside it.

The current build is ad hoc signed and is not notarized. If macOS blocks an app you built or trust, try opening it once, then go to **System Settings → Privacy & Security → Open Anyway**. See [Apple’s instructions for opening an unnotarized app](https://support.apple.com/en-us/102445).

Camera configurations and preset display names are stored separately on each Mac; copying the app does not transfer them. Presets stored in the camera remain in the camera.

### Android

Build with Flutter and the Android SDK installed. Check the Android toolchain with `flutter doctor -v` and resolve any reported issues before building. See [Flutter’s Android setup instructions](https://docs.flutter.dev/platform-integration/android/setup).

To compile, install, and launch the app on an Android device:

1. On the phone, enable **Developer options → USB debugging**.
2. Connect the phone by USB and accept the debugging authorization prompt.
3. Run these commands from the project folder:

   ```sh
   flutter pub get
   flutter devices
   flutter run --release -d <device-id>
   ```

   Replace `<device-id>` with the Android device ID listed by `flutter devices`.

To create an APK you can copy to another device:

```sh
flutter pub get
flutter build apk --release
```

The APK is created at:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Transfer the APK to the phone, open it, and allow installation from that source if prompted. See [Flutter’s Android build and release guidance](https://docs.flutter.dev/deployment/android).

The current Flutter configuration requires **Android 7.0 or newer**. Release builds currently use the debug signing key, which supports local installation; Play Store distribution requires release signing to be configured in `android/app/build.gradle.kts`.

For camera control, connect the phone to Wi-Fi that can reach the camera’s network. The Android Internet permission is already included.

## Connect a camera

1. Open **Cameras** → **Add camera**.
2. Enter a name, unicast IPv4 address, and the camera's configured UDP port.
3. Choose the packet format supported by the camera:
   - **Raw VISCA** sends the VISCA bytes directly (default port 1259).
   - **VISCA over IP** (the default for new cameras) prepends the eight-byte payload/length/sequence header (default port 52381). Opening a session sends the sequence-reset control packet. Replies are matched by sequence number.
4. Leave **Local port** at 0 to use an available port. Some cameras require a fixed controller port; enter that value if needed.
5. Save, then select a camera from the dropdown on **Control** or **Image**. Up to eight configurations are stored locally across launches. Saving changes to a camera selects and reconnects it.

The computer or phone must be able to reach the camera's network. Enable VISCA UDP in the camera if necessary and allow UDP replies through your firewall. Android's Internet permission, Apple's local-network usage description, and macOS sandbox networking entitlements are included. Allow local-network access when the OS prompts. The current Flutter Android target is SDK 36; when upgrading to target SDK 37+, add and request Android’s `ACCESS_LOCAL_NETWORK` runtime permission before opening camera sockets ([Android guidance](https://developer.android.com/privacy-and-security/local-network-permission)).

## Controls

- Hold any of eight arrows to pan/tilt; release, drag outside, or cancel the pointer to stop. Focus loss, app backgrounding, tab changes, and camera changes also end a held movement. Only one held movement is accepted at a time. Keyboard users can focus a button and hold Space or Enter; assistive activation makes a brief movement.
- Speeds: pan **1–24** (`01–18` hex), tilt **1–20** (`01–14`), zoom/focus **0–7** (`00–07`). These are dropdowns to enforce valid ranges. A lens speed of zero means the slowest variable speed; it does not mean stop.
- The center pad button sends **Stop all movement** (pan/tilt, zoom, and focus). A separate home icon centered above the preset grid sends **Home**. Stops preempt waiting requests and cancel unsent motion commands and preset recalls.
- Enable **Sync pan/tilt** to link the two speed dropdowns. Both use the shared range **1–20** while linked; enabling sync clamps an existing pan speed above 20 to 20. Unchecking sync restores independent controls and pan’s full 1–24 range.
- The narrow zoom −/+ and focus near/far buttons to the right of the speed dropdowns are also hold controls. Manual focus becomes available when a camera inquiry confirms manual focus mode. Set the mode on **Image**.
- **Image** sends exposure mode, aperture/iris, shutter, gain, white balance, red/blue gain, and autofocus commands. Queried raw decimal values appear to the right of the aperture, shutter, gain, red gain, and blue gain step buttons; unavailable values show a dash. Triggering one-push white balance requires a Yes/Cancel confirmation. Select Manual or the appropriate priority mode before adjusting exposure, and Manual white balance before adjusting color gains. Mode dropdowns and the focus label show the queried camera settings.
- The overflow menu offers **Debug console**, **Navigation on left**, **Reconnect camera**, and help. The console keeps the latest 200 events with timestamps, command descriptions, camera endpoint, and complete TX/RX hex bytes, including Sony headers. Use the save icon to export the current events to a UTF-8 `.txt` file through the system save dialog. The export preserves console order (newest first) and uses full UTC timestamps. It captures the events present when Save is pressed, even if polling continues. Clear it or hide it at any time. It is hidden on launch.

## Presets

Each camera has nine preset buttons, initially numbered 1–9. They use the camera’s built-in VISCA preset memory. Button 1 maps to VISCA memory address 0, through button 9 at address 8. Only the display names are stored locally with the camera’s configuration.

- Move the camera to the desired shot. Enable **Save preset**, then press a preset button. Enter a name of up to **40 characters on two lines**, for example `2 Podium` / `Extra Wide`. **Save** sends VISCA Memory Set and waits for camera completion before storing the local name. Saving replaces that preset in the camera. **Cancel** or **Escape** closes the dialog without sending a save command.
- When the queried exposure mode is **Manual**, the dialog shows **“Manual exposure mode enabled. Exposure and image settings are also saved.”** above the name entry. The camera saves and restores the settings supported by its preset memory, including manual exposure and image settings; the app does not store or reapply individual values. The exact settings included depend on the camera model and its preset configuration.
- Uncheck **Save preset** to recall shots. Every preset button sends VISCA Memory Recall, even without a locally saved name, so presets configured outside this app can be recalled. The camera reports any unsupported or empty slots.
- **Save aperture with preset** is disabled and unchecked for now. It does not add commands or change the camera’s native preset behavior.
- Recall waits up to 30 seconds for camera completion. Other camera controls are disabled during the operation; the center **Stop** remains available. Stop, changing tabs/cameras, or backgrounding the app interrupts a pending recall wait and sends movement stops. Position telemetry updates on the next five-second poll; recall does not trigger a full settings query.
- Existing local preset names are retained, but old app-managed PTZ/aperture snapshots are no longer used or automatically uploaded. Save the desired shots to camera memory before relying on those names. If local name storage fails after the camera has saved a preset, a message explains that the camera save succeeded and the name is available only for the current session.

The memory commands and zero-based numbering follow the [Sony VISCA command list](https://pro.sony/support/res/manuals/5053/f48354480e724f0aef3d45d2e1eeab63/50531551M.pdf), preset commands on page 18.

The compact Control page places the refresh button next to camera selection, shows `PAN: value`, `TILT: value`, and `ZOOM: value` on one status line, and keeps the nine presets and save controls visible in a 400 × 800 workspace with bottom navigation. Smaller windows, side navigation at narrow widths, and the optional debug console use scrolling as needed.

## Camera status and protocol limits

Selecting a camera opens its UDP socket and queries pan/tilt, zoom, focus mode, AE exposure mode, white balance mode, and the five raw image adjustment values. The status card shows the queried exposure and white balance names below the position values. Missing replies show a dash, and unrecognized mode codes are shown as unknown with their hex code. Only pan/tilt and zoom positions are polled automatically, every five seconds. These polls pause while a movement is held or a preset operation is running, and resume on the regular timer afterward. Exposure, white balance, focus mode, and raw image values are queried once on entering a page that displays them. Changing a setting waits for command completion and then queries only that setting; one-push white balance queries its mode and both affected color gains. Camera selection and the refresh button query all settings. Pan/tilt, zoom, home, and preset recall commands do not trigger extra position or full-settings queries. **Connected** requires a valid VISCA reply from the configured camera address and port; sending a UDP datagram does not establish a connection. After fifteen seconds without replies, the UI shows **No response** and clears telemetry. A status refresh button and reconnect action are available.

Pan/tilt use signed 16-bit camera-native position units. Zoom is shown as its raw decimal position; the debug console still shows wire bytes in hexadecimal. Scaling these values into degrees or optical magnification requires a camera-specific profile. The app deliberately does not assume one universal conversion.

Requests are serialized, normally time out after 700 ms, and log camera errors. Movement commands complete from the client's perspective on ACK or completion; an ACK means accepted, not that a physical move has finished. Setting changes and preset operations wait for completion; one-push balance allows up to ten seconds, and preset operations allow up to thirty seconds. Raw VISCA has no transaction IDs: known inquiry reply lengths are matched, but delayed raw error/ACK replies cannot always be attributed to a particular command. Sony framing provides sequence matching. Delivery and stopping cannot be guaranteed over UDP, and an OS force-quit cannot reliably send a final stop. This version does not automatically retransmit movement commands.

Command support, speed limits, exposure values, and behavior vary by camera model. The common VISCA command set is implemented; model-specific controls can be added in the existing service/controller layers. Camera preset save/recall is covered by simulated-camera tests; verify their behavior with your camera model before operational use. Some cameras require local UDP port 52381 as well as destination port 52381, rather than an automatically assigned local port.

References: [Sony VISCA command list and IP protocol](https://pro.sony/support/res/manuals/E042/3230148ee903c204b912cca5c2c3f5aa/E0421001M.pdf), [PTZOptics movement commands](https://devs.ptzoptics.com/visca-api/movement/), [PTZOptics exposure commands](https://devs.ptzoptics.com/visca-api/exposure/).

## Code and checks

- `lib/models/camera.dart` and `camera_preset.dart`: validated camera configuration, transport choice, and local names for camera memory presets.
- `lib/services/camera_store.dart`: local configuration persistence.
- `lib/services/visca_protocol.dart`: packet encoding, framing, and position decoding.
- `lib/services/visca_client.dart`: UDP lifecycle, request serialization, response validation, logging, completion handling, and stop priority.
- `lib/controller.dart`: selection, polling, status, settings, speeds, and movement state.
- `lib/widgets/`: compact tab shell, setup editor, and hold-to-move buttons.

```sh
flutter analyze
flutter test
flutter build macos --debug
```

Tests cover packet encoding/ranges, signed telemetry, configuration persistence and validation, raw/Sony local UDP peers, source filtering, stop priority, held-button cancellation, speed synchronization, two-line preset names and cancellation, camera-memory preset save/recall, manual-exposure messaging, legacy name migration, camera-save failures, local name-storage failures, interrupted recalls, five-second PTZ-only polling, scoped setting refreshes, and compact layouts with both navigation placements. The macOS debug app has been built and launched locally; other OS builds and physical-camera checks remain to be performed on their target hardware.
