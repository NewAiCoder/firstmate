#!/usr/bin/env bash
# fm-idle-compact.sh - shared eligibility + action owner for opt-in idle-worker
# pre-cache-expiry compaction.
#
# Sourced identically by bin/fm-watch.sh's main loop and
# bin/fm-supervise-daemon.sh's housekeeping tick (fm_idle_compact_tick), so the
# eligibility test and the action sequence have exactly one owner and the two
# supervision paths cannot drift, the same "one shared classifier, two
# callers" shape bin/fm-classify-lib.sh already uses.
#
# Ships inert: an absent local, gitignored config/idle-compact means
# fm_idle_compact_tick returns immediately after one [ -f ] check, with no
# state mutation anywhere. Present, its first non-empty, non-comment line is
# the idle threshold in whole minutes (an empty-but-present file enables the
# feature at the documented 30-minute default); an invalid value is treated
# exactly like an absent file, because a config typo must never fail a
# watcher/daemon loop. See docs/configuration.md "Idle-worker pre-compaction"
# for the full contract.
#
# Eligibility, re-checked every FM_IDLE_COMPACT_INTERVAL seconds for every
# task under state/*.meta, is strictly the intersection of:
#   - kind != secondmate (a secondmate's idle pane is its normal healthy
#     state, and it holds its own fleet) and harness = claude (the only
#     harness with a verified /compact slash command today - every other
#     verified harness is reviewed and not applicable, see
#     docs/configuration.md "Harness compatibility");
#   - bin/fm-crew-state.sh's reconciled current state is parked, done,
#     blocked, or paused - never working (an active no-mistakes run step or a
#     busy pane, even behind a quiet-looking pane) or unknown;
#   - state/<id>.status's mtime age is at least the configured threshold,
#     the same idle-duration basis the watcher's declared-pause re-surface
#     cadence already uses (bin/fm-watch.sh's handle_paused_stale);
#   - a live safety gate right before typing anything: an exact idle verdict
#     from bin/fm-busy-lib.sh's fm_busy_classify and an exact `empty` verdict
#     from bin/fm-backend.sh's fm_backend_composer_state - the identical
#     primitives the away-mode daemon's own injection boundary uses.
#
# A durable per-task marker at state/.idle-compact-<task> (named after the
# existing .hb-surfaced-<task>/.seen-* convention) drives a 4-phase state
# machine so one idle episode produces at most one compaction:
#   1. no marker: send a guarded message asking the crewmate to write its
#      working state to data/<id>/precompact-notes.md, then record
#      phase=save-sent with the current state/<id>.turn-ended signature.
#   2. phase=save-sent: wait for a NEW turn-ended signature - proof the save
#      turn actually completed, the same signal bin/fm-watch.sh's signal scan
#      already trusts - then re-run the full eligibility check (the crew may
#      have been steered back to work during the wait) and the live safety
#      gate before sending /compact with focus text; a bounded
#      FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS abandons a turn that never
#      completes. Once sent, record phase=settling with the send epoch.
#   3. phase=settling: wait FM_IDLE_COMPACT_SETTLE_SECS (default one sweep
#      interval) for the compaction summary to finish rendering, then record
#      phase=done with the status-line and pane-tail signatures - captured
#      after the render so the compaction's own output is baked into the
#      baseline and never reads as new worker activity.
#   4. phase=done: a changed status line or pane-tail signature (a new status
#      append or new pane activity) clears the marker so the next idle
#      episode is evaluated fresh.
#
# Every message is delivered through bin/fm-send.sh exactly as any other
# steer, so the type-once-verified-Enter submission and delivery confirmation
# are unchanged; this file never calls a backend primitive or raw tmux
# command directly, and a deferred or failed attempt at any phase is silent
# routine - retried on the next sweep, never a captain-facing escalation.
#
# CLI (mainly for standalone testing/inspection; production callers source
# this file and call fm_idle_compact_tick directly):
#   fm-idle-compact.sh tick
set -u

