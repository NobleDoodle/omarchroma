#!/usr/bin/env bash
# The theme hook does not run the sync in omarchy-theme-set's process tree,
# outside the unit's restrictions. It asks the running service with SIGUSR1 -- no data, to the unit's
# main process only -- and returns at once; the sync and its result are the
# service's.
#
# Run for real against the user's service manager, with a transient unit
# carrying the shipped unit's restrictions, a scratch home and runtime
# directory, and a fake Hyprland event stream. The service side's sync is a
# stub that records where it ran; a second unit then runs one real forced
# sync under the same restrictions. Nothing of the real session is used but
# the manager itself: its private socket is linked into the scratch runtime
# directory for systemctl, and the session bus is not.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
set -uo pipefail
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }

REAL_RUNTIME=/run/user/$(id -u)
BUS=${HYPRCHROMA_TEST_SESSION_BUS:-${DBUS_SESSION_BUS_ADDRESS:-}}
if [[ ! -S $REAL_RUNTIME/systemd/private || -z $BUS ]]; then
  echo "  FAIL this suite needs the user's service manager"; exit 0
fi

# The real home's Omarchroma files, as they stand: compared at the end, so a
# unit that reached them fails this suite rather than going unnoticed.
REAL_HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
real_snapshot() {
  find "$REAL_HOME/.local/state/hyprchroma" "$REAL_HOME/.local/share/hyprchroma" "$REAL_HOME/.config/kdeglobals" \
       "$REAL_HOME/.config/gtk-3.0" "$REAL_HOME/.config/gtk-4.0" "$REAL_HOME/.local/share/color-schemes" \
       "$REAL_HOME/.icons" "$REAL_HOME/.local/share/icons" "$REAL_HOME/.config/omarchy/themes" \
       -maxdepth 3 -printf '%p %T@ %l\n' 2>/dev/null | sort | sha256sum
}
real_before=$(real_snapshot)

ROOT=$(mktemp -d "$HOME/handoff-XXXXXX")
UNIT=hyprchroma-handoff-test-$$-$RANDOM.service
SYNC_UNIT=hyprchroma-handoff-sync-$$-$RANDOM.service
RUN=$ROOT/run H=$ROOT/home
mkdir -p "$RUN/hypr/fake" "$H" "$ROOT/urun"; chmod 700 "$RUN" "$ROOT/urun"
ln -s "$REAL_RUNTIME/systemd" "$RUN/systemd"
sysctl_() { XDG_RUNTIME_DIR=$RUN systemctl --user "$@"; }
# The user manager's environment names the real XDG folders, and a transient
# unit inherits it: every one is set to the scratch home here, for every unit
# this starts. (Left out once, a forced sync in the second unit below wrote
# its status and palettes into the real state and data folders.)
isolate=(--setenv=HOME="$H" --setenv=XDG_CONFIG_HOME="$H/.config" --setenv=XDG_DATA_HOME="$H/.local/share"
         --setenv=XDG_STATE_HOME="$H/.local/state" --setenv=XDG_CACHE_HOME="$H/.cache")
