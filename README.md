# Stride

Talk to Claude Code on your own PC while you walk, hike or cycle, through Meta Ray-Ban Display glasses. You speak; Claude works in your repositories; the answer comes back as speech, short text and small graphics on the lens.

Proof of concept. Built for one developer and one PC.

```
 Glasses ── lens web app (cards, pinch, dictation) ──┐
                                                     ▼
 Glasses mic/speakers ─Bluetooth─ iPhone voice ──▶ Azure Web PubSub
                                  engine (planned)   ▲   group "up":   devices → PC
                                                     │   group "down": PC → devices
                              Windows PC: bridge ────┘
                              └─ Claude Agent SDK ─▶ your repositories
```

| Folder | What it is |
|---|---|
| `bridge/` | Node service on the PC. Runs Claude Code sessions through the Agent SDK, asks for approvals, keeps undo checkpoints, publishes state. |
| `lens/` | Web app that runs on the glasses. Renders the state, sends pinches and dictated prompts. |
| `protocol/` | The wire format (`schema.ts`), the relay client both sides use, and the fixtures the tests and the lens demo share. |
| `infra/` | Script that creates the Azure relay. |
| `ios/` | iPhone voice engine (not written yet). |

## Status

| Milestone | State |
|---|---|
| M0 Bridge, tested from the PC | Done |
| M0.5 Probe on the glasses, Azure relay | Ready to run; needs the glasses |
| M1 Dictate on the lens → Claude → answer on the glasses | Code done, tested in a desktop browser |
| M2 Lens cards, approve by pinch, graphics | Code done, tested in a desktop browser |
| M3–M5 iPhone voice engine, hands-free walk mode | Not started |

## Try it on the PC (no glasses, no Azure)

Needs Node 24, Git for Windows and a working `claude` login.

```powershell
npm install
Copy-Item bridge/config.example.json bridge/config.json   # then list your projects in it
npm run bridge
```

In a second terminal, play the device:

```powershell
npm run say -- "What does this project do?"
npm run say -- --cmd status
npm run say -- "undo that"
```

Or use the lens in a browser:

```powershell
npm run lens          # serves http://localhost:5173
npm run pair          # prints a link that pairs the browser with the bridge
```

`http://localhost:5173/?demo=all` shows every lens screen side by side without a bridge.

## What you can say

| Say | Effect |
|---|---|
| anything else | goes to Claude in the active project |
| "stop" | interrupts Claude |
| "status" | what is running, or the last result |
| "repeat" | reads the last answer again |
| "undo that" | puts the files back to before the last task that changed them |
| "switch to *project*" | changes the active project (names and aliases from `config.json`) |
| "new session" | starts a fresh conversation in the active project |
| "approve" / "deny, *instead do…*" | answers an approval request |

## What Claude may do without asking

- Read and edit files inside the project.
- Run the commands on the allowlist: tests, builds, linters, read-only git (`bridge/src/session.ts`, plus `allow` in `config.json`).
- Everything else waits for you: a pinch on **Approve**, or the word "approve". A bare "yes" is ignored on purpose. No answer within `askTimeoutSeconds` counts as deny.
- A short list is never run remotely, even if approved: force-push, `git reset --hard`, `git clean`, deleting `.git`, and similar.

Only project-level Claude settings are loaded, so allow rules from your personal settings cannot bypass the approval.

## Security model

Each device holds a relay token that can only publish to the `up` group and read `down`; the bridge is the only one that reads `up` and writes `down`. A stolen device token can therefore send prompts and answer approvals, but cannot impersonate your PC.

Treat the pairing codes like a password. `npm run pair` again to renew them; regenerate the Web PubSub access key in Azure to cut off every device at once. While the lens dictates prompts (`lensCanPrompt: true`), its token travels inside the install link through the Meta AI app; switch that off once the phone handles voice.

## Going live on the glasses

1. Create the relay: `./infra/webpubsub.ps1 -SubscriptionId <id>` shows the plan, `-Apply` creates it and writes `bridge/.env`.
2. Host the lens: pushing to `main` deploys `lens/` to GitHub Pages. In a fork, first set Settings → Pages → Source to "GitHub Actions".
3. In `bridge/config.json` set `"relay": "azure"` and `"lensUrl"` to the Pages address. Restart the bridge.
4. `npm run pair` writes a local page with QR codes. Scan **0. probe** first: it reports to `bridge/logs/lens.log` what the glasses' browser allows. Then scan **1. Glasses**.

The Meta AI app needs Developer Mode (Settings → App Info → tap the version five times) and glasses firmware v125 or newer.

## Logs

`bridge/logs/bridge.log` is the service log, `lens.log` holds what the glasses report (they have no console), and `walk-YYYY-MM-DD.md` is a readable record of each walk: what you said, what Claude answered, what you approved.

## Tests

```powershell
npm test          # 89 tests: routing, approvals, undo checkpoints, relay permissions, fixtures
npm run typecheck
```