# Self-referencing fallbacks (the bin/fm-wake-lib.sh idiom): a caller that
# already sourced its own copy of these globals before sourcing this file
# keeps its value untouched, since every caller derives the identical formula
# from the same FM_HOME/override anyway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
CONFIG="${FM_CONFIG_OVERRIDE:-${CONFIG:-$FM_HOME/config}}"
DATA="${FM_DATA_OVERRIDE:-${DATA:-$FM_HOME/data}}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

FM_IDLE_COMPACT_DEFAULT_MINUTES=30
FM_IDLE_COMPACT_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# --- config parsing ---------------------------------------------------------

# First non-empty, non-comment line of <file>, whitespace-trimmed - the same
# idiom bin/fm-harness.sh's secondmate_line uses for config/secondmate-harness.
fm_idle_compact_first_content_line() {  # <file>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    printf '%s' "$line"
    return 0
  done < "$1"
  return 0
}

# Prints the effective idle threshold in whole minutes and returns 0 when the
# feature is enabled; returns 1 (disabled, prints nothing) when config/idle-
# compact is absent, empty-but-invalid is never a case (empty means the
# documented default), or its first content line is not a positive integer.
fm_idle_compact_threshold_minutes() {  # <config-dir>
  local config=$1 file line
  file="$config/idle-compact"
  [ -f "$file" ] || return 1
  line=$(fm_idle_compact_first_content_line "$file")
  if [ -z "$line" ]; then
    printf '%s' "$FM_IDLE_COMPACT_DEFAULT_MINUTES"
    return 0
  fi
  case "$line" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$line" -gt 0 ] || return 1
  printf '%s' "$line"
}

# --- task context ------------------------------------------------------------

# Resolves <state>/<task>.meta into FM_IDLE_COMPACT_{BACKEND,TARGET,HARNESS,
# KIND,LABEL}. Returns 1 when the meta is missing or records no backend
# target, leaving those globals empty.
FM_IDLE_COMPACT_BACKEND=
FM_IDLE_COMPACT_TARGET=
FM_IDLE_COMPACT_HARNESS=
FM_IDLE_COMPACT_KIND=
FM_IDLE_COMPACT_LABEL=
fm_idle_compact_task_context() {  # <state> <task>
  local state=$1 task=$2 meta
  meta="$state/$task.meta"
  FM_IDLE_COMPACT_BACKEND=
  FM_IDLE_COMPACT_TARGET=
  FM_IDLE_COMPACT_HARNESS=
  FM_IDLE_COMPACT_KIND=
  FM_IDLE_COMPACT_LABEL=
  [ -f "$meta" ] || return 1
  FM_IDLE_COMPACT_BACKEND=$(fm_backend_of_meta "$meta")
  FM_IDLE_COMPACT_TARGET=$(fm_backend_target_of_meta "$meta")
  [ -n "$FM_IDLE_COMPACT_TARGET" ] || return 1
  FM_IDLE_COMPACT_HARNESS=$(fm_meta_get "$meta" harness)
  FM_IDLE_COMPACT_KIND=$(fm_meta_get "$meta" kind)
  [ -n "$FM_IDLE_COMPACT_KIND" ] || FM_IDLE_COMPACT_KIND=ship
  FM_IDLE_COMPACT_LABEL="fm-$task"
  return 0
}

# --- signatures (drive the marker's reset-on-new-activity rule) ------------

# Portable hash of stdin. Mirrors bin/fm-watch.sh's hash_pane idiom; kept
# local because it is a tiny leaf-level portability shim, the same class of
# duplication bin/fm-lock-lib.sh and bin/fm-wake-lib.sh already each carry
# their own portable stat wrapper for.
fm_idle_compact_hash() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

fm_idle_compact_pane_sig() {  # <backend> <target> <label>
  fm_backend_capture "$1" "$2" 40 "$3" 2>/dev/null | fm_idle_compact_hash
}

fm_idle_compact_status_sig() {  # <state> <task>
  last_status_line "$1/$2.status"
}