run_unit() { XDG_RUNTIME_DIR=$RUN DBUS_SESSION_BUS_ADDRESS=$BUS systemd-run --user --quiet --collect "$@"; }
cleanup() {
  sysctl_ stop "$UNIT" "$SYNC_UNIT" >/dev/null 2>&1
  [[ -n ${SERVER:-} ]] && kill "$SERVER" 2>/dev/null
  [[ -f $ROOT/waiter.pid ]] && kill "$(cat "$ROOT/waiter.pid")" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

# The shipped unit's restrictions, read from the file rather than copied.
props=()
while IFS= read -r line; do
  [[ $line =~ ^(NoNewPrivileges|RestrictSUIDSGID|RestrictRealtime|RestrictNamespaces|RestrictAddressFamilies|SystemCallArchitectures|SystemCallFilter|LockPersonality|MemoryHigh|MemoryMax|TasksMax)= ]] &&
    props+=(-p "$line")
done < packaging/systemd/hyprchromad.service
chk "the test unit carries all eleven of the shipped unit's restrictions" "$(( ${#props[@]} / 2 ))" "11"

make install DESTDIR="$ROOT/stage" >/dev/null 2>&1
L=$ROOT/stage/usr/lib/hyprchroma
cat > "$ROOT/service-sync" <<EOF
#!/bin/bash
{ echo "start"; awk '/^NoNewPrivs/{print "nnp=" \$2}' /proc/self/status; echo "cgroup=\$(cat /proc/self/cgroup)"; } >> "$ROOT/service-runs"
if [[ -f "$ROOT/spawn-waiter" ]]; then setsid sleep 60 </dev/null >/dev/null 2>&1 & echo \$! > "$ROOT/waiter.pid"; fi
sleep 0.5
echo "end" >> "$ROOT/service-runs"
exit \$(cat "$ROOT/exit-status" 2>/dev/null || echo 0)
EOF
printf '#!/bin/bash\necho local >> "%s/local-runs"\n' "$ROOT" > "$ROOT/local-sync"
chmod +x "$ROOT/service-sync" "$ROOT/local-sync"
sed -i "s|^FORCED_SYNC = .*|FORCED_SYNC = [\"$ROOT/service-sync\"]|" "$L/hyprchroma_state.py"
sed -e "s|^SERVICE=hyprchromad.service$|SERVICE=$UNIT|" -e "s|^exec /usr/bin/hyprchroma --force --quiet$|exec $ROOT/local-sync|" \
  share/hooks/hyprchroma > "$ROOT/hook"
chk "the probe hook took its substitutions" \
  "$(grep -c "^SERVICE=$UNIT$\|^exec $ROOT/local-sync$" "$ROOT/hook"),$(grep -c '^FORCED_SYNC = \["' "$L/hyprchroma_state.py")" "2,1"
hook() { env -i PATH=/usr/bin HOME="$H" XDG_RUNTIME_DIR="$RUN" bash "$ROOT/hook" "${1:-theme}"; }
runs() { grep -c "^$1$" "$ROOT/service-runs" 2>/dev/null; }
# The hook does not wait, so the checks below do: until the watcher has taken
# a request past the count it showed before, and finished every one.
requested() { cut -d' ' -f3 "$RUN/hyprchroma-handoff" 2>/dev/null; }
settle() {
  local requested done
  for _ in $(seq 150); do
    read -r _ _ requested done _ < "$RUN/hyprchroma-handoff" 2>/dev/null
    (( ${requested:-0} > $1 && ${done:-0} >= ${requested:-0} )) && return 0
    sleep 0.1
  done
  return 1
}

/usr/bin/python3 -I - "$RUN/hypr/fake/.socket2.sock" <<'PY' &
import socket, sys, threading, time
server = socket.socket(socket.AF_UNIX); server.bind(sys.argv[1]); server.listen(4)
held = []
while True:
    connection, _ = server.accept(); held.append(connection)
PY
SERVER=$!
for _ in $(seq 50); do [[ -S $RUN/hypr/fake/.socket2.sock ]] && break; sleep 0.1; done

run_unit --unit="$UNIT" "${props[@]}" "${isolate[@]}" \
  --setenv=XDG_RUNTIME_DIR="$RUN" --setenv=HYPRLAND_INSTANCE_SIGNATURE=fake \
  "$L/hyprchroma-state" --state-dir "$H/state" --data-dir "$H/data" watch-events
main_pid=""
for _ in $(seq 100); do
  main_pid=$(sysctl_ show --property=MainPID --value "$UNIT" 2>/dev/null)
  [[ -f $RUN/hyprchroma-handoff && $(cut -d' ' -f1 "$RUN/hyprchroma-handoff") == "$main_pid" ]] && break
  sleep 0.1
done
chk "the watcher says it is listening, under the unit's main pid" \
  "$(cut -d' ' -f1,3- "$RUN/hyprchroma-handoff" 2>/dev/null)" "$main_pid 0 0 0"

# --- a theme change is synchronized by the service, inside its unit --------
before=$(requested); hook; rc=$?; ended=$(runs end)
chk "the hook hands the sync over and returns before it has finished" "$rc,${ended:-0}" "0,0"
settle "$before"
chk "...and the service runs it, once, and nothing runs in the hook" "$(runs start),$(runs end),$(cat "$ROOT/local-runs" 2>/dev/null | wc -l)" "1,1,0"
chk "the sync runs with no new privileges" "$(grep -c '^nnp=1$' "$ROOT/service-runs")" "1"
chk "...in the service's own cgroup" "$(grep -c "^cgroup=.*/$UNIT$" "$ROOT/service-runs")" "1"
echo 4 > "$ROOT/exit-status"; before=$(requested); hook; rc=$?; settle "$before"; rm -f "$ROOT/exit-status"
chk "a sync that fails leaves the hook's result alone, and its status in the file" "$rc,$(cut -d' ' -f5 "$RUN/hyprchroma-handoff")" "0,4"

# --- requests that arrive together, or during a sync, fold together ---------
: > "$ROOT/service-runs"
before=$(requested)
pids=()
for i in 1 2 3 4; do hook "theme$i" & pids+=("$!"); done
statuses=()
for pid in "${pids[@]}"; do wait "$pid"; statuses+=("$?"); done
rcs=$(printf '%s\n' "${statuses[@]}" | sort -u | paste -sd,)
settle "$before"; syncs=$(runs end)
chk "four hooks at once all return, and none runs the sync itself" "$rcs,$(cat "$ROOT/local-runs" 2>/dev/null | wc -l)" "0,0"
chk "...from one sync, or one more for the requests made during it" "$(( syncs >= 1 && syncs <= 2 ))" "1"

# --- the signal reaches the watcher alone -----------------------------------
touch "$ROOT/spawn-waiter"; before=$(requested); hook; settle "$before"; rm -f "$ROOT/spawn-waiter"
waiter=$(cat "$ROOT/waiter.pid" 2>/dev/null)
before=$(requested); hook; settle "$before"
chk "a waiter a sync left running in the unit survives the next request" \
  "$([[ -n $waiter ]] && kill -0 "$waiter" 2>/dev/null && echo alive || echo gone)" "alive"
kill "$waiter" 2>/dev/null

# --- anything unexpected, and the hook runs the sync itself -----------------
sysctl_ stop "$UNIT" >/dev/null 2>&1
chk "a stopped watcher withdraws its file" "$([[ -e $RUN/hyprchroma-handoff ]] && echo left || echo gone)" "gone"
: > "$ROOT/local-runs"; hook
chk "with the service stopped, the hook synchronizes by itself" "$(wc -l < "$ROOT/local-runs")" "1"
printf '%s 1 0 0 0\n' "$$" > "$RUN/hyprchroma-handoff"; hook
chk "...and with a file naming some other process" "$(wc -l < "$ROOT/local-runs")" "2"
rm -f "$RUN/hyprchroma-handoff"; mkfifo "$RUN/hyprchroma-handoff"
timeout 20 env -i PATH=/usr/bin HOME="$H" XDG_RUNTIME_DIR="$RUN" bash "$ROOT/hook"; rc=$?
chk "...and with a FIFO in its place, without waiting on it" "$rc,$(wc -l < "$ROOT/local-runs")" "0,3"
rm -f "$RUN/hyprchroma-handoff"

# --- a real forced sync runs whole under the unit's restrictions ------------
# The staged package, a seeded Omarchy theme, Icons on, gsettings kept in
# memory, and a runtime directory with no way to the real session at all.
source tests/lib-omarchy.sh
( HOME=$H seed_omarchy_theme )
mkdir -p "$H/.local/state/hyprchroma/icons"
printf '{"frameworks":{"icons":true}}\n' > "$H/.local/state/hyprchroma/settings.json"
icon_set=reversal; [[ -f /usr/share/icons/Reversal/index.theme ]] || icon_set=yaru
printf '{"icon_set":"%s"}\n' "$icon_set" > "$H/.local/state/hyprchroma/icons/settings.json"
# The manager hands every unit the real session bus too; this one gets an
# address inside the scratch folder that leads nowhere.
sync_env=("${isolate[@]}" --setenv=XDG_RUNTIME_DIR="$ROOT/urun" --setenv=GSETTINGS_BACKEND=memory
          --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$ROOT/urun/no-bus" --setenv=HYPRCHROMA_NO_AUTO_RESTART=1)
# What the sync will see, checked first: every place it writes must be inside
# the scratch folder, or it does not run at all.
seen=$(run_unit --wait --pipe "${sync_env[@]}" /usr/bin/env 2>/dev/null |
       grep -E '^(HOME|XDG_(CONFIG|DATA|STATE|CACHE)_HOME|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)=')
contained=$(awk -v root="$ROOT/" '{ value = substr($0, index($0, "=") + 1); sub(/^unix:path=/, "", value)
                                       if (index(value, root) != 1) bad++ } END { print bad ? "leaks" : "contained" }' <<<"$seen")
chk "the sync's unit sees only the scratch home, runtime directory and a bus that leads nowhere" \
  "$contained,$(grep -c . <<<"$seen")" "contained,7"
rc=skipped out=""
if [[ $contained == contained ]]; then
  out=$(run_unit --unit="$SYNC_UNIT" --wait --pipe -p RuntimeMaxSec=120 "${props[@]}" "${sync_env[@]}" \
          "$ROOT/stage/usr/bin/hyprchroma" --force --quiet 2>&1); rc=$?
fi
chk "a whole forced sync succeeds inside the unit's restrictions" "$rc" "0"
chk "...writing GTK, Icons and the status as it does outside them" \
  "$(for f in .config/gtk-4.0/hyprchroma.css .icons/Omarchroma-Icons/index.theme .local/state/hyprchroma/status.json; do [[ -s $H/$f ]] && printf 1 || printf 0; done)" "111"
# Qt/KDE writes, or defers while a KDE application is running on this
# machine -- the sync sees every process, as it does outside the unit.
chk "...and Qt/KDE as it would: written, or deferred for a running KDE app" \
  "$(state=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("qtKde"))' "$H/.local/state/hyprchroma/status.json" 2>/dev/null)
     [[ ( $state == synchronized && -s $H/.config/kdeglobals ) || $state == deferred ]] && echo ok || echo "$state")" "ok"
[[ $rc == 0 ]] || printf '%s\n' "$out" | tail -5 | sed 's/^/    /'

# --- the shape that makes this safe -----------------------------------------
code(){ sed -e 's/[[:space:]]*#.*//' "$@"; }
chk "the hook returns right after the signal, and only falls back before it" \
  "$(code share/hooks/hyprchroma | sed -n '/^hand_off() {/,/^}/p' | grep -A1 'kill-whom=main' | tail -1 | tr -d ' '),$(code share/hooks/hyprchroma | grep -c 'sleep')" "exit0,0"
chk "the hook signals the unit's main process only, through the pinned PATH" \
  "$(code share/hooks/hyprchroma | grep -c 'systemctl --user kill --kill-whom=main --signal=SIGUSR1 "$SERVICE"'),$(grep -c '^PATH=$(hyprchroma_trusted_path)$' share/hooks/hyprchroma)" "1,1"
chk "the daemon ignores the signal until the watcher, its main process, takes it" \
  "$(sed -n '/^  daemon)/,/^    ;;/p' bin/hyprchroma | grep -c "^    trap '' USR1$"),$(sed -n '/^  daemon)/,/^    ;;/p' bin/hyprchroma | grep -c '^    exec "$HYPRCHROMA_LIB/hyprchroma-state" \\$')" "1,1"
chk "no listening socket, FIFO or bus name is added for it" \
  "$(code lib/hyprchroma-state | grep -cE '\.listen\(|mkfifo|RequestName|bus_name')" \
  "$(git show 6451440:lib/hyprchroma-state | code /dev/stdin | grep -cE '\.listen\(|mkfifo|RequestName|bus_name')"

chk "nothing in the real home was touched" "$(real_snapshot)" "$real_before"
