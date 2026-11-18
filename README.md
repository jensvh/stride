# Stride

Talk to Claude Code on your own PC while you walk, hike or cycle, through Meta Ray-Ban Display glasses. You speak; Claude fetches the GitHub repository you name into an empty work folder and works there; the answer comes back as speech, short text and small graphics on the lens. Finished work goes back to GitHub as a pull request, after you approve it.

Proof of concept. Built for one developer and one PC.

```
 Glasses ── lens web app (cards, pinch, dictation) ──┐
                                                     ▼
 Glasses mic/speakers ─Bluetooth─ iPhone voice ──▶ Azure Web PubSub
                                  engine (planned)   ▲   group "up":   devices → PC
                                                     │   group "down": PC → devices
                              Windows PC: bridge ────┘
                              └─ Claude Agent SDK ─▶ C:\stride-work\<session>\<repo>
                                                     ▲ clone / pull request
                                                   GitHub (your repositories only)
```

| Folder | What it is |
|---|---|
| `bridge/` | Node service on the PC. Runs Claude Code in a work folder per session, clones and publishes your GitHub repositories for it, asks for approvals, keeps undo checkpoints, publishes state. |
| `lens/` | Web app that runs on the glasses. Renders the state, sends pinches and dictated prompts. |
| `protocol/` | The wire format (`schema.ts`), the relay client both sides use, and the fixtures the tests and the lens demo share. |
| `infra/` | Script that creates the Azure relay. |
| `spikes/ios-audio-probe/` | Throwaway iPhone app that tests the glasses' microphone, on-device speech recognition, temple taps and locked-phone behaviour. Has its own README with the install steps. |
| `ios/` | iPhone voice engine (not written yet). |

## Status

| Milestone | State |
|---|---|
| M0 Bridge, tested from the PC | Done |
| M0.5 Probe on the glasses, Azure relay | Ready to run; needs the glasses |
| M1 Dictate on the lens → Claude → answer on the glasses | Code done, tested in a desktop browser |
| M2 Lens cards, approve by pinch, graphics | Code done, tested in a desktop browser |
| M3 iPhone build pipeline and audio probe | Builds on GitHub; the probe waits for its test on the phone |
| M4–M5 iPhone voice engine, hands-free walk mode | Not started |

## Try it on the PC (no glasses, no Azure)

Needs Node 24, Git for Windows, a working `claude` login and a GitHub token per account (below).

```powershell
npm install
Copy-Item bridge/config.example.json bridge/config.json   # then put your GitHub login(s) in "github.accounts"
Copy-Item bridge/.env.example bridge/.env                 # then paste the token(s)
npm run bridge
```

The bridge checks the tokens at startup and logs `github <account>: ok` for each.

In a second terminal, play the device:

```powershell
npm run say -- "Get the stride repo and tell me what the bridge does"
npm run say -- --cmd status
npm run say -- "undo that"
```

### GitHub tokens

Create one per account in `github.accounts`, signed in to GitHub as that account: Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token (classic). Name it "Stride", pick an expiry, tick **repo**, generate, and paste it into `bridge/.env` as `GITHUB_TOKEN_<ACCOUNT>` (for an account `my-work` that is `GITHUB_TOKEN_MY_WORK`). If an organization uses single sign-on, click **Configure SSO** next to the token and authorize it.

A classic token is needed because a fine-grained token reaches the repositories of one owner only, and not the repositories other people share with you. Claude never sees the token: only the bridge uses it, to list your repositories, clone them and open pull requests. Revoke it on the same page to cut Stride off from GitHub.

Or use the lens in a browser:

```powershell
npm run lens          # serves http://localhost:5173
npm run pair          # prints a link that pairs the browser with the bridge
```

`http://localhost:5173/?demo=all` shows every lens screen side by side without a bridge.

## What you can say

| Say | Effect |
|---|---|
| "get the *name* repo" | Claude clones that repository into the work folder (or fetches the latest if it is already there) |
| "publish it" | Claude asks to push a new branch and open a pull request; you approve |
| anything else | goes to Claude |
| "stop" | interrupts Claude |
| "status" | what is running, or the last result |
| "repeat" | reads the last answer again |
| "undo that" | puts the files back to before the last task that changed them |
| "switch to *repo*" | moves the focus to another repository cloned in this session |
| "new session" | a fresh conversation in a new, empty work folder |
| "approve" / "deny, *instead do…*" | answers an approval request |