# turn-ended is touch(1)ed by the harness's turn-end hook on every completed
# turn (AGENTS.md's state/<id>.turn-ended); its mtime alone is a sufficient
# signature since a fresh touch always advances it. "absent" when the task
# has not completed a turn since it was spawned.
fm_idle_compact_turnended_sig() {  # <state> <task>
  local m
  m=$(fm_path_mtime "$1/$2.turn-ended") || true
  printf '%s' "${m:-absent}"
}

# --- marker (state/.idle-compact-<task>) ------------------------------------

fm_idle_compact_marker_path() {  # <state> <task>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.idle-compact-%s' "$1" "$key"
}

fm_idle_compact_marker_field() {  # <marker-file> <key>
  [ -f "$1" ] || return 1
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Atomic write (temp file + rename), mirroring bin/fm-classify-lib.sh's
# cursor-write pattern, so a crash mid-write never leaves a half-written
# marker. Each argument is one complete "key=value" line.
fm_idle_compact_marker_write() {  # <marker-file> <key=value>...
  local f=$1 tmp kv
  shift
  tmp="$f.tmp.$$"
  {
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$tmp" && mv -f "$tmp" "$f"
}

# --- eligibility and the live safety gate -----------------------------------

fm_idle_compact_eligible() {  # <state> <task> <threshold-minutes>
  local state=$1 task=$2 threshold_min=$3 statusf age crewline crewstate

  fm_idle_compact_task_context "$state" "$task" || return 1
  [ "$FM_IDLE_COMPACT_KIND" != secondmate ] || return 1
  [ "$FM_IDLE_COMPACT_HARNESS" = claude ] || return 1

  statusf="$state/$task.status"
  [ -f "$statusf" ] || return 1
  age=$(fm_path_age "$statusf")
  [ "$age" -ge $(( threshold_min * 60 )) ] || return 1

  # Explicit override passthrough, not ambient-environment reliance: FM_HOME
  # may be a computed default (never exported) rather than an inherited env
  # var, especially in a secondmate home, so the same explicit-override idiom
  # bin/fm-fleet-snapshot.sh's crew_state_json uses is required here too -
  # otherwise a secondmate sweep would silently reconcile against the wrong
  # home's state.
  crewline=$(FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" \
    "$FM_IDLE_COMPACT_CREW_STATE_BIN" "$task" 2>/dev/null) || return 1
  case "$crewline" in state:*) ;; *) return 1 ;; esac
  crewstate=${crewline#state: }; crewstate=${crewstate%% *}
  case "$crewstate" in
    parked|done|blocked|paused) return 0 ;;
    *) return 1 ;;
  esac
}

# Requires FM_IDLE_COMPACT_{BACKEND,TARGET,HARNESS,LABEL} already resolved by
# a caller's fm_idle_compact_task_context call. 0 only on an exact idle busy
# verdict (never busy, never an unproven unknown/dead) with an exactly-empty
# composer - the same conservative "only an exact verdict permits action"
# discipline bin/fm-crew-state.sh and bin/fm-supervise-daemon.sh's
# inject_msg already apply.
fm_idle_compact_safe_to_send() {  # <state> <task>
  local state=$1 task=$2 verdict
  verdict=$(fm_busy_classify "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" \
    "$FM_IDLE_COMPACT_HARNESS" "$task" "$state")
  [ "${verdict%% *}" = idle ] || return 1
  [ "$(fm_backend_composer_state "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" \
    "$FM_IDLE_COMPACT_LABEL" 2>/dev/null)" = empty ]
}

# --- messages and delivery ---------------------------------------------------

fm_idle_compact_save_message() {  # <task>
  printf 'Idle-compact: your context cache is about to be compacted while you wait. Before that happens, write your open decision keys, current gate/step, next actions, and key file paths to %s/%s/precompact-notes.md (create it if absent), then stop for this turn.' \
    "$DATA" "$1"
}

fm_idle_compact_compact_message() {  # <task>
  printf '/compact Preserve the pointer to %s/%s/brief.md, the AGENTS.md status-append protocol, and the precompact notes at %s/%s/precompact-notes.md - re-read that notes file after compaction to resume.' \
    "$DATA" "$1" "$DATA" "$1"
}

