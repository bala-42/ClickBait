#!/bin/sh
# ClickBait's Claude Code hook (Notification, Stop): one line in ClickBait's events file, which
# ClickBait turns into a pill by the cursor. Claude Code passes its hook JSON on stdin. Only the
# tool, the app it runs in and that JSON are written; nothing is sent anywhere.
dir="$HOME/Library/Application Support/ClickBait"
mkdir -p "$dir" || exit 0
app=$(printf '%s' "${__CFBundleIdentifier:-}" | tr -cd 'A-Za-z0-9._-')
tool=$(printf '%s' "${1:-claude}" | tr -cd 'a-z')
payload=$(tr -d '\n\r')
[ -n "$payload" ] || payload=null
printf '{"tool":"%s","app":"%s","event":%s}\n' "$tool" "$app" "$payload" >> "$dir/agent-events.jsonl"
exit 0
