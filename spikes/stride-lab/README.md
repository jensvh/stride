# Stride Lab

One iPhone app that finds out what Meta Ray-Ban Display glasses can do with your iPhone. It walks you through every test step by step: first with the phone in your hand, then again with the screen off and the phone in your pocket. In that second round the app tells you through the glasses what to do.

| Test | What it checks | How |
|---|---|---|
| 1. Connect the glasses | Registration with the Meta AI app, glasses found, a device session | Device Access Toolkit (DAT) |
| 2. Glasses microphone | The glasses' microphone reaches the app: name, sample rate, level | Bluetooth headset (HFP) |
| 3. Speech to text | Live text from your own STT server, with server time | `/v1/stream` WebSocket |
| 4. Speech and sound | Spoken text and a tone come out of the glasses | iPhone speech synthesis over Bluetooth |
| 5. Live camera | Video frames from the glasses, with frame rate | DAT camera stream |
| 6. Take a photo | A photo from the glasses, with how long it took | DAT photo capture |
| 7. Custom UI on the display | A card with Yes/No buttons on the lens; your pick arrives on the phone | DAT display |
| 8. Gestures | Glasses inputs (touchpad, Neural Band) and media buttons (taps) | DAT inputs, iOS remote commands |

Round 2 (screen off) runs tests 2–8 in about three minutes. You lock the phone, and the glasses tell you each step: talk after the beep, say a sentence, pick Yes or No on the lens, look around, hold still, then tap and pinch for ten seconds. When you unlock, every test shows what worked, with the numbers it measured. **Share results** gives a text report to paste into a chat or send to the PC.

## What you need

- Meta Ray-Ban Display glasses, connected to the Meta AI app (app version V292 or newer is safest; this build uses toolkit 1.0.1).
- **Developer Mode** in the Meta AI app: Settings → App Info → tap the version number five times. Stride Lab uses Developer Mode, so no Meta app ID is needed.
- An iPhone with iOS 17.2 or newer, and Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode).
- For test 3: your STT server's address and key in `bridge/.env` on the PC (`STT_URL`, `STT_API_KEY`).

## Install

GitHub Actions builds an unsigned `StrideLab.ipa` on every push that touches `spikes/stride-lab/`:

```powershell
gh run download --repo jensvh/stride --name StrideLab --dir spikes\stride-lab\build-out
```

An unsigned app has to be signed with your Apple ID before iOS installs it. Without a Mac that means a signing tool on Windows (Sideloadly, AltStore or Impactor), or a paid Apple developer account and TestFlight. With a free Apple ID the app works for 7 days, then needs signing again.

### Put your STT server in the app before signing (optional)

The CI build never contains your STT key: the repository and its build artifacts are public. To have the app ready with your server on first launch, add the address and key on your own PC, before signing:

```powershell
powershell -ExecutionPolicy Bypass -File spikes\stride-lab\configure-ipa.ps1
```

It reads `STT_URL` and `STT_API_KEY` from `bridge/.env` and writes `build-out\StrideLab-configured.ipa` next to the original. Sign and install that file instead. It holds your key: copy it only to the PC that signs it, and delete it once the app is installed. On first launch the app moves the key into the iPhone's Keychain.

## Before you start

1. If you did not configure the .ipa: on the PC, `npm run pair -- --lab`. Open the page it writes and scan the code with the iPhone camera. Stride Lab opens and stores the STT address and key (in the Keychain). Delete the page afterwards: it contains the key.
2. Open Stride Lab, go to **1. Connect the glasses**, tap **Register with the Meta AI app** and allow Stride Lab there.

## Results

The results are saved on the phone (Files → On My iPhone → Stride Lab → `stride-lab-results.json`), next to the full log `stride-lab.log`.

## Rules of the glasses

Found while testing and confirmed on Meta's developer forum. Stride Lab follows them; any app for these glasses has to.

