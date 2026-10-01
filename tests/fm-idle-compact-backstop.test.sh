#!/usr/bin/env bash
# tests/fm-idle-compact-backstop.test.sh - behavior tests for the second half of
# the idle-worker compaction owner (bin/fm-idle-compact.sh): the ring backstop,
# the idle-duration basis, induced-turn absorption, and the tick entry point.
# Split out of tests/fm-idle-compact.test.sh so ShellCheck stays under the
# per-process lint memory bound; the hermetic setup and shared helpers are the
# same as that file's.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-compact-backstop)

new_dir() {  # <name> -> echoes a fresh <TMP_ROOT>/<name>/state dir (created)
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/config" "$d/data"
  printf '%s' "$d"
}

write_task_meta() {  # <state> <task> [harness] [kind] [window]
  local state=$1 task=$2 harness=${3:-claude} kind=${4:-ship} window=${5:-}
  window=${window:-fake:w-$task}
  fm_write_meta "$state/$task.meta" \
    "window=$window" \
    "backend=tmux" \
    "harness=$harness" \
    "kind=$kind"
}

# Appends <line> to the task's status log and backdates the file <seconds-ago>.
# The spawn record is backdated with it: fm-spawn.sh writes state/<id>.meta once,
# at spawn, so in production a crew's own status appends always come LATER, and
# the idle-duration basis (newest of meta/status/turn-ended) would otherwise read
# a fixture's just-written meta as activity a real fleet never has.
touch_status() {  # <state> <task> <seconds-ago> [line]
  local state=$1 task=$2 ago=$3 line=${4:-done: fixture} f now
  f="$state/$task.status"
  printf '%s\n' "$line" > "$f"
  now=$(date +%s)
  touch -d "@$((now - ago))" "$f"
  [ -e "$state/$task.meta" ] && touch -d "@$((now - ago))" "$state/$task.meta"
  return 0
}

# Backdates an existing file by <seconds-ago>, for aging a marker/turn-ended
# fixture the same way touch_status ages a status log.
backdate() {  # <file> <seconds-ago>
  local now
  now=$(date +%s)
  touch -d "@$(( now - $2 ))" "$1"
}

# write_crew_state_stub <dir> <line> -> echoes an executable path that always
# prints <line> to stdout, ignoring its arguments/environment. Used as
# FM_IDLE_COMPACT_CREW_STATE_BIN, which fm_idle_compact_eligible reads at
# CALL time (a plain global, not fixed at source time), so reassigning it
# per test is sufficient - no need to re-source the library.
write_crew_state_stub() {  # <dir> <line>
  local dir=$1 line=$2 f outfile
  f="$dir/fake-crew-state.sh"
  outfile="$dir/fake-crew-state.out"
  printf '%s\n' "$line" > "$outfile"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat %s\n' "$(printf '%q' "$outfile")"
  } > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# fm_busy_classify/fm_backend_composer_state are stubbed idle+empty (safe) and
# fm_idle_compact_send records its calls to a log file, as in the first half.

stub_always_safe() {
  fm_busy_classify() { printf 'idle claude-hook'; }
  fm_backend_composer_state() { printf 'empty'; }
}

stub_recording_send() {  # <logfile>
  local log=$1
  # shellcheck disable=SC2317  # invoked indirectly by the state-machine functions under test
  fm_idle_compact_send() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$log"; return 0; }
}

# --- ring backstop (fm_idle_compact_ring_backstop) ---------------------------
# The last line of defence for a worker that was compacted, never rung, and is
# waiting on firstmate rather than on an external event.

