#!/usr/bin/env bash
# Exercise the real notification functions without touching the desktop bus.
set -euo pipefail
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export XDG_RUNTIME_DIR=$ROOT/run HYPRLAND_INSTANCE_SIGNATURE=first-session
mkdir -m 700 "$XDG_RUNTIME_DIR"
export NOTIFY_LOG=$ROOT/notifications
# Extract just the functions so the trusted production PATH remains untouched.
source <(sed -n '/^notify_error_once() {/,/^}/p; /^notify_user() {/,/^}/p; /^fail() {/,/^}/p' "$REPO/bin/hyprchroma")
notify-send() { printf '%s\n' "$*" >> "$NOTIFY_LOG"; }
export -f notify-send
chk() { if [[ $2 == "$3" ]]; then echo "  PASS $1"; else echo "  FAIL $1: got [$2] want [$3]"; exit 1; fi; }
count() { if [[ -f $NOTIFY_LOG ]]; then wc -l < "$NOTIFY_LOG" | tr -d ' '; else echo 0; fi; }
notify=1
notify_user 'Colors synchronized'
notify_user 'Dark Reader disabled'
chk 'routine messages stay quiet even with --notify' "$(count)" 0
for ((i=0; i<20; i++)); do notify_error_once & done
wait
chk 'concurrent failures share one popup' "$(count)" 1
notify_error_once
chk 'later failures in the same session stay quiet' "$(count)" 1
HYPRLAND_INSTANCE_SIGNATURE=second-session
# A daemon-style failure has no --notify flag, but still deserves one alert.
set +e
(notify=0; fail 'test error') 2>/dev/null
result=$?
set -e
chk 'fail preserves its failure exit status' "$result" 1
chk 'a new compositor session gets one fresh popup' "$(count)" 2
# Reloading functions (like restarting the service) must retain the budget.
source <(sed -n '/^notify_error_once() {/,/^}/p' "$REPO/bin/hyprchroma")
notify_error_once
chk 'service reloads do not reset the budget' "$(count)" 2
unset HYPRLAND_INSTANCE_SIGNATURE
XDG_SESSION_ID=third-session notify_error_once
XDG_SESSION_ID=third-session notify_error_once
chk 'session-id fallback also deduplicates' "$(count)" 3
XDG_RUNTIME_DIR= notify_error_once
chk 'no runtime directory means no popup or persistent marker' "$(count)" 3
notify-send() { return 1; }
HYPRLAND_INSTANCE_SIGNATURE=failing-notifier notify_error_once
HYPRLAND_INSTANCE_SIGNATURE=failing-notifier notify_error_once
chk 'a broken notification daemon does not fail synchronization' "$?" 0
chk 'all desktop notifications flow through the error budget' "$(grep -c '^[[:space:]]*notify-send ' "$REPO/bin/hyprchroma")" 1
chk 'the bar alert stays available and is not hardcoded off' "$(grep -c 'active: root.alertCount > 0' "$REPO/BarWidget.qml"),$(grep -c 'id: staleBadge' "$REPO/BarWidget.qml")" 1,1
chk 'theme hook does not request routine popups' "$(grep -c '^exec /usr/bin/hyprchroma --force --quiet$' "$REPO/share/hooks/hyprchroma")" 1
