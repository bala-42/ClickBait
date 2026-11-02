#!/bin/sh
# ClickBait's Claude Code hook (Notification, Stop): one line in ClickBait's events file, which
# ClickBait turns into a pill by the cursor. Claude Code passes its hook JSON on stdin. Only the
# tool, the app and terminal tab it runs in and that JSON are written; nothing is sent anywhere.
dir="$HOME/Library/Application Support/ClickBait"
mkdir -p "$dir" || exit 0
app=$(printf '%s' "${__CFBundleIdentifier:-}" | tr -cd 'A-Za-z0-9._-')
tool=$(printf '%s' "${1:-claude}" | tr -cd 'a-z')
# The terminal tab Claude Code runs in: the first tty up the process chain (the hook itself has
# none), so "go there" can bring that tab forward.
tty=""; p=$$
for _ in 1 2 3 4 5 6; do
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$p" ] && [ "$p" -gt 1 ] || break
  t=$(ps -o tty= -p "$p" 2>/dev/null | tr -cd 'a-z0-9'); case "$t" in tty*) tty=$t; break;; esac
done
payload=$(tr -d '\n\r')
[ -n "$payload" ] || payload=null
printf '{"tool":"%s","app":"%s","tty":"%s","event":%s}\n' "$tool" "$app" "$tty" "$payload" >> "$dir/agent-events.jsonl"
exit 0