# Arranges a phase=done marker whose signatures match reality (so the episode is
# a no-op) over a status log that still declares the compaction pause, aged
# <marker-age> seconds. Echoes the marker path. An optional <settle-epoch>
# reproduces the field the real settling->done transition now persists
# (fm_idle_compact_advance_settling), so a test can construct a SECOND
# episode's marker distinguishable from an earlier episode's inbox records;
# omitted, the marker carries no settle_epoch at all, matching a legacy marker.
arrange_done_declaring_pause() {  # <dir> <task> <marker-age> [settle-epoch]
  local dir=$1 task=$2 age=$3 settle_epoch=${4:-} marker
  write_task_meta "$dir/state" "$task"
  touch_status "$dir/state" "$task" 3600 \
    'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
  fm_idle_compact_task_context "$dir/state" "$task"
  marker=$(fm_idle_compact_marker_path "$dir/state" "$task")
  if [ -n "$settle_epoch" ]; then
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$dir/state" "$task")" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")" \
      "settle_epoch=$settle_epoch"
  else
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$dir/state" "$task")" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")"
  fi
  backdate "$marker" "$age"
  printf '%s' "$marker"
}

test_backstop_fires_on_a_stale_done_episode_with_no_ring_record() {
  (
    local dir log marker
    dir=$(new_dir backstop-stale)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(arrange_done_declaring_pause "$dir" t1 1800)

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "the backstop must not disturb the episode phase"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "a stale phase=done episode over a still-declared pause must be rung"
    grep -q 'ring backstop re-sent' "$dir/state/.idle-compact.log" \
      || fail "the backstop must log, because it firing means the primary path missed"
    pass "fm_idle_compact_ring_backstop: a stale phase=done episode with no ring record is rung and logged"
  ) || exit 1
}

test_backstop_does_not_fire_on_a_fresh_done_episode() {
  (
    local dir log
    dir=$(new_dir backstop-fresh)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    arrange_done_declaring_pause "$dir" t1 30 >/dev/null

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "a freshly-rung worker that has simply not taken its turn yet must be left alone"
    pass "fm_idle_compact_ring_backstop: a fresh phase=done episode is left alone"
  ) || exit 1
}

test_backstop_skips_when_the_inbox_already_holds_the_ring() {
  (
    local dir log
    dir=$(new_dir backstop-recorded)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    arrange_done_declaring_pause "$dir" t1 1800 >/dev/null
    fm_task_inbox_write "$dir/state" t1 "$(fm_idle_compact_ring_message)" >/dev/null

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "a worker that already holds the ring record must never be sent it twice"
    pass "fm_idle_compact_ring_backstop: an existing ring record in the inbox suppresses the re-send"
  ) || exit 1
}

test_backstop_skips_when_the_ring_was_already_acknowledged() {
  (
    local dir log rec handled
    dir=$(new_dir backstop-handled)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    arrange_done_declaring_pause "$dir" t1 1800 >/dev/null
    rec=$(fm_task_inbox_write "$dir/state" t1 "$(fm_idle_compact_ring_message)")
    handled=$(fm_task_inbox_handled_dir "$dir/state" t1)
    mkdir -p "$handled" && mv "$rec" "$handled/"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "an acknowledged ring in handled/ still proves the worker was rung"
    pass "fm_idle_compact_ring_backstop: an acknowledged ring record in handled/ suppresses the re-send"
  ) || exit 1
}

# Sequence numbers - and so handled/ records - are never reused for a task's
# whole lifetime, so a task that runs a SECOND idle-compact episode keeps the
# first episode's acknowledged ring on disk, same constant body text. A
# second episode whose own ring enqueue genuinely failed must still be rung by
# the backstop; the stale first episode's ring must never satisfy the check.
test_backstop_ignores_a_prior_episodes_acknowledged_ring() {
  (
    local dir log rec handled marker
    dir=$(new_dir backstop-prior-episode)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'

    # Episode 1: rang and acknowledged.
    rec=$(fm_task_inbox_write "$dir/state" t1 "$(fm_idle_compact_ring_message)")
    handled=$(fm_task_inbox_handled_dir "$dir/state" t1)
    mkdir -p "$handled" && mv "$rec" "$handled/"

    # Episode 2's settle_epoch (fixed a few seconds ahead so it cannot land in
    # the same wall-clock second as episode 1's `at=` write above, which is
    # the only thing that timestamp comparison needs to tell them apart) is
    # strictly after episode 1's ring was recorded, and its own settling->done
    # ring enqueue genuinely failed - nothing new written to the inbox.
    marker=$(arrange_done_declaring_pause "$dir" t1 1800 "$(( $(date +%s) + 5 ))")

    fm_idle_compact_process_task "$dir/state" t1 30
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "a second episode's genuinely missing ring must not be suppressed by a prior episode's acknowledged, textually identical ring"
    pass "fm_idle_compact_ring_backstop: a prior episode's acknowledged ring never suppresses a later episode's missing ring"
  ) || exit 1
}