| Rule | What Stride Lab does | Source |
|---|---|---|
| Bringing up the Bluetooth headset microphone (HFP) while a toolkit session is open ends the session or leaves the microphone silent. A glasses software bug, fixed in glasses release 130. | The headset microphone only changes with no session open: switching closes the session first, waits 2 s, then switches. | [ios#342](https://github.com/meta/meta-wearables-dat-ios/issues/342) |
| After the headset link is dropped and re-made a few times, the glasses can refuse sessions and streams until they are switched off and on. | The headset microphone stays on for 2 minutes after use instead of going on and off. After two refusals in a row the app asks you to restart the glasses. | [ios#375](https://github.com/meta/meta-wearables-dat-ios/issues/375) |
| The back gesture closes the app on the glasses; apps can't catch it on real glasses. Only a new session brings a card back. | Every card has a Close button. Show card reopens on a new session when the last card is more than 10 s old. | [ios#349](https://github.com/meta/meta-wearables-dat-ios/issues/349) |
| While a camera stream runs, the glasses mute app sound; it may not come back afterwards. | Speech closes the camera first; round 2 puts the camera last and asks whether you can still hear it. | [ios#358](https://github.com/meta/meta-wearables-dat-ios/issues/358), [#256](https://github.com/meta/meta-wearables-dat-ios/issues/256) |
| One tap on the glasses pauses a session, a second tap resumes, tap-and-hold stops it. | Shows "paused", never restarts while paused, closes the session after 30 s paused. | [ios#312](https://github.com/meta/meta-wearables-dat-ios/issues/312) |
| Keep one session; between uses stop the camera and add it again. Don't restart a stopped stream. Leave at least 2 s between sessions. | One shared session, `camera.stop()` and a fresh camera each time, 2 s gap, one retry. | [ios#292](https://github.com/meta/meta-wearables-dat-ios/issues/292), [#260](https://github.com/meta/meta-wearables-dat-ios/issues/260) |
| The white LED is on while the camera streams. If it stays on after stopping, or after the app was killed mid-stream, the glasses still hold the camera. | Every stop is confirmed; an unconfirmed stop closes the session. After a kill, the next launch tells you to tap Stop in Meta AI or restart the glasses. | [ios#318](https://github.com/meta/meta-wearables-dat-ios/issues/318), [#231](https://github.com/meta/meta-wearables-dat-ios/issues/231) |
| Asking for every gesture takes the Neural Band away from a card's buttons. | Two gesture modes: everything to the phone, or frame gestures only with the band left to the card. | Meta's BirdSpotter sample |

## When something gets stuck

Every screen shows what is open (registration, glasses, session, camera, card, gestures, headset microphone) and has a **Reset** menu:

- **Stop everything**: closes the camera, card, gestures, session and headset microphone. Keeps the registration.
- **Reset glasses connection**: stop everything, wait, open a new session to prove it works.
- **Reset audio**: closes the session, releases the headset microphone; it comes back when a test needs it.
- **Full reset**: all of the above, and clears the lists on screen.

If the glasses keep refusing (the app says so), switch them off and on with the power switch, then use Reset glasses connection.

Leaving a test stops what it started. Locking the phone closes nothing. Swiping the app away releases the camera, card, gestures, session and headset microphone, so the glasses and other apps are free again.

## Known limits of this first version

- The toolkit's exact Swift API was not available on a Mac while writing; the first CI builds fix any names that differ (the CI job saves the toolkit's interfaces as the `StrideLab-api` artifact).
- The camera needs a faster link than the display. The toolkit has two: the glasses' Wi-Fi (needs Apple's Hotspot capability, which a free Apple ID can't sign) and Bluetooth Classic, which it only uses when the app declares the `com.meta.ar.wearable` accessory protocol and the `external-accessory` background mode (Stride Lab does). Without a usable link the camera waits 30 seconds and fails with "not connected". Over Bluetooth the video is compressed (HEVC): the app shows it on a video layer, because the toolkit can't turn those frames into an image.
- Permissions for the toolkit's camera and microphone are asked in the Meta AI app, which can't show them while the phone is locked. The screen-off round asks for both before you lock the phone.
- The screen-off round starts with the screen on and keeps going after you lock. If iOS suspends the app, the log shows the gap and the remaining steps fail. That is a finding, not a bug.
