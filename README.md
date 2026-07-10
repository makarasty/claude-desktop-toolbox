# claude-desktop-toolbox

A small menu app for Windows to run several Claude Desktop accounts and move chats between them.

## What it does

- **Set up extra accounts** — separate logins, each with its own window and Start Menu shortcut. Survives Claude updates.
- **Copy a chat into another account.**
- **Replace a chat** with another chat's history.
- **Restart an account window** so moved chats show up.

## How it works

Each account keeps a small pointer file per chat. The real conversation is stored once and shared by all accounts, so copying a chat is instant and never touches the original.

Claude reads its chat list only when an account starts, so a moved chat appears after you restart that account window. The app can do that for you.

## Use

Double-click `claude-toolbox.bat` and pick from the menu. No arguments needed.

## Notes

- Windows only (needs the Claude desktop app installed).
- To move a chat into an account, open that account and sign in once first.