test_backstop_fires_at_most_once_per_episode() {
  (
    local dir log marker
    dir=$(new_dir backstop-once)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(arrange_done_declaring_pause "$dir" t1 1800)

    fm_idle_compact_process_task "$dir/state" t1 30
    backdate "$marker" 1800
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(wc -l < "$log")" = 1 ] \
      || fail "the backstop must re-send exactly once per episode, not on every later sweep"
    pass "fm_idle_compact_ring_backstop: the re-send happens at most once per episode"
  ) || exit 1
}

test_backstop_ignores_a_status_that_no_longer_declares_the_pause() {
  (
    local dir log marker
    dir=$(new_dir backstop-notdeclared)
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 'paused: no-mistakes run in progress, clears on its own'
    fm_idle_compact_task_context "$dir/state" t1
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")"
    backdate "$marker" 1800

    fm_idle_compact_process_task "$dir/state" t1 30
    [ ! -s "$log" ] \
      || fail "a worker waiting on a genuine external event must never be rung to start validation"
    pass "fm_idle_compact_ring_backstop: a status declaring some other wait is never rung"
  ) || exit 1
}

# --- the idle-duration basis (fm_idle_compact_activity_age) -----------------
# Requirement 2's threshold is measured from last activity, not from the status
# log alone: AGENTS.md's status-append protocol makes a status line a WAKE
# EVENT, written on wake-worthy transitions, so a crewmate steered back to
# work, doing it, and ending its turn leaves an hours-old status file untouched.

test_recent_turn_end_blocks_eligibility_despite_ancient_status() {
  (
    local dir
    dir=$(new_dir basis-turnend)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 10800 "needs-decision: which gate"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    : > "$dir/state/t1.turn-ended"

    fm_idle_compact_eligible "$dir/state" t1 30 \
      && fail "a crewmate that completed a turn seconds ago is not idle, however old its status log is"
    # ... and once that turn is itself hours old, it is idle again.
    backdate "$dir/state/t1.turn-ended" 10800
    fm_idle_compact_eligible "$dir/state" t1 30 \
      || fail "a crewmate whose newest activity of any kind is hours old must be eligible"
    pass "fm_idle_compact_eligible: the idle threshold is measured from the newest activity (turn-ended), not the status log alone"
  ) || exit 1
}

test_recent_spawn_record_blocks_eligibility() {
  (
    local dir
    dir=$(new_dir basis-meta)
    touch_status "$dir/state" t1 10800
    write_task_meta "$dir/state" t1
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")

    fm_idle_compact_eligible "$dir/state" t1 30 \
      && fail "a just-recorded spawn (a fresh incarnation behind an inherited status log) must not read as idle"
    pass "fm_idle_compact_eligible: a fresh spawn record counts as activity in the idle-duration basis"
  ) || exit 1
}

test_identical_repeated_status_append_ends_the_episode() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-identical-append)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 "blocked: waiting on the gate"
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    fm_idle_compact_task_context "$dir/state" t1
    status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)
    # shellcheck disable=SC2031  # read within the same subshell that just set it above
    pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=done "status_sig=$status_sig" "pane_sig=$pane_sig"

    # A SECOND, textually identical append: a genuinely new status line, and so
    # a genuine reset, even though the last line's text did not change.
    printf 'blocked: waiting on the gate\n' >> "$dir/state/t1.status"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a repeated, textually identical status append is still a new append and must end the episode"
    pass "fm_idle_compact_process_task: a repeated, textually identical status append still ends the episode"
  ) || exit 1
}

