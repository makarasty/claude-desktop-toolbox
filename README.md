# claude-desktop-toolbox

A small menu app for Windows to run several Claude Desktop accounts and move chats between them.

## What it does

- **Set up extra accounts** — separate logins, each with its own window and Start Menu shortcut. Survives Claude updates.
- **Copy a chat into another account.**
- **Replace a chat** with another chat's history.
- **Restart an account window** so moved chats show up.
- **Export a chat** to Desktop or Downloads as readable text (`.md`) or raw data (`.jsonl`).
- **Import a chat** from a `.jsonl` file — auto-finds them on your Desktop and in Downloads.

## How it works

Each account keeps a small pointer file per chat. The real conversation is stored once and shared by all accounts, so copying a chat is instant and never touches the original.

Claude reads its chat list only when an account starts, so a moved chat appears after you restart that account window. The app can do that for you.

## Use

Double-click `claude-toolbox.bat` and pick from the menu. No arguments needed.

## Accounts it can see

- Your normal Claude install (`%APPDATA%\Claude`), shown as `default`.
- Extra accounts made with option 1 (`%LOCALAPPDATA%\Claude-Profiles\<name>`).

## Notes

- Windows only (needs the Claude desktop app installed).
- To move a chat into an account, open that account and sign in once first.
- `Replace` keeps a `.bak` next to the file it changes, so you can undo.

## Heads up

This tool reads and writes Claude Desktop's own on-disk files, which are **not a public API**. A future Claude update could change that layout and break the tool. Tested on Claude for Windows `1.20186.0.0`. It never edits your conversations, only the small pointer files that list them.
