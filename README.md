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
                                │  HTTP on 127.0.0.1
                                ▼
          toreplyd (Swift, no dependencies)
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
2. **What to show.** `toreplyd` is a small server on the same Mac. It reads the Messages database
   read-only, decodes message bodies with Apple's own unarchiver, and keeps its own small
   database of what you've triaged. "Done" means done as of a particular message, so a
   new text puts someone back in your queue automatically. Other networks come in through
   Beeper Desktop's local API.
3. **Reaching out.** Replies go out through Messages (or Beeper); calls open FaceTime.

## Setup

You need a Mac signed in to iMessage, with Messages in iCloud turned on, Xcode or the
Xcode command line tools, and Claude Code. Everything runs on that one Mac.

```bash
git clone https://github.com/alexa-loste/photosynthesizing && cd photosynthesizing
./install.sh
```

The script builds the server and the strip, starts both at login, points the strip at
the server, and adds the Claude Code hook to `~/.claude/settings.json` (keeping a
`.bak` copy). Run it again after pulling changes.

Then the one step it can't do for you: give the server **Full Disk Access**, so it can
read Messages, call history and Contacts (read-only). The script opens the settings
page; click **+**, press **⌘⇧G**, paste `~/toreply/bin/toreplyd`, and switch it on. Then:

```bash
launchctl kickstart -k gui/$(id -u)/com.photosynthesizing.server
```

The first time you send a reply, macOS asks whether the server may control Messages.
Allow it.

**WhatsApp, Instagram and Messenger (optional).** Install
[Beeper Desktop](https://www.beeper.com), sign in to those accounts, turn on its Desktop
API (Settings → Integrations), create a token, and save it:

```bash
umask 077; cat > ~/.toreply/beeper-token     # paste the token, then Ctrl-D
launchctl kickstart -k gui/$(id -u)/com.photosynthesizing.server
```

**Checking it.** `~/toreply/bin/toreplyd doctor` reports whether it can read Messages,
without printing any message content.

### Running the server on another Mac

If you have an always-on Mac, the server can live there instead, so other clients can
reach it while your laptop sleeps. It's reached over Tailscale:

```bash
cp toreply.env.example toreply.env              # set TOREPLY_REMOTE to its ssh host
./deploy-server.sh                              # builds, signs, installs, restarts there
ssh <host> 'bash -s' < tools/install-agent.sh   # once: keep it running
```

Grant Full Disk Access to `~/toreply/bin/toreplyd` on that Mac, then on your laptop build
the strip (`cd strip && ./build.sh`), add the hook with
`python3 tools/add-hooks.py ~/.claude/settings.json hook/tv_hook.py`, and write
`~/.claude-tv/config.json`:

```json
{"baseURL": "http://<server's tailscale address>:8787/", "token": "<cat ~/.toreply/token on that Mac>"}
```

**Using it**: it appears on its own. ⌃⌥Space or the menu bar icon opens it by hand.
With several Claude sessions going, the strip lists each one (working, needs you, done)
and the screen glows whenever any one of them finishes. `strip/demo.sh 60` pretends
Claude is working for a minute.

## Notes

- Everything stays on your own machines; nothing goes to a third-party server except
  what Beeper itself does.
- iMessage tapbacks can't be sent from a Mac app without Apple's private frameworks, so
  reactions work on Beeper networks only.
- Messenger one-to-one chats are end-to-end encrypted by default and may not come
  through Beeper; group chats do.