# --- induced-turn absorption (fm_idle_compact_absorbs_signal) --------------
# The episode-scoped, one-shot-per-send exemption bin/fm-watch.sh's signal
# triage asks this owner about. The watcher-side behavior (a wake really is
# suppressed, and a non-induced turn-end in the same window really does still
# wake) is proven end to end against a live watcher in
# tests/fm-watch-triage.test.sh; these cover the predicate's own arms.

# Marks <file>'s .seen-* suppressor as holding <sig>, i.e. "every byte in this
# file was already surfaced or deliberately absorbed" - the provenance state
# the absorption requires, through the production signature owner.
prime_seen() {  # <state> <file> <sig>
  printf '%s' "$3" > "$(fm_wake_signal_seen_path "$1" "$2")"
}

# Sets <file>'s mtime to an exact epoch, so a fixture can order two distinct
# turn-ends without sleeping through the signature's one-second resolution.
set_mtime_epoch() {  # <file> <epoch>
  touch -d "@$2" "$1"
}

# An in-flight save-sent episode whose induced save turn has just completed.
# Echoes the marker path.
arm_induced_turn() {  # <state> <task> <turn-ended-epoch>
  local state=$1 task=$2 epoch=$3 marker
  marker=$(fm_idle_compact_marker_path "$state" "$task")
  fm_idle_compact_marker_write "$marker" phase=save-sent \
    "sent_epoch=$(date +%s)" "baseline_turnended="
  prime_seen "$state" "$state/$task.turn-ended" ""
  : > "$state/$task.turn-ended"
  set_mtime_epoch "$state/$task.turn-ended" "$epoch"
  printf '%s' "$marker"
}

test_absorbs_the_induced_turn_exactly_once() {
  (
    local dir state marker now
    dir=$(new_dir absorb-once); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    marker=$(arm_induced_turn "$state" t1 "$((now - 5))")

    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      || fail "the turn-end induced by this episode's own save message must be absorbed"
    [ -n "$(fm_idle_compact_marker_field "$marker" absorbed_turnended)" ] \
      || fail "the absorbed turn's signature must be recorded on the episode marker"

    # The watcher scans twice across its signal grace window: re-seeing the
    # SAME signature is the same turn, not a second one.
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      || fail "re-seeing the same absorbed signature must stay absorbed (idempotent)"

    # A LATER turn-end in the same episode window is real crew work and must
    # wake the captain normally - this fence is the safety case for the whole
    # exemption.
    set_mtime_epoch "$state/t1.turn-ended" "$now"
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "a SECOND turn-end in the same episode window is not induced and must still wake"
    pass "fm_idle_compact_absorbs_signal: exactly one turn per induced send is absorbed; a later turn-end still wakes"
  ) || exit 1
}

test_never_absorbs_a_status_signal() {
  (
    local dir state now
    dir=$(new_dir absorb-status); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    arm_induced_turn "$state" t1 "$((now - 5))" >/dev/null
    printf 'blocked: gate is red\n' > "$state/t1.status"

    fm_idle_compact_absorbs_signal "$state" "$state/t1.status" \
      && fail "a status append is the crew's own captain-facing report and must never be absorbed"
    pass "fm_idle_compact_absorbs_signal: a status append is never absorbed, even mid-episode"
  ) || exit 1
}