## Where Claude works

Every session gets an empty folder under `workRoot` (default `C:\stride-work`). Claude starts there and works only there:

- **Repositories come from GitHub only**, through the bridge's `get_repo` tool. It accepts the repositories your accounts own, those of organizations you belong to, and those shared with you. Any other public repository is refused.
- **Nothing else on the PC is reachable.** File tools and shell commands that point outside the work folder (absolute paths, `~`, `$HOME`, `..` climbing out) are refused before they run.
- **Claude has no GitHub credentials.** Its environment holds no tokens, the gh login is hidden and git's credential helper is off, so `git push`, `git clone` or `gh` cannot reach GitHub as you. Changes leave only through `publish`, which you approve.
- **Publish never touches the default branch.** It commits what is left, pushes a new branch (`stride/<title>`) without force, and opens a pull request.
- **Old folders are deleted** `keepDays` (default 7) after their last use. Only folders the bridge made are touched.

One limit: code from a repository that Claude runs, such as a test script or a build, runs with your Windows rights. The work folder keeps Claude's own reads and writes in, not what that code does. For a hard wall, run the bridge in a container or WSL, or use Claude Code's Windows sandbox.

## What Claude may do without asking

- Read and edit files in the work folder.
- Clone your repositories with `get_repo`, and commit, branch and stash locally.
- Run the commands on the allowlist: tests, builds, linters, read-only git (`bridge/src/session.ts`, plus `allow` in `config.json`).
- Everything else waits for you: a pinch on **Approve**, or the word "approve". A bare "yes" is ignored on purpose. No answer within `askTimeoutSeconds` counts as deny.
- A short list is never run remotely, even if approved: `git push`, `git clone`, `gh`, force-push, `git reset --hard`, `git clean`, deleting `.git`, and similar.

Only the work folder's Claude settings are loaded (it has none), so allow rules from your personal settings, or from a cloned repository's own `.claude` folder, cannot bypass the approval.

## Security model

Each device holds a relay token that can only publish to the `up` group and read `down`; the bridge is the only one that reads `up` and writes `down`. A stolen device token can therefore send prompts and answer approvals, but cannot impersonate your PC.

The GitHub tokens and the relay key live in `bridge/.env` and are used by the bridge only; they are removed from the environment Claude runs in.

Treat the pairing codes like a password. `npm run pair` again to renew them; regenerate the Web PubSub access key in Azure to cut off every device at once. While the lens dictates prompts (`lensCanPrompt: true`), its token travels inside the install link through the Meta AI app; switch that off once the phone handles voice.

## Going live on the glasses

First find out whether your glasses run web apps at all: set `"lensUrl"` in `bridge/config.json` to the Pages address and run `npm run pair -- --probe`. It writes a page with one QR code that installs the probe; no relay is needed for this check.

1. Create the relay: `./infra/webpubsub.ps1 -SubscriptionId <id>` shows the plan, `-Apply` creates it and writes `bridge/.env`.
2. Host the lens: pushing to `main` deploys `lens/` to GitHub Pages. In a fork, first set Settings → Pages → Source to "GitHub Actions".
3. In `bridge/config.json` set `"relay": "azure"` and `"lensUrl"` to the Pages address. Restart the bridge.
4. `npm run pair` writes a local page with QR codes. Scan **0. probe** first: it reports to `bridge/logs/lens.log` what the glasses' browser allows. Then scan **1. Glasses**.

The Meta AI app needs Developer Mode (Settings → App Info → tap the version five times) and glasses firmware v125 or newer.

## Logs

`bridge/logs/bridge.log` is the service log, `lens.log` holds what the glasses report (they have no console), and `walk-YYYY-MM-DD.md` is a readable record of each walk: what you said, what Claude answered, what you approved.

## Tests

```powershell
npm test          # 116 tests: routing, approvals, undo, relay permissions, repo matching, the work-folder guard, clone and publish against local stand-ins for GitHub
npm run typecheck
```
