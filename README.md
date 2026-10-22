# SpinnerKey

SpinnerKey rotates your AI API keys on a schedule, so a leaked key stops working soon after it leaks.

It's a small native macOS app. You choose which keys to rotate and how often in a settings window. A per-user `launchd` job then issues new keys on that schedule, puts them into your tools, and revokes the old ones.

**Supported today:** OpenRouter keys, installed into OpenCode.
**Designed for more:** each provider (who issues keys) and each target (the tool that uses them) is a small plug-in. See [Extending](#extending).

## How a rotation works

```
 launchd (every 15 min, at login)
   └─ SpinnerKey rotate
        1. Revoke old keys whose grace period has passed
        2. Is a rotation due? If not, exit (no network calls)
        3. Create a new key with the OpenRouter management key (from Keychain)
        4. Record the new key's id as "revoke if we crash"
        5. Verify that the new key works
        6. Write it into OpenCode (~/.local/share/opencode/auth.json) atomically
        7. Mark it active and schedule the previous key for revocation
```

If any step fails, OpenCode keeps its previous working key and the new key is revoked. If revoking it fails too, the key stays queued and the next run revokes it. A failed rotation never leaves OpenCode broken and never leaves an unused key alive.

## Security model

| Concern | How SpinnerKey handles it |
|---|---|
| The management key (it can create keys) | Stored only in the macOS login Keychain. Marked this-device-only, so it never syncs to iCloud. The app never displays it again and never writes it to disk, logs, arguments or environment variables. |
| Newly issued API keys | Kept in memory only long enough to write them into the target tool. SpinnerKey's own files store key **ids** (hashes), never secrets. |
| Writing OpenCode's credentials | Writes a 0600 temp file (`O_EXCL`), fsyncs it, then renames it into place, so the file is never partly written or readable by others. Other providers' entries are preserved. A corrupt file is left untouched. |
| Network | HTTPS only, against a hard-coded `https://openrouter.ai` URL. Uses an ephemeral session (no cache, no cookies) and refuses redirects, so credentials can't be forwarded elsewhere. |
| Blast radius of a leaked key | Limited to one rotation interval plus the grace period. You can also set a credit cap on every issued key. |
| Revoking the wrong key | SpinnerKey only revokes keys it created itself and has recorded. |
| Attack surface | No server, no listening port, no helper running as root, no resident daemon, no third-party dependencies. The scheduler starts a short-lived process, which exits when done. |
| Logs | `~/Library/Logs/SpinnerKey/spinnerkey.log` (0600, capped at 1 MB). Anything that looks like a key is redacted. Error messages never include API response bodies. |
| Concurrency | A file lock stops a scheduled run and "Rotate now" from rotating at the same time. |

The management key is the most sensitive item. It can only manage keys, not call models, but anyone holding it could mint keys on your account. Treat it like a password. If you suspect it's exposed, delete it in the OpenRouter dashboard and paste a new one into SpinnerKey.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools with Swift 5.9 or later (`xcode-select --install`)
- An OpenRouter **management key** (OpenRouter → Settings → Management Keys)
- OpenCode configured to use OpenRouter (`opencode auth login`), or simply let SpinnerKey create the entry

## Install

```bash
git clone https://github.com/amoranio/spinnerkey.git
cd spinnerkey
./scripts/build-app.sh --install     # builds, signs ad-hoc, copies to /Applications
open /Applications/SpinnerKey.app
```

## Use

1. **Management key:** paste it, click **Save to Keychain**, then **Test**.
2. **What gets rotated:** leave *Rotate my OpenRouter API key* and *Update OpenCode* on. You can also set a credit limit per key.
3. **Schedule:** choose how often to rotate and when to revoke the previous key. A grace period lets running OpenCode sessions finish on the old key.
4. Click **Rotate now** once to check that everything works, then turn on **Automatic rotation**.
5. Delete the key you originally gave OpenCode in the OpenRouter dashboard. SpinnerKey never revokes keys it didn't create.

Running OpenCode sessions keep the key they started with. New sessions pick up the new key.

You can close the window. Rotation runs from `launchd`, not from the app.

### Command line

```bash
/Applications/SpinnerKey.app/Contents/MacOS/SpinnerKey status       # what's due, last error
/Applications/SpinnerKey.app/Contents/MacOS/SpinnerKey rotate-now   # rotate immediately
/Applications/SpinnerKey.app/Contents/MacOS/SpinnerKey rotate       # what the scheduler runs
```

### Files

| Path | Contents |
|---|---|
| Keychain → `com.spinnerkey` | Management key(s) |
| `~/Library/Application Support/SpinnerKey/config.json` | Your settings |
| `~/Library/Application Support/SpinnerKey/state.json` | Key ids, timestamps, pending revocations (no secrets) |
| `~/Library/LaunchAgents/com.spinnerkey.agent.plist` | The schedule (present only while automatic rotation is on) |
| `~/Library/Logs/SpinnerKey/` | Log |

### Notes

- **Keychain prompt after a rebuild:** the Keychain trusts the exact signed binary that saved the key. After you rebuild with an ad-hoc signature, macOS asks once whether SpinnerKey may read its key. Choose **Always Allow**. Signing with a stable `SIGN_IDENTITY` avoids this.
- **Moving the app:** if you move SpinnerKey.app, open it once so the scheduler points to the new location.
- **Uninstall:** turn off Automatic rotation, click Remove under the management key, then delete the app and `~/Library/Application Support/SpinnerKey`.

## Extending

Adding a provider (for example Anthropic or OpenAI) or a target (for example Claude Code, Cursor or a `.env` file) needs:

1. A case in `ProviderKind` or `TargetKind` (`Sources/SpinnerKeyCore/Config.swift`).
2. A type that implements `KeyProvider` (create, verify, revoke) or `KeyTarget` (install, restore).
3. One line in `Wiring.swift` to construct it.
4. A toggle in `ConfigView.swift`.

The rotation engine (`Rotator.swift`) doesn't change. Targets must write atomically and return a snapshot so that a failure in one target rolls back the others.

## Development

```bash
swift build
swift test
```

CI builds and tests on macOS for every push.
