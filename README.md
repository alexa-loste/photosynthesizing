# Photosynthesizing

While Claude Code works, a strip slides in from the side of your screen with the people
you owe a reply. When Claude finishes, the screen edges glow and the strip slides away.
The minutes you'd spend scrolling go to your friends instead.

Built in one hack night. Mac only.

## What's in the strip

- **Reply**: everyone waiting on you, across iMessage, SMS, WhatsApp, Instagram and
  Messenger, one conversation at a time. Send, skip, park it in Later, or mark it done.
- **Later**: a backlog for once Reply is clear, and threads you texted last and mean to
  come back to. Anything here returns to Reply when they text you.
- **All**: every conversation, newest first.
- **Favorites**: people you want to stay close to, each on their own rhythm (every week,
  every month…). It shows when you last texted and called, nudges you with "time to say
  hi", and notes birthdays coming up. For some people you can say only calls count.

## How it works

```
Claude Code ──hooks──▶ ~/.claude-tv/working/<session>   (a turn you prompted is running)
                                │
                                ▼
                    Photosynthesizing.app (the strip, SwiftUI panel)
                                │  HTTP over Tailscale
                                ▼
          always-on Mac · toreplyd (Swift, no dependencies)
            ├── chat.db              iMessage + SMS, read-only
            ├── CallHistory          last phone/FaceTime call, read-only
            ├── AddressBook          names, photos, birthdays, read-only
            ├── Beeper Desktop API   WhatsApp, Instagram, Messenger
            ├── state.db             triage + favorites (the only thing it writes)
            └── Messages.app         sends, via AppleScript
```

1. **When to appear.** A Claude Code hook (`hook/tv_hook.py`) runs on every prompt and
   every stop. It writes a small file while a turn *you* prompted is running, and skips
   turns Claude starts by itself. The strip watches that folder: four seconds into a
   turn it slides in, and when the turn ends it glows and slides out. It stays put while
   you're mid-reply.
2. **What to show.** `toreplyd` runs on an always-on Mac. It reads the Messages database
   read-only, decodes message bodies with Apple's own unarchiver, and keeps its own small
   database of what you've triaged. "Done" means done as of a particular message, so a
   new text puts someone back in your queue automatically. Other networks come in through
   Beeper Desktop's local API.
3. **Reaching out.** Replies go out through Messages (or Beeper); calls open FaceTime.

## Setup

You need an always-on Mac signed in to iMessage, with Tailscale, and a Mac you work on
with Claude Code. They can be the same Mac.

**Server (the always-on Mac)**

```bash
cp toreply.env.example toreply.env      # set TOREPLY_REMOTE to its ssh host
./deploy-server.sh                      # builds, signs, installs, restarts
ssh <host> 'bash -s' < tools/install-agent.sh   # once: keep it running
```

Grant the installed `~/toreply/bin/toreplyd` Full Disk Access on that Mac (System
Settings → Privacy & Security). It's signed with your Apple Development certificate, so
the grant survives future deploys.

Optional: install Beeper Desktop there, enable its Desktop API (Settings →
Integrations), and save a token to `~/.toreply/beeper-token`.

**Strip (your Mac)**

```bash
cd strip && ./build.sh && open build/Photosynthesizing.app
```

Write `~/.claude-tv/config.json`:

```json
{"baseURL": "http://<server's tailscale address>:8787/", "token": "<ssh host 'cat ~/.toreply/token'>"}
```

Add the hook to `~/.claude/settings.json` for `UserPromptSubmit`, `Stop`,
`Notification`, `PostToolUse` and `SessionEnd`:

```json
{"hooks": [{"type": "command", "command": "/usr/bin/python3 /path/to/hook/tv_hook.py", "timeout": 5}]}
```

**Using it**: it appears on its own. ⌃⌥Space or the menu bar icon opens it by hand.
`strip/demo.sh 60` pretends Claude is working for a minute.

## Notes

- Everything stays on your own machines; nothing goes to a third-party server except
  what Beeper itself does.
- iMessage tapbacks can't be sent from a Mac app without Apple's private frameworks, so
  reactions work on Beeper networks only.
- Messenger one-to-one chats are end-to-end encrypted by default and may not come
  through Beeper; group chats do.
