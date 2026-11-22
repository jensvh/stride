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

## Known limits of this first version

- The toolkit's exact Swift API was not available on a Mac while writing; the first CI builds fix any names that differ (the CI job saves the toolkit's interfaces as the `StrideLab-api` artifact).
- High-resolution video over Wi-Fi needs Apple's Hotspot entitlement, which a free Apple ID can't sign. The camera test uses the low resolution (360×640), which streams over Bluetooth.
- The screen-off round starts with the screen on and keeps going after you lock. If iOS suspends the app, the log shows the gap and the remaining steps fail. That is a finding, not a bug.
