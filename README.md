# claude-desktop-toolbox

A small menu app for Windows to run several Claude Desktop accounts and move chats between them.

## What it does

- **Set up extra accounts** — separate logins, each with its own window and Start Menu shortcut. Survives Claude updates.
- **Copy a chat into another account.**
- **Replace a chat** with another chat's history.
- **Restart an account window** so moved chats show up.
- **Export a chat** to Desktop or Downloads as readable text (`.md`) or raw data (`.jsonl`).
- **Import a chat** from a `.jsonl` file — auto-finds them on your Desktop and in Downloads.
- **Move a chat to the top** of the chat list — resurface an old chat without changing it.
- **Block Claude auto-updates** — stop the app from updating and relaunching itself. Undo from the same menu item.

## How it works

Each account keeps a small pointer file per chat. The real conversation is stored once and shared by all accounts, so copying a chat is instant and never touches the original.

Claude reads its chat list only when an account starts, so a moved chat appears after you restart that account window. The app can do that for you.

## Blocking auto-updates

Claude Desktop updates itself in the background and force-installs after about 72 hours, which relaunches the app. With several accounts that is worse than an interruption: every account's windows close at the same moment, and the extra ones often fail to come back up. So once more than one account exists, the menu says so and points at the option.

Blocking writes a single value, `disableAutoUpdates`, under `HKCU\SOFTWARE\Policies\Claude` — the policy the app itself reads at launch. With it set, the updater never starts, so nothing is downloaded and the force-install timer never arms. An update already downloaded before you block will still install once.

What you give up: security and compatibility fixes stop arriving on their own, so update by hand when you want to:

```
winget upgrade --id Anthropic.Claude
```

The same menu item undoes it. Blocking also pins the winget package, and unblocking unpins it, so `winget upgrade --all` does not quietly put the new build back.

Two things worth knowing. The policy is read at launch, so close every Claude window — tray icon too — and reopen. And if a machine-wide policy exists at `HKLM\SOFTWARE\Policies\Claude`, it overrides the per-user one entirely; the tool detects that and prints the admin commands instead of pretending to have worked.

## Use

Double-click `claude-toolbox.bat` and pick from the menu. No arguments needed.

## Accounts it can see

- Your normal Claude install, shown as `default` — whether it was the direct `.exe` download (`%APPDATA%\Claude`) or the Microsoft Store / MSIX build (`%LOCALAPPDATA%\Packages\Claude_*\LocalCache\...`).
- Extra accounts made with option 1 (`%LOCALAPPDATA%\Claude-Profiles\<name>`).

## Notes

- Windows only (needs the Claude desktop app installed).
- To move a chat into an account, open that account and sign in once first.
- `Copy`, `Replace` and `Import` ask whether to show the chat at the top of the list — just press Enter for yes. Answering no on `Import` keeps the chat's real dates from the file.
- `Replace` keeps a `.bak` next to the file it changes, so you can undo.

## Heads up

This tool reads and writes Claude Desktop's own on-disk files, which are **not a public API**. A future Claude update could change that layout and break the tool. Tested on Claude for Windows `1.20186.0.0`. It never edits your conversations, only the small pointer files that list them.
