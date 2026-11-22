# Building iPhone apps for Meta Ray-Ban Display glasses: a field guide

This guide is written for an agent (or a developer) who has to build an iPhone app for Meta Ray-Ban Display glasses with Meta's Wearables Device Access Toolkit (DAT). Everything in it was learned the hard way while building and testing a real app (Stride Lab, `spikes/stride-lab/` in this repo) on real glasses, then checked against Meta's sample apps and Meta's answers on their developer forum.

**How to use it**

1. Read [section 2, the rules of the glasses](#2-the-rules-of-the-glasses), and [section 10, the pitfalls](#10-pitfalls-we-hit-symptom--cause--fix), before writing any code.
2. Start from the skeleton in [section 6](#6-architecture-of-a-robust-app) and the recipes in [section 7](#7-recipes-per-capability). They compiled and ran on the glasses.
3. Never guess an API name. Check it against the toolkit's `.swiftinterface` files ([section 3.3](#33-read-the-real-api-never-guess)).
4. Plan for testing on the device from the first day ([section 11](#11-how-to-test)). CI can compile; only the glasses tell you whether it works.

**Verified with:** Meta Ray-Ban Display, glasses software 129.0.0.218.272, iPhone on iOS 27.2.1, DAT iOS 1.0.1, Xcode 26.6 on a GitHub Actions `macos-26` runner, Swift 5 language mode, free Apple ID sideloading, November 2026. Re-check the rules marked with a glasses software or SDK version when either changes.

---

## Contents

1. [What the glasses can do, by route](#1-what-the-glasses-can-do-by-route)
2. [The rules of the glasses](#2-the-rules-of-the-glasses)
3. [Toolchain without a Mac](#3-toolchain-without-a-mac)
4. [One-time setup](#4-one-time-setup)
5. [Info.plist: every key you need](#5-infoplist-every-key-you-need)
6. [Architecture of a robust app](#6-architecture-of-a-robust-app)
7. [Recipes per capability](#7-recipes-per-capability)
8. [Lens web apps (the other route)](#8-lens-web-apps-the-other-route)
9. [Talking to servers and to a PC](#9-talking-to-servers-and-to-a-pc)
10. [Pitfalls we hit: symptom → cause → fix](#10-pitfalls-we-hit-symptom--cause--fix)
11. [How to test](#11-how-to-test)
12. [Checklist before you ship](#12-checklist-before-you-ship)
13. [References](#13-references)

---

## 1. What the glasses can do, by route

There are three ways to reach the glasses. Pick by capability:

| Capability | Lens web app (runs on the glasses) | Native iPhone app with DAT | Plain Bluetooth (phone or PC) |
|---|---|---|---|
| Custom UI on the lens | Yes, HTML at 600×600 | Yes, `MWDATDisplay` cards (FlexBox, Text, Button, Image) | No |
| Neural Band / touchpad input | Yes, as arrow keys and Enter (focus navigation) | Yes, `MWDATInputs` events, and taps on display buttons | No |
| Camera video | No | Yes, `MWDATCamera` stream | No |
| Photos | No | Yes | No |
| Microphone | No (only the glasses' own dictation in a text field) | Yes, two routes: Bluetooth headset (HFP) via `AVAudioSession`, or audio on the DAT camera stream | Yes, Hands-Free profile (16 kHz mono) |
| Speech / sound out | `speechSynthesis` in the page | `AVSpeechSynthesizer` / `AVAudioEngine` over Bluetooth | Yes (A2DP, or HFP while the mic is on) |
| Media buttons (AVRCP) | n/a | Unreliable: one `pause` in all our runs | Not confirmed |
| Works with the phone locked | Not applicable (runs on the glasses) | Yes, with the right background modes (see [7.13](#713-screen-off-and-background)) | Yes |

**Measured on the device** (DAT 1.0.1, Bluetooth link, no Wi-Fi entitlement):

| What | Result |
|---|---|
| Session start | under 1 s once the glasses are connected |
| Camera, `.medium` + hvc1 | 504×896, 20–24 fps, first frame 1–2 s after `start()` |
| Camera, `.low` + hvc1, phone locked | 360×640 (low), 151–172 frames in 8 s |
| Photo (`capturePhoto(format: .jpeg)`) | 1080×1440 JPEG, 1.7–3.1 s |
| Display card `send()` | 30–110 ms (rarely up to 1.7 s) |
| HFP microphone | 16 kHz mono, peak ≈ 0.1 when talking, works with the phone locked |
| Camera-stream microphone | 16 kHz mono PCM, starts with the stream |
| Streaming STT over WebSocket (own server) | stream open 0.2–0.5 s, server time 130–520 ms per final |

---

## 2. The rules of the glasses

These are not bugs in your code; they are how the glasses and the toolkit behave. Every one of them broke something before we knew it. Your app must follow them by construction.

| # | Rule | What to do | Source |
|---|---|---|---|
| R1 | **Bringing up the Bluetooth headset microphone (HFP) while a DAT session is open ends the session** ("Session ended by device") or leaves the microphone silent. Glasses software bug; Meta says glasses release 130 fixes it, 129.x does not. | Change the HFP route only with no session open: close the session, wait 2 s, switch, wait ~1.5 s for the route to settle, then open sessions again. Opening a session with HFP already up worked fine. | [ios#342](https://github.com/meta/meta-wearables-dat-ios/issues/342) |
| R2 | **Dropping and re-making the HFP link repeatedly can make the glasses refuse sessions and streams** until they are switched off and on. Nothing in the SDK recovers it. | Don't flap HFP. Keep it up for a while after use (we use 2 minutes), release it only with no session open. After two refusals in a row, tell the user to power-cycle the glasses. | [ios#375](https://github.com/meta/meta-wearables-dat-ios/issues/375), [#292](https://github.com/meta/meta-wearables-dat-ios/issues/292) |
| R3 | **The back gesture closes your app on the glasses.** Apps can't receive it on real glasses: `InputsConfiguration(consumeBack: true)` only works in the Mock Device Kit. Afterwards `Display.state` can still say `.started` and `send()` still succeeds, but nothing shows on the lens. Only a **new session** brings your view back. | Put a Close button on every card. Assume a card older than a few seconds may be gone; to show it again, close the session and open a new one. | [ios#349](https://github.com/meta/meta-wearables-dat-ios/issues/349) |
| R4 | **While a camera stream runs, the glasses mute app sound**, even though `AVAudioSession.currentRoute` still names the glasses. Sometimes the sound doesn't come back after the stream (open bug). | Close the camera before speaking. Put the camera last in a guided flow. Offer "Reset audio" and a power-cycle hint. | [ios#358](https://github.com/meta/meta-wearables-dat-ios/issues/358), [#256](https://github.com/meta/meta-wearables-dat-ios/issues/256) |
| R5 | **One tap on the glasses pauses the session, a second tap resumes; tap-and-hold stops it.** | Show "paused", never restart while paused, close after a timeout (we use 30 s). SDK 1.1.0 adds `pause()`/`resume()`. | [ios#312](https://github.com/meta/meta-wearables-dat-ios/issues/312) |
| R6 | **Keep one session; don't restart a stopped stream.** Restarting a stopped stream can fail. | Between uses: `camera.stop()`, later `addCamera(config:)` again on the same session. At least 2 s between ending a session and creating the next. Cap retries. | [ios#292](https://github.com/meta/meta-wearables-dat-ios/issues/292), [#260](https://github.com/meta/meta-wearables-dat-ios/issues/260) |
| R7 | **The camera needs a faster link than the display.** Two links exist: the glasses' Wi-Fi (SoftAP; needs Apple's Hotspot Configuration and Access Wi-Fi Information entitlements, which a free Apple ID can't sign) and **Bluetooth Classic through ExternalAccessory**, which the toolkit only uses if the app declares `com.meta.ar.wearable` and the `external-accessory` background mode. Without a usable link the stream sits in `waitingForDevice` and fails `deviceNotConnected` after exactly 30 s. | Always declare the accessory protocol and background mode ([section 5](#5-infoplist-every-key-you-need)). Use hvc1 over Bluetooth. | [discussion #284](https://github.com/meta/meta-wearables-dat-ios/discussions/284), strings in the 1.0.1 binary |
| R8 | **`AutoDeviceSelector` picks its device asynchronously.** One created at the moment of a tap is still empty, and `createSession` fails `noEligibleDevice`. | Pick the device yourself (connected and worn first) and use `SpecificDeviceSelector(device:)`. | Meta's BirdSpotter sample |
| R9 | **`started` means the session exists, not that every capability can attach.** The camera waits for the glasses (`waitingForDevice`); display and inputs don't, and fail once if asked too early. | Retry `addDisplay()` / `addInputs()` (we retry every 0.75 s, up to 10 times). | BirdSpotter sample |
| R10 | **A raw (uncompressed) stream pauses when the app leaves the screen; hvc1 keeps flowing.** Raw also needs the Wi-Fi link. | Use hvc1. `VideoFrame.makeUIImage()` returns nil for hvc1; show frames with `AVSampleBufferDisplayLayer` and flush it after each photo. | DAT changelog 0.5.0, BirdSpotter, discussion #284 |
| R11 | **The white capture LED is on whenever the camera runs**, including a stream used only for audio. If it stays on after you stopped, or after the app was killed mid-stream, the glasses still hold the camera. | Confirm every stop; if a stop isn't confirmed, stop the session. After an unclean exit, tell the user: tap Stop in the Meta AI app or power-cycle the glasses. | [ios#318](https://github.com/meta/meta-wearables-dat-ios/issues/318), [#231](https://github.com/meta/meta-wearables-dat-ios/issues/231) |
| R12 | **Asking Inputs for every source takes the Neural Band away from your display buttons.** `sources` is not a filter: the glasses route those inputs to you instead of to the card. | Offer two modes: all sources (gesture test, custom handling) or frame-only sources (`.captouch, .captureButton, .actionButton`) while a card with buttons is shown. | BirdSpotter sample |
| R13 | **Inputs can't be stopped, only removed.** An ended inputs capability keeps its place until removed. | Cancel the reader and listener tokens, then `session.removeInputs()`. Attach a fresh one each time. | BirdSpotter sample |
| R14 | **The Meta AI app asks for permissions, and it can't while the phone is locked.** Two requests in a row can collide (`requestInProgress`, `requestTimeout`). | Ask one permission at a time, only with the app in front, before any locked-phone flow. Re-read the status after returning. A thrown error from `checkPermissionStatus` means "unknown / not connected", not "denied". | Observed; BirdSpotter |
| R15 | **When the glasses end a session they send no reason.** iOS reports `unexpectedError("Session ended by device")`; don't match on that text. | Log the link state at that moment: link up → the glasses ended it (back gesture, tap-and-hold, HFP); link down → transport. Drop everything and let the next user action open a new session. | [ios#301](https://github.com/meta/meta-wearables-dat-ios/issues/301) |
| R16 | **Calls end sessions** on some glasses software (CallKit and VoIP too). | Don't retry in a tight loop; wait for the user. | [ios#332](https://github.com/meta/meta-wearables-dat-ios/issues/332) |
| R17 | **Taking the glasses off / folding them** ends streams (`hingesClosed`) or the session. | Release the camera on `donState == .doffed`. | android#239, changelog 0.9.0 |

---

## 3. Toolchain without a Mac

### 3.1 Project from a recipe (XcodeGen)

No `.xcodeproj` in git; generate it on the CI runner from `project.yml`:

```yaml
name: MyGlassesApp
options:
  deploymentTarget:
    iOS: "17.2"            # DAT's minimum
packages:
  MWDAT:
    url: https://github.com/meta/meta-wearables-dat-ios
    exactVersion: 1.0.1     # pin it; see 4.2 before moving to 1.1.0
settings:
  base:
    SWIFT_VERSION: "5.0"    # Swift 6 strict concurrency = many extra build round trips
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  MyGlassesApp:
    type: application
    platform: iOS
    sources: [Sources]
    dependencies:
      - { package: MWDAT, product: MWDATCore }
      - { package: MWDAT, product: MWDATCamera }
      - { package: MWDAT, product: MWDATDisplay }
      - { package: MWDAT, product: MWDATInputs }
    scheme: {}
    info:
      path: Info.plist
      properties: { }       # see section 5 for the full list
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.myglassesapp
        TARGETED_DEVICE_FAMILY: "1"
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGNING_ALLOWED: NO   # signed later with the user's Apple ID
```

The toolkit's products: `MWDATCore`, `MWDATCamera`, `MWDATDisplay`, `MWDATInputs`, `MWDATMotion`, `MWDATSpeech`, `MWDATMockDevice`, `MWDATMockDeviceTestClient`. Inputs, Motion, Speech, photo capture and camera audio are marked experimental in 1.0.x: they work in Developer Mode and beta channels but can't be published yet.

### 3.2 Build on GitHub Actions (the only compiler)

```yaml
name: iPhone build
on:
  push:
    paths: ['ios-app/**', '.github/workflows/ios.yml']
  workflow_dispatch:
permissions: { contents: read }
jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 30
    defaults: { run: { working-directory: ios-app } }
    steps:
      - uses: actions/checkout@v7
      - run: sudo xcode-select -s /Applications/Xcode_26.6.app && xcodebuild -version   # pin Xcode
      - run: brew install xcodegen && xcodegen generate
      - run: xcodebuild -resolvePackageDependencies -project MyGlassesApp.xcodeproj -scheme MyGlassesApp -derivedDataPath build
      - name: Save the toolkit's API (every module's file has the same name: rename per module)
        run: |
          mkdir -p api
          find build/SourcePackages -name '*.swiftinterface' -path '*ios-arm64/*' ! -path '*simulator*' ! -name '*.private.swiftinterface' |
            while read -r f; do m=$(basename "$(dirname "$f")" .swiftmodule); cp "$f" "api/$m.swiftinterface"; done
      - uses: actions/upload-artifact@v7
        with: { name: api, path: ios-app/api }
      - name: Build without signing
        run: |
          set -o pipefail
          xcodebuild build -project MyGlassesApp.xcodeproj -scheme MyGlassesApp \
            -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" | tee build.log | grep -E 'error:|BUILD' || true
          grep -q 'BUILD SUCCEEDED' build.log
      - if: failure()
        run: grep -E 'error:' build.log | sort -u | head -200 > errors.txt || true
      - if: failure()
        uses: actions/upload-artifact@v7
        with: { name: errors, path: ios-app/errors.txt }
      - run: mkdir Payload && cp -R build/Build/Products/Release-iphoneos/MyGlassesApp.app Payload/ && zip -qry MyGlassesApp.ipa Payload
      - uses: actions/upload-artifact@v7
        with: { name: MyGlassesApp, path: ios-app/MyGlassesApp.ipa, if-no-files-found: error }
```

The loop: push → `gh run watch <id> --exit-status` → on failure `gh run download <id> --name errors` → fix → push. Swift reports all type-check errors of a module in one go, so a round usually fixes several.

### 3.3 Read the real API, never guess

Meta's repo carries the interfaces as plain text. Read them before writing a single toolkit call:

```sh
for m in Core Camera Display Inputs Speech Motion; do
  gh api -H "Accept: application/vnd.github.raw" \
    "repos/meta/meta-wearables-dat-ios/contents/MWDAT$m.xcframework/ios-arm64/MWDAT$m.framework/Modules/MWDAT$m.swiftmodule/arm64-apple-ios.swiftinterface?ref=1.0.1" \
    > MWDAT$m.swiftinterface
done
grep -v "ObjC_\|hashValue\|static func ==" MWDATDisplay.swiftinterface | less
```

Also read Meta's samples (`samples/BirdSpotter`, `samples/CameraAccess`, `samples/DisplayAccess` on `main`). BirdSpotter's `Data/Dat/DatGlassesSessionRepository.swift` explains most lifecycle rules in its comments.

Things that tripped the first build (all fixed by reading the interfaces):

- Display builders are **result builders**: one component per line, no array literals (`FlexBox { Text(...); Text(...) }`, not `{ [Text(...), Text(...)] }`).
- `TextStyle` is `.heading / .body / .meta` (no `.title`). `ButtonStyle` is `.primary / .secondary / .outline`.
- `Display.send(_:)` and `clearDisplay()` are `async throws`.
- `session.addInputs()` returns `Inputs?`; `session.addCamera(config:)` returns `Camera?`.
- Many calls use **typed throws** (`throws(DeviceSessionError)`). Compare errors with `(error as? DeviceSessionError) == .capabilityAlreadyActive`; that works whether the catch is typed or not.
- `AnyListenerToken` is a protocol; store `[any AnyListenerToken]` and **cancel** tokens (`await token.cancel()`); dropping them from an array doesn't stop the listener.

### 3.4 Signing and installing

The CI `.ipa` is unsigned. iOS needs it signed with the user's Apple ID:

- **Free Apple ID:** sign on Windows with Sideloadly, AltStore or Impactor (the user signs in; an agent never handles the Apple ID password). The app expires after 7 days. Free accounts can't sign Hotspot/Wi-Fi entitlements → the camera only works over Bluetooth Classic (R7), which is fine.
- **Paid account:** TestFlight, or a development profile with the Hotspot Configuration + Access Wi-Fi Information entitlements for the faster Wi-Fi camera link. An unsigned CI build embeds no entitlements; to use them you must sign in CI or ad-hoc sign with an entitlements file.
- The iPhone needs Developer Mode (Settings → Privacy & Security → Developer Mode) and the developer profile trusted (Settings → General → VPN & Device Management).
- Some signer installers are themselves unsigned; let the user decide whether to trust and run them.

### 3.5 Secrets never go into the CI build

On a public repository, build artifacts are downloadable by anyone signed in to GitHub. A key compiled into the app is a published key. Two safe ways to hand a key to the app:

1. **Add it to the downloaded `.ipa` locally, before signing.** A script reads the key from a git-ignored `.env` and writes a plist into the app bundle of a *copy* of the `.ipa`; the app moves it to the Keychain on first launch and only fills empty settings. Stride Lab's `spikes/stride-lab/configure-ipa.ps1` does this with .NET's `ZipArchive`, and verifies the result without printing the key.
2. **A deep link from a QR code** (`myapp://config?stt=<url>&key=<key>`) generated on the user's PC into a local file the user deletes after scanning.

Store keys with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they are readable while the phone is locked (background flows) but never sync.

---

## 4. One-time setup

### 4.1 On the phone and glasses

1. Meta AI app → Settings → App Info → tap the version number five times → **Developer Mode** on. In Developer Mode no Meta app ID or client token is needed.
2. Glasses paired and **connected** in the Meta AI app.
3. iPhone Developer Mode on; app installed and trusted.
4. In your app: register (opens the Meta AI app, user confirms, Meta AI calls back through your URL scheme).
5. Camera and microphone permissions are granted in the Meta AI app (it switches there and back). Users can revoke them under Meta AI → App connections.

### 4.2 Pick the DAT version deliberately

- 1.0.1 works with glasses software 129.x. **1.1.0 (2026-11-20)** appeared to need glasses software 130 when we checked, so we stayed on 1.0.1. It adds `DeviceSession.pause()/resume()`, `DeviceSessionError.notRegistered`, typed `StreamError.thermalHot/batteryLow/peakPowerLimit`, and shortens the photo timeout to 10 s; check the release notes for the minimum glasses software before upgrading.
- `Compatibility` on `Device` tells you `deviceUpdateRequired` / `sdkUpdateRequired`; show it, don't fight it.
- Only one Developer Mode registration exists at a time in Meta AI. A re-signed build with a different bundle ID counts as a different app.

---

## 5. Info.plist: every key you need

```yaml
UIBackgroundModes:
  - audio                  # mic, speech and STT socket keep running with the screen off
  - bluetooth-central      # DAT link
  - bluetooth-peripheral   # DAT link
  - external-accessory     # REQUIRED for the Bluetooth Classic camera link (R7)
  - processing
UISupportedExternalAccessoryProtocols:
  - com.meta.ar.wearable   # REQUIRED for the Bluetooth Classic camera link (R7)
NSMicrophoneUsageDescription: "…uses the microphone of your glasses."
NSBluetoothAlwaysUsageDescription: "Needed to connect to your Meta glasses."
NSBluetoothPeripheralUsageDescription: "Needed to connect to your Meta glasses."
NSLocalNetworkUsageDescription: "Needed to stream video from your Meta glasses."
NSBonjourServices: [ _bonjour._tcp ]
NSCameraUsageDescription: "…shows the camera of your glasses."
NSPhotoLibraryAddUsageDescription: "…can save photos taken with your glasses."
CFBundleDisplayName: My Glasses App            # Wearables.configure() fails without bundle name/version keys
CFBundleShortVersionString: $(MARKETING_VERSION)
CFBundleVersion: $(CURRENT_PROJECT_VERSION)
CFBundleURLTypes:
  - CFBundleURLName: myglassesapp
    CFBundleTypeRole: Editor
    CFBundleURLSchemes: [ myglassesapp ]
MWDAT:
  AppLinkURLScheme: myglassesapp://            # Meta AI calls back here
  Analytics:
    OptOut: true
  # Outside Developer Mode also: MetaAppID, ClientToken, TeamID (Wearables Developer Center)
UIFileSharingEnabled: true                     # logs/results visible in the Files app
LSSupportsOpeningDocumentsInPlace: true
```

`Wearables.configure()` throws `configurationError` when `CFBundleIdentifier`, `CFBundleDisplayName`/`CFBundleName`, `CFBundleShortVersionString` or `CFBundleVersion` is missing, which is easy to miss with a hand-written Info.plist.

---

## 6. Architecture of a robust app

The first versions of Stride Lab worked "once" and then got stuck: Stop needed two taps, cards never came back, sound vanished, the camera refused with its LED on. Every one of those came from missing structure, not from a single bug. This is the structure that fixed it.

### 6.1 One coordinator owns the toolkit

One `@MainActor final class Glasses: ObservableObject` owns `Wearables.shared`, the `DeviceSession`, the `Camera`, the `Display` and the `Inputs`. Views never call the toolkit. All state the UI shows is `@Published` on it.

**SwiftUI pitfall:** a view only redraws for objects it observes. If a view reads `lab.locked` where `locked` is computed from `glasses.busy`, and the view observes only `lab`, it won't redraw when `busy` changes. Its buttons then stay disabled until something else in `lab` changes. Observe the object that publishes (a small `ViewModifier` with `@EnvironmentObject var glasses` works).

### 6.2 One action at a time, with time limits

Every user action and every cleanup runs through a serial queue. Actions never interleave, each has a hard timeout, and resets can preempt:

```swift
/// Lets exactly one of several racers win.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

@MainActor
func waitUntil(_ seconds: Double, step: Double = 0.1, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end || Task.isCancelled { return condition() }
        try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
    }
    return true
}

/// Runs `op`; if it takes longer than `seconds` it is cancelled and abandoned,
/// so a hanging toolkit call can't block the app.
@MainActor
func finishes(within seconds: Double, _ op: @escaping @MainActor () async -> Void) async -> Bool {
    let worker = Task { @MainActor in await op() }
    return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
        let once = Once()
        Task { await worker.value; if once.claim() { done.resume(returning: true) } }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { worker.cancel(); done.resume(returning: false) }
        }
    }
}

// Inside the coordinator:
@Published private(set) var busy: String?
private var lastWork: Task<Void, Never>?
private var currentWorker: Task<Void, Never>?
private var queueGen = 0
private var busyID = UUID()

func run(_ label: String, timeout: Double = 30, preempt: Bool = false,
         _ work: @escaping @MainActor () async -> Void) {
    if preempt { queueGen += 1; currentWorker?.cancel() }   // resets drop waiting work
    let gen = queueGen
    let previous = preempt ? nil : lastWork
    lastWork = Task { @MainActor [weak self] in
        await previous?.value
        guard let self, gen == self.queueGen else { return }
        let id = UUID(); self.busyID = id; self.busy = label
        let worker = Task { @MainActor in await work() }
        self.currentWorker = worker
        let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = Once()
            Task { await worker.value; if once.claim() { done.resume(returning: true) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() { worker.cancel(); done.resume(returning: false) }
            }
        }
        if !finished { self.say("“\(label)” took more than \(Int(timeout)) s and was stopped. Use Reset if it stays stuck.") }
        if self.busyID == id { self.busy = nil; self.currentWorker = nil }
    }
}
```

Don't use a `TaskGroup` for the timeout: a group waits for all children, and `await worker.value` doesn't react to cancellation, so the timeout would never fire.

### 6.3 Typed phases, shown on screen

```swift
enum Phase: Equatable { case off, starting, on, paused, stopping; case failed(String) }
@Published private(set) var sessionPhase: Phase = .off
@Published private(set) var cameraPhase: Phase = .off
// display.phase, display.inputsPhase, audio.running …
```

Show them as a status strip on every screen (coloured dots: registered · glasses connected · session · camera · card · gestures · headset mic), plus the running action and the last event in one line of plain text.

### 6.4 Generation guards: ignore late callbacks

Toolkit callbacks arrive on its own threads and can arrive after you stopped something. Give every camera, display and inputs instance a number; bump it when you open or close; drop callbacks with an old number. This fixed "Stop needs two taps": a late `streaming` from the old stream flipped the button back.

```swift
private var cameraGen = 0
// when opening:
cameraGen += 1
let gen = cameraGen
cameraTokens.append(stream.statePublisher.listen { [weak self] state in
    Task { @MainActor in self?.streamStateChanged(state, gen: gen) }
})
// handler:
private func streamStateChanged(_ state: StreamState, gen: Int) {
    guard gen == cameraGen else { return }   // from an older stream: ignore
    // …
}
// when closing: cameraGen += 1 before anything else
```

### 6.5 Confirmed teardown, in Meta's order

Close in this order, wait for each confirmation with a time limit, escalate when one doesn't come:

1. **Inputs:** cancel the event reader and tokens → `session.removeInputs()`.
2. **Display:** `try? await display.clearDisplay()` (2 s limit) → `display.stop()` → wait for `.stopped` (2 s) → cancel tokens.
3. **Camera:** bump the generation → cancel tokens → `camera.stop()` (cascades to stream and photo and detaches the camera) → wait for `camera.state == .stopped` (3 s). **Not confirmed → stop the session**, which releases the camera on the glasses (LED off).
4. **Session:** `session.stop()` → wait for `.stopped` (3 s) → drop every handle regardless of the answer.

After step 4 nothing is held, whatever the glasses said. Teardown cascades parent → child, not child → parent.

### 6.6 Session lifecycle

- **Reuse one session** for all features while it is healthy (`session.state == .started`). The next action only opens a new session if there is none, it is stopped, or the display needs a fresh one (R3).
- **Open:** registered? → device listed? → link `.connected` (wait up to 5 s after launch: the link fills in after the device is listed) → compatibility OK → at least 2 s since the last session ended → `createSession(deviceSelector: SpecificDeviceSelector(device: id))` → subscribe `stateStream()` and `errorStream()` **before** `start()` → `start()` → wait up to 15 s for `.started`.
- **Retry once** on `noEligibleDevice` / `sessionAlreadyExists`, then stop and say why. Count refusals; after two in a row show "switch the glasses off and on".
- **`.paused`:** show it, don't restart anything, close after 30 s.
- **`.stopped` that you didn't ask for:** drop camera/display/inputs handles, log the link state (R15), tell the user the next action opens a new session. **No automatic reopen loop.**
- **Idle:** close a session nobody used for a minute.
- **Error stream** is informational; let the state stream end things. `datAppOnTheGlassesUpdateRequired` → tell the user to update in Meta AI.

### 6.7 Watch the device, react on transitions

Subscribe per device to `addLinkStateListener`, `addCompatibilityListener` and `addDeviceStateListener`, and re-subscribe whenever `devicesStream()` emits. Re-read the properties in each callback; `Device` fills in asynchronously. React only on transitions:

- connected → not connected with a session open: close the session.
- donned → doffed with the camera open: close the camera (R17).
- registration lost: close the session; show "register again".

Prefer the device that is connected **and** worn, then connected, then compatible.

### 6.8 Two sound modes, never mixed

- **Voice:** HFP up (headset mic, speech to text, spoken output with mic open).
- **Quiet:** HFP down (the camera-stream microphone can be used; output via A2DP).

Switching mode = close the session first (R1) → 2 s → switch → 1.5 s settle → sessions may open again. HFP is never switched on as a side effect (`say()` must not start the mic). Keep HFP for 2 minutes after the last use, release it only with no session open (R2).

### 6.9 Every screen cleans up after itself

- `onDisappear` of a feature screen stops what it started: camera, camera-stream mic, inputs, card, STT socket, speech. Keep the session for the next screen.
- Starting a feature first closes what conflicts with it: speech closes the camera (R4), camera-mic switches to Quiet, the HFP mic switches to Voice.
- A photo opens the camera if needed and closes it again afterwards, so the LED doesn't stay on.

### 6.10 App lifecycle

- **Screen off / background:** close nothing if your app is meant to work in a pocket (hvc1 camera, display, inputs and HFP keep working; see [7.13](#713-screen-off-and-background)). If it isn't, end the session on `didEnterBackground` like Meta's CameraAccess sample.
- **App swiped away:** `UIApplication.willTerminateNotification` arrives on the main queue; do a synchronous shutdown inside `MainActor.assumeIsolated { … }`. There is no time to await answers: remove inputs, stop display, stop camera, stop session, close sockets, deactivate the audio session with `.notifyOthersOnDeactivation`, clear Now Playing info so media buttons and sound go back to other apps.
- **Killed without warning:** keep a marker in `UserDefaults` listing what is open (session, camera, card, gestures, headset mic), updated on every phase change. On the next launch, if the marker is there, start clean and tell the user what was left open and how to clear the LED (R11).

```swift
center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
    MainActor.assumeIsolated { self?.shutdownNow() }
}

func shutdownNow() {                       // synchronous on purpose
    stt.stop()
    if let s = session {
        if inputsOpen { try? s.removeInputs() }
        display?.stop()
    }
    camera?.stop()
    session?.stop()
    audio.stop()                           // setActive(false, options: .notifyOthersOnDeactivation)
    UserDefaults.standard.removeObject(forKey: "openAtExit")
}
```

### 6.11 A way out of every stuck state

A Reset menu on every screen, each entry preempting the queue:

| Entry | Does |
|---|---|
| Stop everything | STT off, speech off, close inputs/display/camera/session, release HFP. Keeps the registration. |
| Reset glasses connection | Stop everything → 2 s → open a session to prove it works. |
| Reset audio | Close the session (R1) → release HFP → 1.5 s. Comes back on when needed. |
| Full reset | All of the above, plus clear on-screen lists and refusal counters. |

Plus banners with the fix: not registered · glasses not connected · glasses keep refusing → power-cycle · app was closed while the camera was on.

### 6.12 Logging

Write every state change and decision to a file in Documents (visible in Files with `UIFileSharingEnabled`) and offer **Share full log** (all runs, not just this one). Log: app version, iOS version, registration state, device link/compatibility/don/battery, every session/camera/display/inputs state, every error, every sound-mode switch with the reason, permission answers, app foreground/background/lock/unlock, and measured numbers (first-frame size, fps, photo ms, send ms, mic peak and buffer count). Count high-rate events (Neural Band drag) instead of logging each one.

---

## 7. Recipes per capability

All snippets are simplified from Stride Lab 0.4.x, which compiled against DAT 1.0.1 and ran on the glasses.

### 7.1 Configure, register, handle the callback

```swift
import MWDATCore
import SwiftUI

@main
struct MyApp: App {
    @StateObject private var glasses: Glasses
    init() {
        do { try Wearables.configure() } catch { print("Wearables.configure failed: \(error)") }  // once, before anything else
        _glasses = StateObject(wrappedValue: Glasses())
    }
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(glasses)
                .onOpenURL { url in glasses.handle(url) }   // Meta AI returns through AppLinkURLScheme
        }
    }
}

// In Glasses:
private let wearables = Wearables.shared

init() {
    Task { [weak self] in
        guard let self else { return }
        for await state in self.wearables.registrationStateStream() {
            self.registered = state == .registered      // unavailable / available / registering / registered
        }
    }
    Task { [weak self] in
        guard let self else { return }
        for await ids in self.wearables.devicesStream() { self.watchDevices(ids) }
    }
}

func register() {
    guard !registered else { say("Already registered."); return }      // "already registered" is a success (ios#307)
    run("registering") {
        do { try await self.wearables.startRegistration() }
        catch { self.say("registration failed: \(error)") }
    }
}

func handle(_ url: URL) {
    Task { _ = try? await wearables.handleUrl(url) }
}
```

### 7.2 Pick the device and open a session

```swift
private func preferredDevice() -> Device? {
    let found = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
    func rank(_ d: Device) -> Int {
        if d.linkState == .connected && d.donState == .donned { return 0 }
        if d.linkState == .connected { return 1 }
        if d.compatibility() == .compatible { return 2 }
        return 3
    }
    return found.min { rank($0) < rank($1) }
}

private func openSession() async -> DeviceSession? {
    guard registered, let device = preferredDevice(), device.linkState == .connected else { return nil }
    let gap = 2 - Date().timeIntervalSince(lastSessionEnd)              // R6
    if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
    sessionGen += 1
    let gen = sessionGen
    do {
        let s = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device.identifier))  // R8
        session = s
        sessionTasks.append(Task { [weak self] in
            for await state in s.stateStream() {
                guard let self, self.sessionGen == gen else { return }
                self.sessionStateChanged(state)          // .paused / .stopped handling, see 6.6
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await error in s.errorStream() {
                guard let self, self.sessionGen == gen else { return }
                self.say("session error: \(error)")
            }
        })
        try s.start()
        _ = await waitUntil(15, step: 0.2) { s.state == .started || s.state == .stopped }
        return s.state == .started ? s : nil
    } catch {
        lastSessionEnd = Date()
        return nil
    }
}
```

### 7.3 Camera stream over Bluetooth, with a preview

```swift
import MWDATCamera

let config = StreamConfiguration(
    videoCodec: VideoCodec.hvc1,                     // fits Bluetooth, survives the background (R7, R10)
    audioCodec: nil,                                 // or .pcm(sampleRate: .rate16000, numberOfChannels: 1), see 7.6
    resolution: .medium,                             // .low 360×640, .medium 504×896, .high 720×1280 (Wi-Fi)
    frameRate: 24)
guard let camera = try session.addCamera(config: config) else { /* no camera on this session */ return }
cameraGen += 1
let gen = cameraGen
let stream = camera.stream
// Subscribe BEFORE start().
cameraTokens.append(stream.statePublisher.listen { [weak self] s in Task { @MainActor in self?.streamStateChanged(s, gen: gen) } })
cameraTokens.append(stream.errorPublisher.listen { [weak self] e in Task { @MainActor in self?.streamFailed(e, gen: gen) } })
cameraTokens.append(stream.videoFramePublisher.listen { [weak self] frame in
    Task { @MainActor in self?.gotFrame(frame, gen: gen) }          // VideoFrame is Sendable
})
cameraTokens.append(stream.photoDataPublisher.listen { [weak self] photo in
    let image = UIImage(data: photo.data)
    Task { @MainActor in self?.gotPhoto(image, gen: gen) }
})
stream.start()
_ = await waitUntil(15, step: 0.2) { self.cameraGen != gen || self.cameraPhase == .on }  // .on when .streaming arrives
```

`StreamState`: `waitingForDevice → starting → streaming`, plus `paused`, `stopping`, `stopped`. Ignore a `stopped` before the stream ever started. An unasked `stopping/stopped` or any `StreamError` → run the full camera close (6.5) through the queue. Map `thermalHot`, `batteryLow`, `peakPowerLimit`, `hingesClosed`, `permissionDenied` to plain messages; count `videoStreamingError`, `deviceNotConnected`, `timeout` as refusals.

hvc1 frames can't become a `UIImage` (`makeUIImage()` returns nil). Show them with a sample-buffer layer:

```swift
import AVFoundation
import CoreMedia

@MainActor
final class FramePreview {
    let layer = AVSampleBufferDisplayLayer()
    init() { layer.videoGravity = .resizeAspect }

    func show(_ buffer: CMSampleBuffer) {
        // Show each frame on arrival instead of at its timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(buffer)
    }

    /// Call after every photo, or the picture freezes.
    func flush() { layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) }
}

struct FramePreviewView: UIViewRepresentable {
    let preview: FramePreview
    func makeUIView(context: Context) -> LayerView { let v = LayerView(); v.hosted = preview.layer; return v }
    func updateUIView(_ view: LayerView, context: Context) {}
    final class LayerView: UIView {
        var hosted: CALayer? { didSet { oldValue?.removeFromSuperlayer(); if let hosted { layer.addSublayer(hosted) } } }
        override func layoutSubviews() { super.layoutSubviews(); hosted?.frame = bounds }
    }
}
```

First-frame size for the log: `CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(frame.sampleBuffer)!)`.

### 7.4 Photo

```swift
// The stream must be .streaming. If you opened the camera just for the photo, close it afterwards.
photoAskedAt = Date()
guard camera.stream.capturePhoto(format: .jpeg) else { say("the glasses refused the request"); return }
let got = await waitUntil(12, step: 0.1) { self.photoCount != before }   // gotPhoto() increments photoCount
preview.flush()
```

`Camera.photo` (separate high-quality still capture, experimental) also exists; stream photos were enough here (1080×1440).

### 7.5 Microphone A: the Bluetooth headset (HFP)

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])  // .allowBluetoothHFP = the old .allowBluetooth
try session.setActive(true)
if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
    try? session.setPreferredInput(glasses)
}
// A fresh AVAudioEngine per start: after a route change an old one can keep the previous mic's format.
engine = AVAudioEngine()
let mic = engine.inputNode
let format = mic.outputFormat(forBus: 0)                 // 16 kHz mono from the glasses
guard format.sampleRate > 0, format.channelCount > 0 else { return }
let pcm16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
converter = AVAudioConverter(from: format, to: pcm16k)
mic.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in self?.received(buffer) }
engine.prepare()
try engine.start()
```

- Check `session.currentRoute.inputs.first?.portType == .bluetoothHFP` and show it: "not listening through the glasses" is the most common silent failure.
- Handle `routeChangeNotification`, `.AVAudioEngineConfigurationChange` (restart the engine), `interruptionNotification` (restart after `.ended`) and `mediaServicesWereResetNotification` (rebuild everything).
- Stop: remove the tap, stop the engine, `setActive(false, options: .notifyOthersOnDeactivation)`, `MPNowPlayingInfoCenter.default().nowPlayingInfo = nil`.
- Count buffers in a test window: "0 buffers" (iOS stopped the mic) and "buffers of silence" (the glasses sent zeros, R1) need different fixes.
- A backgrounded app can't *start* recording; start the mic while the app is in front.
- Never switch HFP with a session open (R1, R2).

### 7.6 Microphone B: audio on the camera stream

```swift
// Needs the DAT microphone permission (asked in Meta AI) and Quiet mode (HFP down).
let config = StreamConfiguration(videoCodec: VideoCodec.hvc1,
                                 audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: 1),
                                 resolution: .low, frameRate: 24)
// … addCamera as in 7.3, then:
cameraTokens.append(stream.audioFramePublisher.listen { [weak self] audio in
    let buffer = audio.pcmBuffer                         // AVAudioPCMBuffer, 16 kHz mono
    let (level, rate) = meter.add(buffer)                // compute off the main thread
    Task { @MainActor in self?.gotAudio(level: level, rate: rate, gen: gen) }
})
```

Meta's notes: this audio isn't beamformed like HFP, is experimental, and works in the development and beta channels only. It keeps the camera (and its LED) on. Only ask for audio on the stream when the microphone permission is known to be granted: a stream asked for audio without the grant may not come up at all.

### 7.7 Speech and sound out

```swift
let synth = AVSpeechSynthesizer()          // keep one instance, set a delegate
func say(_ text: String) {
    guard audioRunning else { log("speech skipped: the sound is off"); return }   // never start HFP as a side effect
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice(language: "en-US")
    speaking = true
    synth.speak(u)
}
// delegate: didStart → log the output route; didFinish and didCancel → speaking = false
```

Beeps: an `AVAudioPlayerNode` on the same engine, connected to `mainMixerNode` with a 44.1 kHz mono format. Close the camera before speaking (R4). In a guided flow, wait for `speaking == false` before the next step.

### 7.8 Cards on the lens

```swift
import MWDATDisplay   // no SwiftUI import in this file: MWDATDisplay has its own Text, Button, Image

private func card(title: String, body: String) -> FlexBox {
    FlexBox(direction: .column, spacing: 16, alignment: .start, crossAlignment: .start) {
        Text(title, style: .heading, color: .primary)
        Text(body, style: .body, color: .secondary)
        ButtonGroup(alignment: .start) {
            Button(label: "Yes", style: .primary, onClick: { [weak self] in
                Task { @MainActor in self?.chose("Yes") }
            }).actionRole(.primary)                      // gets the focus first
            Button(label: "No", style: .secondary, onClick: { [weak self] in
                Task { @MainActor in self?.chose("No") }
            })
            Button(label: "Close", style: .outline, onClick: { [weak self] in   // instead of the back gesture (R3)
                Task { @MainActor in self?.closePressed() }
            })
        }
    }
}

// Attach with patience (R9):
for attempt in 1...10 {
    do {
        let display = try session.addDisplay()
        displayGen += 1
        let gen = displayGen
        displayTokens.append(display.statePublisher.listen { [weak self] s in
            Task { @MainActor in self?.displayStateChanged(s, gen: gen) }
        })
        display.start()
        if await waitUntil(5, { display.state == .started }) { self.display = display; break }
        display.stop()
    } catch {
        if (error as? DeviceSessionError) == .capabilityAlreadyActive { /* only a new session helps */ break }
    }
    try? await Task.sleep(nanoseconds: 750_000_000)
}
try await display.send(card(title: "Hello", body: "Pick with the Neural Band."))
```

Showing a card reliably (R3):

1. A card shown less than ~10 s ago on a started session: send the new view in place.
2. Otherwise, if a card was shown earlier in this session and nothing else (camera, inputs) uses the session: **close the session and open a new one**, then attach the display. It takes about 3 s and is the only thing that brings the view back after a back gesture.
3. If the camera or inputs use the session: restart the display on the same session (stop, add again) and accept that it may not come back.
4. `capabilityAlreadyActive` from `addDisplay()` → new session.

Every send replaces the whole screen; button callbacks belong to the most recent view. Clear with `try await display.clearDisplay()`, then `display.stop()`.

### 7.9 Gestures (Inputs)

```swift
import MWDATInputs

let sources: Set<InputSource> = withCard
    ? [.captouch, .captureButton, .actionButton]                            // band stays with the card (R12)
    : [.captouch, .neuralBand, .captureButton, .actionButton, .neuralBandDrag]
guard let inputs = try session.addInputs(configuration: InputsConfiguration(sources: sources, consumeBack: true)) else { return }
inputsGen += 1
let gen = inputsGen
inputsTokens.append(inputs.statePublisher.listen { [weak self] s in Task { @MainActor in self?.inputsStateChanged(s, gen: gen) } })
inputsReader = Task { [weak self] in
    for await event in inputs.events {                   // single reader only
        guard let self, gen == self.inputsGen else { return }
        switch event {
        case .nav(let direction, let source, _): self.log("swipe \(direction) (\(source))")
        case .select(let source, _): self.log("select (\(source))")
        case .back(let source, _): self.log("back (\(source))")          // never arrives on hardware (R3)
        case .button(let type, let source, _): self.log("button \(type) (\(source))")
        case .capture(let type, let source, _): self.log("capture \(type) (\(source))")
        case .drag: self.drags += 1                                       // dozens per gesture: count, don't log
        }
    }
}
// Stop (R13):
inputsGen += 1; inputsReader?.cancel(); for t in inputsTokens { await t.cancel() }
try? session.removeInputs()
```

Observed on Ray-Ban Display + Neural Band: swipe up/down/left/right, select (pinch), drag (down/move/up), capture button short press. `InputsState`: `inactive → activating → active`; an `inactive` after `active` means the glasses dropped it (usually the session ended).

### 7.10 Permissions

```swift
private func allowed(_ permission: Permission, ask: Bool) async -> Bool {
    let status: PermissionStatus
    do { status = try await wearables.checkPermissionStatus(permission) }
    catch { return false }                                  // "not connected", not "denied"
    if status == .granted { return true }
    guard ask, UIApplication.shared.applicationState == .active else { return false }   // R14
    for attempt in 1...2 {
        do {
            let answer = try await wearables.requestPermission(permission)   // switches to Meta AI and back
            _ = await waitUntil(5, step: 0.2) { UIApplication.shared.applicationState == .active }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let now = (try? await wearables.checkPermissionStatus(permission)) ?? answer
            return now == .granted
        } catch {
            if (error as? PermissionError) == .requestInProgress, attempt == 1 {
                try? await Task.sleep(nanoseconds: 2_000_000_000); continue
            }
            return false
        }
    }
    return false
}
// Before any locked-phone flow, with the app in front:
_ = await allowed(.camera, ask: true)
try? await Task.sleep(nanoseconds: 1_500_000_000)
_ = await allowed(.microphone, ask: true)
```

`PermissionError` raw values: 0 noDevice, 1 noDeviceWithConnection, 2 connectionError, 3 metaAINotInstalled, 4 requestInProgress, 5 requestTimeout, 6 internalError.

### 7.11 Media buttons (AVRCP)

`MPRemoteCommandCenter` targets (play, pause, togglePlayPause, next, previous) plus Now Playing info while the audio session is active: in all our iPhone runs **a single `pause` arrived** (probably a tap on the frame); swipes and Neural Band gestures never did. Don't build on media commands; use `MWDATInputs` for gestures. Clear Now Playing info when you stop, so the glasses' media controls go back to other apps.

### 7.12 Streaming speech to text

A generic client for a WebSocket STT server that takes 16 kHz, 16-bit mono PCM and returns JSON (`partial`, `final`, `error`):

```swift
final class SttClient: ObservableObject {
    @Published private(set) var partial = ""
    @Published private(set) var finals: [String] = []
    private var task: URLSessionWebSocketTask?
    private var buffer = Data()
    private let lock = NSLock()

    func start(base: String, key: String) {
        stop()
        let wss = base.replacingOccurrences(of: "https://", with: "wss://")
        var request = URLRequest(url: URL(string: wss + "/v1/stream")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")   // never put a key in the URL
        let t = URLSession.shared.webSocketTask(with: request)
        task = t
        t.resume()
        receive(t)
        t.sendPing { error in /* no open callback exists: the ping answer means "open" */ }
    }

    /// Audio thread: send about 100 ms (3200 bytes) per frame.
    func feed(_ pcm: Data) {
        lock.lock(); buffer.append(pcm)
        let chunk: Data? = buffer.count >= 3200 ? buffer : nil
        if chunk != nil { buffer = Data() }
        lock.unlock()
        if let chunk { task?.send(.data(chunk)) { _ in } }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            if case .success(let message) = result {
                if case .string(let text) = message,
                   let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    let words = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                    DispatchQueue.main.async {
                        switch json["type"] as? String {
                        case "partial": self.partial = words
                        case "final": self.partial = ""; if !words.isEmpty { self.finals.append(words) }
                        default: break
                        }
                    }
                }
                self.receive(t)
            }
        }
    }

    func stop() { task?.cancel(with: .normalClosure, reason: nil); task = nil }
}
```

Convert the HFP tap buffers to 16 kHz Int16 with `AVAudioConverter` and pass them to `feed`. Measured end to end with the phone locked: finals 130–520 ms after speech ends.

### 7.13 Screen off and background

With the background modes from [section 5](#5-infoplist-every-key-you-need), started while the app was in front, then the phone locked (results from a full guided run):

| Feature | Phone locked |
|---|---|
| HFP microphone + engine tap | works (must be started in front) |
| WebSocket STT | works |
| Spoken output | works; muted while the camera runs (R4) |
| Display cards + Neural Band picks | works |
| Inputs (gestures) | works |
| Camera hvc1 `.low` | works, about 19–21 fps |
| Photo | works, 1.7–3.1 s |
| Permissions | can't be asked (R14) |
| Starting HFP recording | not allowed from the background |

---

## 8. Lens web apps (the other route)

Meta Web Apps run on the glasses themselves (Chromium). They are the fastest way to custom UI and need no Apple signing.

- **Viewport 600×600, additive display:** black is transparent, light colours are ink. Large text (20–24 px), one accent colour.
- **Input:** the Neural Band moves focus like arrow keys, a pinch is Enter/click (Chromium spatial navigation). Use real `<button>`s and a visible focus style. A desktop browser has no spatial navigation; add an arrow-key fallback for testing.
- **Dictation:** focusing a text field opens the glasses' own dictation. **No microphone or camera API:** Meta's docs reserve those for DAT.
- **Speech:** `speechSynthesis` works.
- **Install:** a manifest at `/.well-known/meta-wearables-manifest.json` (`version`, `name`, `description`, `appearance.theme_color`, `appearance.icon`) and an install deep link `fb-viewapp://web_app_deep_link?appName=<enc>&appUrl=<enc>`. **Encode the whole app URL**: the Meta AI app keeps the query string only when it is encoded.
- **No console on the glasses:** send logs over your own socket to a PC.
- Keep the first load small (Meta's docs at the time named a 300 KB limit); write your own small relay client instead of pulling a large SDK.
- A WebSocket survived a minute of display sleep in our test; plan for reconnects anyway and send a state snapshot on reconnect.
- Web Apps were available in Belgium, where the glasses aren't sold, with Developer Mode on.

---

## 9. Talking to servers and to a PC

- **Phone ↔ PC:** a managed relay both sides connect to outbound (we used Azure Web PubSub: per-device tokens, separate "up" and "down" groups so a device can't impersonate the PC, ~100–180 ms round trip). Don't open ports on a home PC.
- **Glasses as a PC microphone:** pair the glasses with Windows over Bluetooth; they show up as a 16 kHz Hands-Free headset. Over Remote Desktop the session only sees microphones when the RDP client plays audio on the remote computer (`audiomode:i:1`); otherwise it has none.
- **Keys:** keep them on the side that owns them. A dev server can proxy the STT server and add the `Authorization` header from a git-ignored `.env`, so pages never see the key.
- **Corporate networks** (for example TLS-inspecting proxies) can reset connections to self-hosted servers. Test on another network before debugging your code.
- **Network changes** (Wi-Fi → mobile data while walking): reconnect sockets on failure with backoff; don't assume a socket survives.

---

## 10. Pitfalls we hit: symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| Every session fails `noEligibleDevice`; buttons "do nothing" | `AutoDeviceSelector` created at the tap is still empty (R8); failures only logged | `SpecificDeviceSelector` on the preferred device; show every failure on screen |
| Camera stuck in `waitingForDevice`, fails `deviceNotConnected` after exactly 30 s | No usable high-bandwidth link: Bluetooth Classic not declared, Wi-Fi entitlements missing (R7) | `UISupportedExternalAccessoryProtocols: com.meta.ar.wearable` + `external-accessory` background mode; hvc1 |
| Camera works but the picture is blank | `makeUIImage()` returns nil for hvc1 | `AVSampleBufferDisplayLayer` (7.3) |
| Preview freezes after a photo | Layer not flushed | `flush()` after each photo |
| "Session ended by device" right when the mic starts | HFP came up during a session (R1) | Switch sound mode only with no session open |
| Mic level ~0.001 after using the camera-stream mic | HFP and stream audio mixed (R1) | Two sound modes, never mixed |
| No app sound after using the camera | Glasses mute app audio during a stream; may not recover (R4) | Close the camera before speaking; camera last; Reset audio / power-cycle |
| Card shows once; after the back gesture never again, although `send()` succeeds | The back gesture closed the app on the glasses (R3) | Close button on every card; reopen on a new session |
| Gestures arrive once, then the button does nothing | Old inputs listener on a dead session; code returned early because "a listener exists" | Always remove and re-attach; drop handles when the session ends |
| Stop needs two taps | Late callback from the old stream flipped the state back | Generation guards (6.4) |
| LED stays on; every later camera start fails `videoStreamingError` | Stream error never cleaned up; camera half open | Any stream error → full confirmed close; unconfirmed → stop the session; after two refusals ask for a power-cycle |
| Paused stream, then errors | A tap on the glasses paused the session (R5) | Show paused; never restart while paused |
| Microphone permission `requestTimeout` | Asked right after the camera request, or with the phone locked (R14) | One request at a time, app in front, before locking |
| Buttons stay grey after an action until you leave the screen | View observed `Lab`, the busy flag lived on `Glasses` (6.1) | Observe the publishing object |
| `Register` while registered → error with a garbage code | `startRegistration()` called when already registered | Check `registrationState` first; treat "already registered" as success |
| Registration dropped after reinstalling | One Developer Mode registration at a time; a re-signed build can count as a new app | Re-check on foreground, offer Register again |
| First CI build: dozens of API errors | API written from docs and memory | Read the `.swiftinterface` files first (3.3) |
| CI API dump contained one module only | Every module's interface has the same file name | Rename per module when copying |
| `display.clearDisplay()` "async call in a function that does not support concurrency" | `clearDisplay` and `send` are `async throws` | Call from a `Task`, await, `try?` |
| Array literal in `FlexBox { [...] }` fails to compile | Result builder | One component per line |
| Key would have shipped in a public CI artifact | Building secrets into the app in CI | Inject locally before signing, or QR deep link (3.5) |
| STT server unreachable from the office | TLS-inspecting proxy resets the connection | Test on another network |
| Glasses mic missing on a Windows PC over RDP | RDP doesn't redirect the remote PC's mic unless audio plays on the remote computer | `audiomode:i:1` |
| A commit included unrelated staged files | `git commit` takes the whole index | Commit with a pathspec (`git commit -- path/`) |

---

## 11. How to test

1. **Build a test app before the real app.** One screen per capability, each with numbered steps, the buttons that run it, what the app measured, and the tester's verdict (works / partly / fails). It answers "what can we use" in an afternoon and gives the real app a proven base.
2. **Round 1, screen on:** every capability by hand.
3. **Round 2, screen off:** a guided, narrated flow. Ask permissions first with the screen on, bring the sound mode up before any session, tell the tester to lock the phone, then speak each step through the glasses and take answers from cards on the lens. Put the camera last (R4) and ask afterwards whether sound came back.
4. **Log everything to a file** and offer "Share results" (a text report) and "Share full log" (every run). Read the log, not just the verdicts: the timestamps showed the HFP/session clash (two session ends in the same second as "audio on").
5. **Measure in the app:** first-frame size, fps over 2 s, photo ms, send ms, mic peak and buffer count per window, STT server ms, and where the app was (front / background / locked).
6. **Edge cases to run every time:** back gesture on a card, one tap on the glasses during a stream, glasses taken off during a stream, leaving each screen while its feature runs, Reset entries while something runs, swiping the app away during a stream (LED must go off; other audio apps must play), a second run of round 2 straight after the first.
7. **Know what CI can't tell you:** background audio, Bluetooth routes, gestures, LED, the glasses' own behaviour. Only the device can.

---

## 12. Checklist before you ship

- [ ] Info.plist has the accessory protocol, `external-accessory`, `audio`, both Bluetooth modes, the usage strings, `MWDAT.AppLinkURLScheme`, bundle name and version keys.
- [ ] `Wearables.configure()` runs once at launch; `onOpenURL` passes callbacks to `handleUrl`.
- [ ] All toolkit calls go through one coordinator and one serial queue with timeouts.
- [ ] Every camera, display and inputs instance has a generation guard.
- [ ] Teardown is confirmed in order (inputs → display → camera → session); an unconfirmed camera stop stops the session.
- [ ] One session, `SpecificDeviceSelector`, 2 s between sessions, one retry, no reopen loops, idle close.
- [ ] `.paused` and unasked `.stopped` are handled and shown.
- [ ] HFP only changes with no session open; never flaps; never starts as a side effect.
- [ ] Every card has a Close button; reopening uses a new session.
- [ ] Inputs are removed, not just forgotten; drag events are counted.
- [ ] The camera is closed before speech; leaving a screen closes what it opened; a photo closes the camera it opened.
- [ ] Permissions are asked one at a time, in front, before locked flows.
- [ ] `willTerminate` releases everything synchronously; an unclean-exit marker explains leftovers on the next launch.
- [ ] Status strip and Reset menu on every screen; banners say what to do.
- [ ] Logs are written to a file and can be shared.
- [ ] No keys in the repository or in CI artifacts.

---

## 13. References

- Toolkit (iOS): https://github.com/meta/meta-wearables-dat-ios (interfaces in the `.xcframework` folders, `CHANGELOG.md`, `samples/BirdSpotter`, `samples/CameraAccess`, `samples/DisplayAccess`)
- Toolkit (Android): https://github.com/meta/meta-wearables-dat-android (same rules apply to the glasses side)
- Developer docs: https://wearables.developer.meta.com/docs/develop/ (Web Apps: https://wearables.developer.meta.com/docs/develop/webapps)
- Forum issues cited above: [ios#342](https://github.com/meta/meta-wearables-dat-ios/issues/342) HFP ends sessions · [#375](https://github.com/meta/meta-wearables-dat-ios/issues/375) refusals after HFP re-links · [#349](https://github.com/meta/meta-wearables-dat-ios/issues/349) back gesture · [#358](https://github.com/meta/meta-wearables-dat-ios/issues/358) / [#256](https://github.com/meta/meta-wearables-dat-ios/issues/256) sound muted during streams · [#312](https://github.com/meta/meta-wearables-dat-ios/issues/312) tap pauses · [#292](https://github.com/meta/meta-wearables-dat-ios/issues/292) / [#260](https://github.com/meta/meta-wearables-dat-ios/issues/260) keep one session · [#318](https://github.com/meta/meta-wearables-dat-ios/issues/318) / [#231](https://github.com/meta/meta-wearables-dat-ios/issues/231) LED · [#301](https://github.com/meta/meta-wearables-dat-ios/issues/301) no end reason · [#332](https://github.com/meta/meta-wearables-dat-ios/issues/332) calls · [#307](https://github.com/meta/meta-wearables-dat-ios/issues/307) already registered · [discussion #284](https://github.com/meta/meta-wearables-dat-ios/discussions/284) Bluetooth Classic camera with a free Apple ID
- Working code: `spikes/stride-lab/Sources/` in this repo (`Glasses.swift` coordinator, `GlassesDisplay.swift` cards and inputs, `Audio.swift` HFP and speech, `Preview.swift` hvc1 preview, `Lab.swift` sound modes, cleanup, guided screen-off round, shutdown), `.github/workflows/ios.yml`, `spikes/stride-lab/configure-ipa.ps1`.
