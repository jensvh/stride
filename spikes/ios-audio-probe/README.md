# iPhone audio probe

A throwaway app. It answers four questions that decide how the real iPhone app is built, and that only your iPhone and your glasses can answer:

1. Does the glasses' microphone reach an app over Bluetooth?
2. Does speech-to-text work on the iPhone itself, on that audio?
3. Does a tap on the glasses' temple reach the app?
4. Does it all keep running while the phone is locked in your pocket?

The app shows the four answers at the top and a log below. Nothing leaves the phone unless you pair it with your PC.

## Get the app file

Every push that touches this folder builds an unsigned `StrideProbe.ipa` on a GitHub Mac runner (workflow "iPhone build"). Fetch the newest one into the repository root:

```powershell
gh run download --repo jensvh/stride --name StrideProbe --dir .
```

## Install it from Windows (free Apple ID)

One-time setup on the PC:

1. Install **iTunes** and **iCloud** from apple.com. The Microsoft Store versions do not work with Sideloadly; uninstall those first if you have them.
2. Install **Sideloadly** from sideloadly.io.

Each install:

1. Connect the iPhone by USB and tap **Trust** on the phone.
2. Open Sideloadly, drag `StrideProbe.ipa` into it, fill in your Apple ID and press **Start**. Sideloadly asks for your password and sends it to Apple only.
3. On the iPhone: Settings → General → VPN & Device Management → tap your Apple ID → **Trust**. Developer Mode must be on (Settings → Privacy & Security → Developer Mode).

A free Apple ID signs an app for 7 days and allows 3 such apps at a time. Tick **Automatic refresh** in Sideloadly: its background service re-signs the app before it expires whenever the phone is reachable by USB or Wi-Fi. For Wi-Fi, enable "Sync with this iPhone over Wi-Fi" once in iTunes (device → Summary → Options).

## Run the test (about five minutes)

1. Put the glasses on and make sure they are connected to the iPhone.
2. Open **Stride Probe**, press **Start listening**, allow the microphone and speech recognition.
3. Say a sentence. The app repeats what it understood through the glasses.
4. Tap the temple once, then twice. Try the other gestures you use for music.
5. Lock the phone, put it in your pocket, and say three or four sentences a few seconds apart. Listen for the repeats.
6. Wait a minute in silence, then say one more sentence.
7. Unlock and read the four answers at the top.

Then send me the log: the share button at the top right, or pair with the PC first (scan code **2. iPhone** from `npm run pair`) and the log arrives in `bridge/logs/phone.log` by itself.

## What the answers mean for the real app

| Answer | Consequence |
|---|---|
| Microphone is "Bluetooth hands-free" and sound comes in | The voice engine can listen through the glasses as planned. |
| Speech to text works "on the phone itself" | No speech server needed for the default path. |
| Temple taps arrive | A tap can start and stop listening. Otherwise the lens pinch and the automatic listening window carry it. |
| Phone locked: microphone kept running, phrases understood | Hands-free walk mode works. If iOS pauses the app, the design changes to push-to-talk from the lens. |
