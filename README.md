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

Camera configurations, preset display names, and preset snapshots are stored separately on each Mac; copying the app does not transfer them. Presets stored in the camera remain in the camera.

Note: Xcode 27 no longer requires macOS binaries to support the x86_64 architecture. To build ARM-only macOS apps now, run: `flutter config --enable-macos-arm64-only`. This will become the default behavior
in a future Flutter release.

### iOS

Build on a Mac with Flutter, Xcode, and CocoaPods installed. The iOS project is already included and targets **iOS 15 or later**. Check the iOS toolchain and open the Xcode workspace:

```sh
flutter doctor -v
flutter pub get
open ios/Runner.xcworkspace
```

Resolve any iOS toolchain issues reported by `flutter doctor` before building. See [Flutter’s iOS setup instructions](https://docs.flutter.dev/platform-integration/ios/setup).

To compile, install, and launch the app on an iPhone or iPad:

1. In Xcode, select the **Runner** project, then the **Runner** target → **Signing & Capabilities**.
2. Enable **Automatically manage signing** and select your **Team**. Add your Apple account if needed. A free Apple account works for testing on your own device.
3. The bundle identifier is currently `com.ptz.ptzControl`. Change it to a unique identifier if Xcode reports that it is unavailable.
4. Connect the device by USB, unlock it, and accept the **Trust This Computer** prompt. Enable **Settings → Privacy & Security → Developer Mode** on the device and restart it if prompted.
5. Run these commands from the project folder:

   ```sh
   flutter devices
   flutter run --release -d <device-id>
   ```

   Replace `<device-id>` with the iPhone or iPad device ID listed by `flutter devices`. This compiles, signs, installs, and launches the app. If prompted on the device, trust the developer certificate under **Settings → General → VPN & Device Management**.

For **TestFlight or App Store distribution**, enroll in the Apple Developer Program, register the app in App Store Connect, and configure distribution signing. Then build the release package:

```sh
flutter build ipa --release
```

The Xcode archive is created in `build/ios/archive/`, and the exported `.ipa` is created in `build/ios/ipa/`. See [Flutter’s iOS build and release guidance](https://docs.flutter.dev/deployment/ios) for uploading and distributing the build.

For camera control, connect the device to Wi-Fi that can reach the camera’s network and allow **Local Network** access when prompted. The local-network permission description is already included.

### Android

Build with Flutter and the Android SDK installed. Check the Android toolchain with `flutter doctor -v` and resolve any reported issues before building. See [Flutter’s Android setup instructions](https://docs.flutter.dev/platform-integration/android/setup).

To compile, install, and launch the app on an Android device:

1. You may have to turn off Auto Blocker on the phone. Go to **Settings → Privacy & Security → Auto Blocker** and turn it off.
2. On the phone, enable **Developer options → USB debugging**.
3. Connect the phone by USB and accept the debugging authorization prompt.
4. Run these commands from the project folder:

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
5. Use **Test connection** below the local-port instructions to check the entered network settings before saving. It sends a pan/tilt position inquiry without moving the camera. A valid position reply shows **Connected**; no reply, invalid data, or a socket error shows **Not connected** beside the button. The indicator uses the same colors and dot as Control, and changing the address, ports, or packet format clears a successful result. Opening **Edit camera** automatically tests the saved connection settings once and displays the result.
6. **Get camera info**, directly below **Test connection**, retrieves the manufacturer, model, serial number, and MAC address and displays them beneath the button. Choose **Save camera** to keep those details. Open **Camera info connection** if the camera needs a different web/ONVIF port, HTTPS, or a username and password. Login details are used only for the current editor session and are never saved or exported.
7. **Test & save limits** sweeps pan left/right, tilt down/up, and zoom out/in, one axis at a time, using the entered connection settings. It shows **Please wait. Testing limits...** while polling positions. After a successful sweep, the app saves the camera settings and all six measured bounds immediately and shows them in the **Pan**, **Tilt**, and **Zoom** rows under **Min** and **Max**. Saved limits appear when reopening the editor. **Stop test** interrupts the sweep; failed or interrupted tests keep the previous saved limits. Each direction allows up to 90 seconds and requires repeated unchanged position replies before accepting an endpoint. After measuring all six limits, the app sends Home and waits for the camera to finish returning home before saving the results. A failed or interrupted Home move also keeps the previous saved limits. The app does not change the camera’s configured hardware or software travel limits. Editing the IP address, UDP packet format, camera port, or local port preserves the saved Min and Max values for pan, tilt, and zoom.
8. Save, then select a camera from the dropdown on **Control** or **Image**. Up to eight configurations are stored locally across launches. Saving changes to a camera selects and reconnects it.

Multiple cameras can use the same **Camera port**, such as 52381, at different IP addresses. If **Test connection** fails with **Local port** 0 but succeeds with 52381, keep the working fixed local port. Saved cameras may share that local port: the app controls one selected camera at a time and waits for the previous socket to release the port before switching or testing another camera. Another running app or instance of this app can still occupy that port; close its connection before using it here.

The computer or phone must be able to reach the camera's network. Enable VISCA UDP in the camera if necessary and allow UDP replies through your firewall. Android's Internet permission, Apple's local-network usage description, and macOS sandbox networking entitlements are included. Allow local-network access when the OS prompts. The current Flutter Android target is SDK 36; when upgrading to target SDK 37+, add and request Android’s `ACCESS_LOCAL_NETWORK` runtime permission before opening camera sockets ([Android guidance](https://developer.android.com/privacy-and-security/local-network-permission)).

The identity lookup uses read-only [ONVIF device operations](https://www.onvif.org/yaml/wsdl-viewer2.php) (`GetDeviceInformation` and `GetNetworkInterfaces`) at `/onvif/device_service`, with a fallback to the [PTZOptics HTTP API](https://docs.ptzoptics.com/resources/http-api/query/get-device-config/). This uses the camera’s web port (default 80), separately from the UDP camera and local ports, and leaves the active UDP connection in place. Some cameras require ONVIF to be enabled or a camera login; support and returned fields vary by model. Unavailable fields show **Not reported** after a successful partial lookup. A failed lookup keeps existing details. Partial results from the same IP preserve previously retrieved fields; a successful lookup at a different IP replaces the cached identity, and the last queried IP is displayed beneath the details. Normal platform network and certificate policies apply; use HTTPS where required.

## Find cameras

On **Cameras** → **Your cameras**, the action row contains **Find cameras**, **Export**, and **Import**, in that order. **Find cameras** sends a WS-Discovery multicast probe to `239.255.255.250` on UDP port `3702` through each active IPv4 interface, with two retries. It collects replies for five seconds and displays each responding ONVIF device's **EndpointReference (address)**, **Types**, **Scopes**, and **XAddrs** as advertised. Results appear as they arrive, combine repeated replies by endpoint reference, and remain open after the search finishes. **Cancel** stops any pending probes, releases discovery sockets, and closes the display. Discovery uses separate ephemeral local ports from VISCA camera control and does not add or modify saved cameras.

Only devices that respond to multicast discovery can appear; cameras must have discovery enabled and be on a network that allows multicast traffic. See [ONVIF Core, section 7](https://www.onvif.org/specs/core/ONVIF-Core-Specification.pdf) for device discovery behavior. The saved-camera limit does not limit the number of discovery results.

On iOS/iPadOS, multicast additionally requires signing with Apple's `com.apple.developer.networking.multicast` entitlement, which the current iOS runner does not include. Configure an approved provisioning profile before using discovery on physical iOS devices; see [Apple's local network and multicast requirements](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Export and import camera settings

On **Cameras** → **Your cameras**, choose **Export** and select a location for the `.json` file. Exports contain every saved camera in display order, including IDs, names, IPv4 addresses, UDP packet formats, camera and local ports, measured pan/tilt/zoom limits, retrieved device identity, and local preset names and snapshots. The next-ID counter is included so its sequence continues when the file is restored.

Each exported camera includes an `info` object with `manufacturer`, `model`, `serialNumber`, and `macAddress`; details not yet retrieved or not reported by the camera are `null`. When available, `sourceHost` records the IP queried. Use **Get camera info** in the editor and **Save camera** before exporting to include newly retrieved details. Export uses saved settings and does not query cameras again.

Choose **Import**, select an exported JSON file, and review the listed cameras. **Replace cameras** replaces the entire saved camera list with the file’s contents; **Cancel** keeps the current setup. Import preserves a selection when the same ID and camera endpoint are present; otherwise it selects the first imported camera. A camera may remain offline if its network is unavailable on the receiving device.

Import restores all available camera info and displays it when reopening **Edit camera**, even if the camera is offline. Partial information and older files without an `info` object are supported.

Files use readable UTF-8 JSON with a format marker (`ptz-control-camera-settings`), a schema `version` (currently `1`), an `exportedAt` timestamp, `nextId`, and an ordered `cameras` array. Limits and presets stay nested under their camera. The file format version is separate from the app’s internal preferences version. Imports validate the whole file before saving, including unique IDs in 1–255, valid addresses and ports, limits, presets, and the eight-camera maximum. Invalid files, unsupported versions, and canceled dialogs keep the saved setup intact. Files larger than 1 MB are rejected.

## App preferences and camera settings storage

Camera configurations are saved locally for the current OS user through Flutter's [`shared_preferences`](https://pub.dev/packages/shared_preferences/versions/2.5.6) plugin. The app saves all cameras together as one JSON object containing the ordered `cameras` array and a `nextId` counter under the Dart key `ptz.cameras.v2`; the stored preference key includes Flutter's default prefix: **`flutter.ptz.cameras.v2`**.

Each camera entry contains its integer ID (1–255), name (`name`), IP address (`host`), destination port (`port`), packet format (`transport`), local UDP port (`localPort`), and locally saved preset names and snapshots (`presets`). Measured travel limits, when saved, are nested under `limits`: `panMin`, `panMax`, `tiltMin`, `tiltMax`, `zoomMin`, and `zoomMax`, in camera-native position units. Retrieved device information is optional and nested under `info`: `manufacturer`, `model`, `serialNumber`, `macAddress`, and `sourceHost` (the IP queried). Existing settings files without `info` still load. These details supplement the app’s integer camera ID; they do not change camera IDs or selection. The save/load code is in [`lib/services/camera_store.dart`](lib/services/camera_store.dart).

New cameras receive sequential IDs beginning at 1. The counter survives deletion and restarts; after assigning 255, vacant IDs can be reused. Editing or reordering cameras never changes their IDs. Drag the handles on **Your cameras** to change the saved order used by every **Selected camera** dropdown. Reordering preserves the currently selected camera and its connection. The eight-camera limit still applies.

On first load, the app migrates the original `ptz.cameras.v1` camera array to the new format, assigning IDs in its existing order while preserving every camera’s network settings, limits, and presets. The original preference remains as a backup.

Interface options such as navigation placement, movement mode, speed selections, and debug-console visibility currently reset on launch; they are not saved as preferences. Camera configurations and local preset metadata survive app restarts. Use **Export** and **Import** to transfer camera configurations between devices. Presets stored in the camera remain in the camera.

The locations below reflect the current application identifiers and dependency versions. Files are created when settings are first saved; changing an application identifier or Windows company/product metadata can change the location.

### macOS

The app uses `UserDefaults` in its sandbox. Preferences are stored at:

```text
~/Library/Containers/com.ptz.ptzControl/Data/Library/Preferences/com.ptz.ptzControl.plist
```

Here, `~` is your home folder. In Finder, choose **Go → Go to Folder** and enter the containing folder. The camera JSON is the string value of `flutter.ptz.cameras.v2` in the property list. To view it in Terminal:

```sh
plutil -extract 'flutter\.ptz\.cameras\.v2' raw \
  ~/Library/Containers/com.ptz.ptzControl/Data/Library/Preferences/com.ptz.ptzControl.plist \
  | python3 -m json.tool
```

### Windows

Preferences are stored in a JSON file under the current user's roaming AppData folder:

```text
%APPDATA%\com.ptz\ptz_control\shared_preferences.json
```

Paste `%APPDATA%\com.ptz\ptz_control` into File Explorer's address bar to open the folder. The `com.ptz` and `ptz_control` directories come from the executable's `CompanyName` and `ProductName` in `windows/runner/Runner.rc`. Inside the preferences file, `flutter.ptz.cameras.v2` holds the camera setup as a JSON-encoded string.

### iOS

The app uses `UserDefaults` inside its private app data container:

```text
<app-data-container>/Library/Preferences/com.ptz.ptzControl.plist
```

On a device, the data container is typically `/var/mobile/Containers/Data/Application/<UUID>`; the UUID is assigned by iOS and can change. The camera JSON is stored under `flutter.ptz.cameras.v2`. This private directory is not exposed in the Files app. For a development build, inspect the app's data container through Xcode's **Devices and Simulators** window. Simulator installations have their own separate data containers.

### Android

The app uses Android `SharedPreferences`, stored in its private app data directory:

```text
/data/user/0/com.ptz.ptz_control/shared_prefs/FlutterSharedPreferences.xml
```

This is the usual path for the primary Android user; other users or work profiles have a different user number. `/data/data/com.ptz.ptz_control/shared_prefs/FlutterSharedPreferences.xml` is a common equivalent path for the primary user. The XML string entry named `flutter.ptz.cameras.v2` contains the camera JSON. The file is private to the app; inspect a debuggable installation with Android Studio's **Device Explorer** or `adb shell run-as com.ptz.ptz_control`. The current app uses the legacy `SharedPreferences` API, so these settings are in this XML file rather than Android DataStore.

### Linux

Preferences are stored under `$XDG_DATA_HOME`, which defaults to `~/.local/share`:

```text
~/.local/share/com.ptz.ptz_control/shared_preferences.json
```

If `XDG_DATA_HOME` is set, replace `~/.local/share` with that directory. The current path provider uses the application ID `com.ptz.ptz_control`; for compatibility, it can reuse an existing older directory named after the executable, `~/.local/share/ptz_control/`, when the application-ID directory does not yet exist. Inside `shared_preferences.json`, `flutter.ptz.cameras.v2` holds the camera setup as a JSON-encoded string.

## Controls

- With **Move until stopped** unchecked (the default), hold any of eight arrows to pan/tilt and release to stop. Enable the checkbox above the direction pad to start continuous movement with a click; use the center Stop button to stop. Clicking another direction stops the previous move and starts the new direction. Turning the checkbox off stops the active move. Keyboard Space/Enter and assistive activation respect the selected mode.
- Enable **OSD navigation** on Control to operate the camera's on-screen menu on its video output. This stops active movement, changes the four cardinal arrows to single menu actions, and replaces the center Stop button with **Enter**. **Menu / Back** replaces Home; use it to open the menu and back out of nested selections until the menu closes. Diagonals, camera selection, refresh, speeds, lens controls, movement options, iris, and preset controls are disabled in this mode. The app does not show a video preview or track whether the camera's menu is open: enabling or disabling the checkbox sends no menu toggle. Close the camera menu before returning to PTZ control. Status inquiries, including automatic pan, tilt, and zoom polling, pause while OSD navigation is enabled. The connection timeout is also suspended during this intentional silence. Turning the checkbox off resumes polling, refreshes the displayed camera settings, and restores your control selections. Changing pages or selecting/reconnecting a camera resets the local OSD mode without sending a menu toggle. Each OSD arrow sends its direction packet, waits for acknowledgement, pauses for 100 milliseconds, then sends a pan/tilt stop packet using the same fixed speeds (`81 01 06 01 0E 0E 03 03 FF`). The total interval between direction and stop includes acknowledgement time plus the 100 ms pause. Errors, timeouts, focus loss, and camera changes bypass the pause and stop immediately. Menu / Back and Enter do not send a stop. OSD buttons ignore holds and keyboard repeats and stay disabled until the complete direction/stop action finishes; focus loss and camera changes also stop a pending directional action. Commands use the [PTZOptics OSD packets](https://docs.ptzoptics.com/resources/visca-api/osd/), with fixed navigation speeds independent of the PTZ speed selections; support and Menu / Back behavior must be verified on your camera model.
- Only one movement runs at a time. Dragging outside, cancelling a press, focus loss, app backgrounding, tab changes, and camera changes stop movement.
- Direction-pad motion queries pan/tilt before starting and every 250 ms while moving. Saved camera limits block outward movement and stop each axis independently on diagonals. Repeated unchanged replies detect camera end stops when no limits have been saved. Missing or invalid position replies stop the move.
- Speeds: pan **1–24** (`01–18` hex), tilt **1–20** (`01–14`), zoom/focus **0–7** (`00–07`). These are dropdowns to enforce valid ranges. A lens speed of zero means the slowest variable speed; it does not mean stop.
- The center pad button sends **Stop all movement** (pan/tilt, zoom, and focus). A separate home icon below the direction pad sends **Home**. Stops preempt waiting requests and cancel unsent motion commands and preset recalls.
- Use the **link icon between Pan and Tilt** to synchronize their speed dropdowns. Both use the shared range **1–20** while linked; enabling sync clamps an existing pan speed above 20 to 20. Disabling sync restores independent controls and pan’s full 1–24 range.
- Pan and Tilt share the top speed row. Below them, the Zoom and Focus dropdowns each have two hold buttons to their right. Zoom uses minus/plus magnifying glasses, with a smaller minus icon; focus uses the supplied eye-profile SVG artwork for near and far, with white shapes and transparent eye detail. The **Autofocus** checkbox above the Focus dropdown switches the camera between automatic and manual focus. Autofocus disables the Focus speed dropdown and near/far buttons; unchecking it enables them after the camera confirms manual mode. The mode can also be set on **Image**.
- **Aperture / iris** sits below Focus with close (−) and open (+) buttons and the camera's raw iris value. The buttons are enabled only in Manual and Iris priority exposure modes. Entering Control reads the current iris value, and each adjustment reads it again after command completion.
- **Image** sends exposure mode, aperture/iris, shutter, gain, white balance, red/blue gain, and autofocus commands. Queried raw decimal values appear to the right of the aperture, shutter, gain, red gain, and blue gain step buttons; unavailable values show a dash. Triggering one-push white balance requires a Yes/Cancel confirmation. Select Manual or the appropriate priority mode before adjusting exposure, and Manual white balance before adjusting color gains. Mode dropdowns and the focus label show the queried camera settings.
- The overflow menu offers **Debug console**, **Navigation on left**, **Reconnect camera**, and help. The console keeps the latest 200 events with timestamps, command descriptions, camera endpoint, and complete TX/RX hex bytes, including Sony headers. Use the save icon to export the current events to a UTF-8 `.txt` file through the system save dialog. The export preserves console order (newest first) and uses full UTC timestamps. It captures the events present when Save is pressed, even if polling continues. Clear it or hide it at any time. It is hidden on launch.

## Presets

Each camera has nine preset buttons, initially numbered 1–9. They use the camera’s built-in VISCA preset memory. Button 1 maps to VISCA memory address 0, through button 9 at address 8. Display names and queried pan, tilt, zoom, and focus snapshots are stored locally with the camera’s configuration, along with iris when exposure saving is enabled in Manual mode.

- Move the camera to the desired shot. Enable **Save preset**, then press a preset button. Enter a name of up to **40 characters on two lines**, for example `2 Podium` / `Extra Wide`. **Save** queries the current pan, tilt, zoom, focus, and exposure mode, persists the local snapshot, then sends VISCA Memory Set and waits for camera completion. Saving replaces that preset in the camera. **Cancel** or **Escape** closes the dialog without sending a save command.
- The save dialog queries and displays **Exposure mode:** and **Aperture:** side by side above the name entry. In **Manual** mode it shows **“Exposure setting will be saved.”**; other modes show **“Exposure setting can only be saved for manual exposure.”** When **Save exposure with preset** is checked, the app also queries and saves iris in Manual mode. Other exposure and image settings remain subject to the camera’s own preset behavior.
- Uncheck **Save preset** to recall shots. Every preset button sends VISCA Memory Recall, even without a locally saved name, so presets configured outside this app can be recalled. The camera reports any unsupported or empty slots.
- The exposure checkbox reads **Save exposure with preset** while **Save preset** is checked and **Use exposure from preset** otherwise. It starts unchecked and retains its state when switching between save and recall. When checked during recall, the app waits for VISCA Memory Recall to complete, then sets iris to the locally saved value, if available.
- Recall waits up to 30 seconds for camera completion. Other camera controls are disabled during the operation; the center **Stop** remains available. Stop, changing tabs/cameras, or backgrounding the app interrupts a pending recall wait and sends movement stops. Position telemetry updates on the next five-second poll; recall does not trigger a full settings query.
- Existing name-only presets remain usable via camera memory; saved snapshots also survive configuration reloads. A failed inquiry or local storage write prevents the camera save. If the camera rejects the save, the app restores the previous local snapshot and reports the failure.

The memory commands and zero-based numbering follow the [Sony VISCA command list](https://pro.sony/support/res/manuals/5053/f48354480e724f0aef3d45d2e1eeab63/50531551M.pdf), preset commands on page 18.

The compact Control page places the refresh button next to camera selection and shows connection, exposure, and white balance status in a compact card. The nine presets and save controls remain visible in a 400 × 800 workspace with bottom navigation. Smaller windows, side navigation at narrow widths, and the optional debug console use scrolling as needed.

## Camera status and protocol limits

At startup, the app selects the first saved camera and queries its state. When the application resumes, it reconnects to the currently selected camera and refreshes its state, regardless of which page is open. The shared `PtzController` holds the queried `exposureMode`, `aperture` (iris), `autofocus` (`true` for Auto, `false` for Manual, `null` when unavailable), and `whiteBalanceMode`; all pages use the same controller and receive updates through its listeners.

The shared `panSpeed`, `tiltSpeed`, `zoomSpeed`, and `focusSpeed` fields are the app's selected movement speeds. The common [VISCA movement commands](https://docs.ptzoptics.com/resources/visca-api/movement/) include speeds in each movement request, and the documented [state inquiries](https://docs.ptzoptics.com/resources/visca-api/inquiries/) do not provide corresponding current-speed inquiries. These fields retain their app selections across resume and start at 8, 6, 3, and 3 on a fresh launch. Reading camera-side speed settings would require a documented extension for the specific camera model; a maximum-speed capability inquiry would not report the selected movement speed.

Selecting a camera opens its UDP socket and queries pan/tilt, zoom, focus mode, AE exposure mode, white balance mode, and the five raw image adjustment values. The status card shows the queried exposure and white balance names below the connection status. Missing replies show a dash, and unrecognized mode codes are shown as unknown with their hex code. Only pan/tilt and zoom positions are polled automatically, every five seconds. These five-second polls pause while a movement or preset operation is running and resume on the regular timer afterward. Direction-pad moves use their own pan/tilt limit monitoring while active. Exposure, white balance, focus mode, and raw image values are queried once on entering a page that displays them. Changing a setting waits for command completion and then queries only that setting; one-push white balance queries its mode and both affected color gains. Camera selection and the refresh button query all settings. Zoom, home, and preset recall commands do not trigger extra position or full-settings queries. **Connected** requires a valid VISCA reply from the configured camera address and port; sending a UDP datagram does not establish a connection. After fifteen seconds without replies, the UI shows **No response** and clears telemetry. A status refresh button and reconnect action are available.

Pan/tilt use signed 16-bit camera-native position units. Zoom is shown as its raw decimal position; the debug console still shows wire bytes in hexadecimal. Scaling these values into degrees or optical magnification requires a camera-specific profile. The app deliberately does not assume one universal conversion.

Requests are serialized, normally time out after 700 ms, and log camera errors. Movement commands complete from the client's perspective on ACK or completion; an ACK means accepted, not that a physical move has finished. Setting changes and preset operations wait for completion; one-push balance allows up to ten seconds, and preset operations allow up to thirty seconds. Raw VISCA has no transaction IDs: known inquiry reply lengths are matched, but delayed raw error/ACK replies cannot always be attributed to a particular command. Sony framing provides sequence matching. Delivery and stopping cannot be guaranteed over UDP, and an OS force-quit cannot reliably send a final stop. This version does not automatically retransmit movement commands.

Command support, speed limits, exposure values, and behavior vary by camera model. The common VISCA command set is implemented; model-specific controls can be added in the existing service/controller layers. Camera preset save/recall is covered by simulated-camera tests; verify their behavior with your camera model before operational use. Some cameras require local UDP port 52381 as well as destination port 52381, rather than an automatically assigned local port.

References: [Sony VISCA command list and IP protocol](https://pro.sony/support/res/manuals/E042/3230148ee903c204b912cca5c2c3f5aa/E0421001M.pdf), [PTZOptics movement commands](https://devs.ptzoptics.com/visca-api/movement/), [PTZOptics exposure commands](https://devs.ptzoptics.com/visca-api/exposure/).

## Code and checks

- `lib/models/camera.dart` and `camera_preset.dart`: validated camera configuration, transport choice, and local names and position/iris snapshots for camera memory presets.
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

Tests cover packet encoding/ranges, signed telemetry, configuration persistence and validation, raw/Sony local UDP peers, source filtering, stop priority, held-button cancellation, speed synchronization, two-line preset names and cancellation, camera-memory preset save/recall, manual-exposure messaging, legacy preset compatibility, position/iris snapshot persistence, conditional iris restoration, camera-save failures, local storage failures, interrupted recalls, five-second PTZ-only polling, scoped setting refreshes, and compact layouts with both navigation placements. The macOS debug app has been built and launched locally; other OS builds and physical-camera checks remain to be performed on their target hardware.