# Delivers through bin/fm-send.sh's verified type-once-retried-Enter path,
# never a raw backend/tmux call. Silent on either outcome: a deferred or
# failed send is retried on a later sweep, never a captain-facing escalation.
# Explicit override passthrough (the same idiom as the crew-state call above)
# so a caller's <state> - which may differ from $FM_HOME/state under test
# isolation - is exactly what fm-send.sh resolves against.
fm_idle_compact_send() {  # <state> <task> <message>
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$1" \
    "$SCRIPT_DIR/fm-send.sh" "$2" "$3" >/dev/null 2>&1
}

# --- per-task state machine --------------------------------------------------

# Phase 2: waits for the turn-ended signature to advance past the recorded
# baseline (proof the save turn completed), re-checks full eligibility (the
# reconciled crew state may have flipped to working during the wait - the
# never-mid-task rule applies to the /compact send exactly as it does to the
# first send), then sends /compact.
fm_idle_compact_advance_save_sent() {  # <state> <task> <marker> <threshold-minutes>
  local state=$1 task=$2 marker=$3 threshold_min=$4
  local baseline sent_epoch save_timeout age cur_turnended

  fm_idle_compact_task_context "$state" "$task" || { rm -f "$marker"; return 0; }
  baseline=$(fm_idle_compact_marker_field "$marker" baseline_turnended)
  sent_epoch=$(fm_idle_compact_marker_field "$marker" sent_epoch)
  save_timeout=${FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS:-900}

  case "$sent_epoch" in
    ''|*[!0-9]*) rm -f "$marker"; return 0 ;;
  esac
  age=$(( $(date +%s) - sent_epoch ))
  if [ "$age" -ge "$save_timeout" ]; then
    # A save turn that never completes must not wait forever either; abandon
    # this episode silently. A later genuinely new status append or pane
    # activity still clears phase=done the normal way.
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$state" "$task")" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")"
    return 0
  fi

  cur_turnended=$(fm_idle_compact_turnended_sig "$state" "$task")
  [ "$cur_turnended" != "$baseline" ] || return 0

  fm_idle_compact_eligible "$state" "$task" "$threshold_min" || return 0
  fm_idle_compact_safe_to_send "$state" "$task" || return 0

  if fm_idle_compact_send "$state" "$task" "$(fm_idle_compact_compact_message "$task")"; then
    fm_idle_compact_marker_write "$marker" phase=settling \
      "settle_epoch=$(date +%s)"
  fi
  return 0
}

# Phase 3: the /compact went out, but its summary has not necessarily finished
# rendering yet. Capturing the done-phase baseline immediately would record a
# pre-render pane hash, and the compaction summary's own render would then
# read as "new pane activity" - clearing the marker and self-triggering a
# brand-new save+compact episode every couple of sweeps. So the baseline is
# captured on a LATER sweep, one settle window after the send, so the
# feature's own output is baked into the recorded signatures and never counts
# as worker activity.
fm_idle_compact_advance_settling() {  # <state> <task> <marker>
  local state=$1 task=$2 marker=$3 settle_epoch settle_secs age

  fm_idle_compact_task_context "$state" "$task" || { rm -f "$marker"; return 0; }
  settle_epoch=$(fm_idle_compact_marker_field "$marker" settle_epoch)
  case "$settle_epoch" in
    ''|*[!0-9]*) rm -f "$marker"; return 0 ;;
  esac
  settle_secs=${FM_IDLE_COMPACT_SETTLE_SECS:-${FM_IDLE_COMPACT_INTERVAL:-300}}
  age=$(( $(date +%s) - settle_epoch ))
  [ "$age" -ge "$settle_secs" ] || return 0

  fm_idle_compact_marker_write "$marker" phase=done \
    "status_sig=$(fm_idle_compact_status_sig "$state" "$task")" \
    "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")"
  return 0
}

