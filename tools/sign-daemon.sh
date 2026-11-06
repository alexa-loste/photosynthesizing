#!/bin/bash
# Sign a freshly built toreplyd with the Apple Development certificate and install it.
#
#   sign-daemon.sh <staged binary> <install path> [--restart]
#
# Why a certificate and not ad hoc: Full Disk Access is stored against the binary's
# designated requirement. An ad-hoc signature's requirement is its cdhash, which changes
# on every build, so each deploy silently revoked the grant and the daemon crash-looped
# on "could not open chat.db" (Aug 21 to Nov 5 2026). A certificate signature's
# requirement names the identifier and the certificate instead, so it survives rebuilds
# until the certificate itself is renewed.
#
# Runs as a one-shot LaunchAgent in gui/<uid>, never over SSH: codesign needs the private
# key in the login keychain, which an SSH session cannot reach (see refresh-app.sh).
# Writes "ok" or "failed: …" to ~/.toreply/sign.status for deploy.sh to wait on.
set -uo pipefail

STAGED="$1"
DEST="$2"
STATUS="$HOME/.toreply/sign.status"

fail() { echo "failed: $*" > "$STATUS"; exit 1; }

IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')
[[ -n "$IDENTITY" ]] || fail "no Apple Development identity in the login keychain"

codesign --force --sign "$IDENTITY" --identifier com.alexa.toreplyd "$STAGED" 2>/tmp/toreplyd-sign.err \
  || fail "codesign: $(tail -1 /tmp/toreplyd-sign.err)"
codesign --verify "$STAGED" || fail "signature did not verify"

mv -f "$STAGED" "$DEST" || fail "could not install to $DEST"

if [[ "${3:-}" == "--restart" ]]; then
  launchctl kickstart -k "gui/$(id -u)/com.alexa.toreplyd" || fail "kickstart"
fi
echo ok > "$STATUS"