test_absorbs_nothing_outside_an_in_flight_episode() {
  (
    local dir state marker now phase
    dir=$(new_dir absorb-expired); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    marker=$(arm_induced_turn "$state" t1 "$((now - 5))")

    rm -f "$marker"
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "with no episode marker at all, nothing may be absorbed (the feature-off case)"

    for phase in 'done' reset; do
      fm_idle_compact_marker_write "$marker" "phase=$phase"
      fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
        && fail "a finished episode (phase=$phase) must absorb nothing - the exemption expires with it"
    done

    # An in-flight episode whose send is older than the bound the state machine
    # abandons a never-completing save turn on has expired too.
    fm_idle_compact_marker_write "$marker" phase=save-sent \
      "sent_epoch=$((now - 5000))" "baseline_turnended="
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "a turn-end past FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS from its send is no longer provably induced"
    pass "fm_idle_compact_absorbs_signal: the exemption expires with the episode and with its send window"
  ) || exit 1
}

test_does_not_absorb_while_a_sweep_holds_the_lock() {
  (
    local dir state marker lock holder_pid now
    dir=$(new_dir absorb-lockheld); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    marker=$(arm_induced_turn "$state" t1 "$((now - 5))")

    # The signal path runs from the watcher's triage loop, not from the sweep,
    # so a concurrent supervisor (a DIFFERENT live pid - the same pid would
    # take fm_lock_try_acquire's self-held reclaim path) can be mid-sweep on
    # this very marker. Its write and this one must not interleave.
    lock=$(fm_idle_compact_lock_path "$state")
    ( fm_lock_try_acquire "$lock" && sleep 30 ) &
    holder_pid=$!
    for _ in $(seq 1 50); do
      [ -L "$lock" ] && break
      sleep 0.1
    done
    [ -L "$lock" ] || fail "fixture: background holder never acquired the sweep lock"

    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && { kill "$holder_pid" 2>/dev/null; fail "a turn-end must not be absorbed while a sweep holds the marker's lock"; }
    [ -z "$(fm_idle_compact_marker_field "$marker" absorbed_turnended)" ] \
      || { kill "$holder_pid" 2>/dev/null; fail "a locked-out absorption must not have rewritten the episode marker"; }

    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true

    # Released, the same signal is absorbed as before - the lock defers the
    # decision, it does not discard the episode.
    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      || fail "once the sweep lock is released the induced turn-end must be absorbed again"
    pass "fm_idle_compact_absorbs_signal: a sweep holding the idle-compact lock defers absorption instead of racing its marker write"
  ) || exit 1
}

test_does_not_absorb_over_an_unannounced_earlier_turn_end() {
  (
    local dir state now
    dir=$(new_dir absorb-unannounced); state="$dir/state"
    write_task_meta "$state" t1
    now=$(date +%s)
    arm_induced_turn "$state" t1 "$((now - 5))" >/dev/null
    # A turn-end the watcher never surfaced is still pending on this file, so
    # the recorded baseline no longer matches the .seen-* suppressor: the
    # signal is not provably ours and must wake.
    prime_seen "$state" "$state/t1.turn-ended" "0:1"

    fm_idle_compact_absorbs_signal "$state" "$state/t1.turn-ended" \
      && fail "an unannounced earlier turn-end on the same file must block absorption (fail toward waking)"
    pass "fm_idle_compact_absorbs_signal: an unannounced earlier turn-end blocks absorption"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_backstop_fires_on_a_stale_done_episode_with_no_ring_record
test_backstop_does_not_fire_on_a_fresh_done_episode
test_backstop_skips_when_the_inbox_already_holds_the_ring
test_backstop_skips_when_the_ring_was_already_acknowledged
test_backstop_ignores_a_prior_episodes_acknowledged_ring
test_backstop_fires_at_most_once_per_episode
test_backstop_ignores_a_status_that_no_longer_declares_the_pause

test_recent_turn_end_blocks_eligibility_despite_ancient_status
test_recent_spawn_record_blocks_eligibility
test_identical_repeated_status_append_ends_the_episode

test_absorbs_the_induced_turn_exactly_once
test_never_absorbs_a_status_signal
test_absorbs_nothing_outside_an_in_flight_episode
test_does_not_absorb_over_an_unannounced_earlier_turn_end
test_does_not_absorb_while_a_sweep_holds_the_lock

echo "all fm-idle-compact-backstop tests passed"