# One task through the 3-phase marker state machine. Never propagates a
# failure to the caller: every branch that cannot proceed just returns 0 so a
# sweep across many tasks never aborts early on one task's transient issue.
fm_idle_compact_process_task() {  # <state> <task> <threshold-minutes>
  local state=$1 task=$2 threshold_min=$3 marker phase status_sig pane_sig
  local cur_status cur_pane_sig cur_turnended

  marker=$(fm_idle_compact_marker_path "$state" "$task")

  if [ -f "$marker" ]; then
    phase=$(fm_idle_compact_marker_field "$marker" phase)
    case "$phase" in
      save-sent)
        fm_idle_compact_advance_save_sent "$state" "$task" "$marker" "$threshold_min"
        return 0
        ;;
      settling)
        fm_idle_compact_advance_settling "$state" "$task" "$marker"
        return 0
        ;;
      done)
        fm_idle_compact_task_context "$state" "$task" || { rm -f "$marker"; return 0; }
        status_sig=$(fm_idle_compact_marker_field "$marker" status_sig)
        pane_sig=$(fm_idle_compact_marker_field "$marker" pane_sig)
        cur_status=$(fm_idle_compact_status_sig "$state" "$task")
        cur_pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")
        if [ "$cur_status" = "$status_sig" ] && [ "$cur_pane_sig" = "$pane_sig" ]; then
          return 0
        fi
        rm -f "$marker"
        ;;
      *)
        rm -f "$marker"
        ;;
    esac
  fi

  fm_idle_compact_eligible "$state" "$task" "$threshold_min" || return 0
  fm_idle_compact_safe_to_send "$state" "$task" || return 0

  cur_turnended=$(fm_idle_compact_turnended_sig "$state" "$task")
  fm_idle_compact_send "$state" "$task" "$(fm_idle_compact_save_message "$task")" || return 0
  fm_idle_compact_marker_write "$marker" phase=save-sent \
    "sent_epoch=$(date +%s)" \
    "baseline_turnended=$cur_turnended"
  return 0
}

# --- sweep entry point (the one thing both callers invoke) -----------------

fm_idle_compact_sweep_due() {  # <state>
  local age
  age=$(fm_path_age "$1/.idle-compact-last-sweep")
  [ "$age" -ge "${FM_IDLE_COMPACT_INTERVAL:-300}" ]
}

# The single entry point bin/fm-watch.sh's main loop and
# bin/fm-supervise-daemon.sh's housekeeping both call, on their own existing
# cadence. Always returns 0: idle-compact is opt-in housekeeping and must
# never fail a caller's loop.
fm_idle_compact_tick() {  # <state> [config-dir]
  local state=$1 config=${2:-$CONFIG} minutes meta task lock

  minutes=$(fm_idle_compact_threshold_minutes "$config") || return 0
  fm_idle_compact_sweep_due "$state" || return 0

  # The watcher's main loop and the away-mode daemon's housekeeping tick both
  # call this against the same state dir, and the due-check above is
  # check-then-touch: without mutual exclusion two concurrent callers can both
  # pass it in the same window, both pass the live safety gate, and interleave
  # keystrokes into the same crewmate pane. fm_lock_try_acquire is the
  # existing WATCH_LOCK idiom (bin/fm-wake-lib.sh: pid-recorded, stale-holder
  # recovery built in); a held lock means the other supervisor is already
  # sweeping, so skipping is silent routine. The due-check re-runs under the
  # lock because the loser of the race may acquire only after the winner
  # released, with the marker already freshly touched.
  lock="$state/.idle-compact.lock"
  fm_lock_try_acquire "$lock" || return 0
  if ! fm_idle_compact_sweep_due "$state"; then
    fm_lock_release "$lock"
    return 0
  fi
  touch "$state/.idle-compact-last-sweep" 2>/dev/null || true

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    fm_idle_compact_process_task "$state" "$task" "$minutes"
  done
  fm_lock_release "$lock"
  return 0
}

# --- Main entry: only when executed directly, matching bin/fm-watch.sh's
# sourced-vs-executed split so tests can source this file for its functions
# without triggering a sweep.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-tick}" in
    tick) fm_idle_compact_tick "$STATE" "$CONFIG" ;;
    *)
      echo "usage: fm-idle-compact.sh [tick]" >&2
      exit 2
      ;;
  esac
fi
