#!/usr/bin/env bash
# tests/fm-idle-compact.test.sh - behavior tests for the opt-in idle-worker
# pre-cache-expiry compaction owner (bin/fm-idle-compact.sh), sourced
# identically by bin/fm-watch.sh's main loop and bin/fm-supervise-daemon.sh's
# housekeeping tick.
#
# Covers: config/idle-compact parsing (absent/empty/valid/invalid), the
# eligibility intersection (kind, harness, idle age, reconciled crew state -
# each exclusion arm on its own), the live safety gate (exact idle + exact
# empty composer only), and the 4-phase state machine marker lifecycle
# (no-marker -> save-sent -> settling -> done, the eligibility re-check
# before /compact, the post-render settle capture, and the
# reset-on-new-activity rule).
#
# Hermetic: fm_busy_classify, fm_backend_composer_state, and
# fm_idle_compact_send are function-overridden per test (the same dependency-
# injection idiom tests/fm-daemon.test.sh already uses for
# fm_backend_composer_state/pane_is_busy), and bin/fm-crew-state.sh is
# replaced via the FM_CREW_STATE_BIN override this file's eligibility check
# reads at call time. No real tmux, no real Claude session, no network.
# The vendor-rendered-signal proof this feature's action step ultimately
# depends on (a real idle Claude Code composer reading empty, and a real
# `/compact` submission landing) lives in the live-harness-optin guard,
# tests/fm-idle-compact-live-e2e.test.sh, per firstmate-coding-guidelines'
# two-test rule for harness-dependent checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-compact)

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

# --- config parsing (fm_idle_compact_threshold_minutes) --------------------

test_config_absent_is_disabled() {
  local dir out rc=0
  dir=$(new_dir config-absent)
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || rc=$?
  [ "$rc" -ne 0 ] || fail "an absent config/idle-compact must disable the feature"
  [ -z "$out" ] || fail "a disabled threshold must print nothing, got '$out'"
  pass "fm_idle_compact_threshold_minutes: absent config/idle-compact disables the feature"
}

test_config_empty_file_uses_default_15() {
  local dir out
  dir=$(new_dir config-empty)
  : > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "an empty-but-present file must enable the feature"
  [ "$out" = 15 ] || fail "expected the documented 15-minute default, got '$out'"
  pass "fm_idle_compact_threshold_minutes: an empty-but-present file enables the feature at the 15-minute default"
}

test_config_comment_only_uses_default_15() {
  local dir out
  dir=$(new_dir config-comment)
  printf '# just a comment\n\n# another\n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "a comment-only file must enable the feature"
  [ "$out" = 15 ] || fail "expected the documented 15-minute default, got '$out'"
  pass "fm_idle_compact_threshold_minutes: a comment-only file enables the feature at the 15-minute default"
}

test_config_valid_value_used_verbatim() {
  local dir out
  dir=$(new_dir config-valid)
  printf '  45  \n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "a valid positive integer must enable the feature"
  [ "$out" = 45 ] || fail "expected the configured value 45 (whitespace-trimmed), got '$out'"
  pass "fm_idle_compact_threshold_minutes: a valid positive integer is used verbatim, whitespace-trimmed"
}

test_config_invalid_value_disabled() {
  local dir val rc
  dir=$(new_dir config-invalid)
  for val in abc -5 1.5; do
    printf '%s\n' "$val" > "$dir/config/idle-compact"
    rc=0
    fm_idle_compact_threshold_minutes "$dir/config" >/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "invalid value '$val' must disable the feature, not enable it"
  done
  pass "fm_idle_compact_threshold_minutes: a non-positive-integer value disables the feature, same as absent"
}

test_config_whitespace_only_line_is_treated_as_empty() {
  local dir out
  dir=$(new_dir config-whitespace)
  printf '   \n\t\n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_threshold_minutes "$dir/config") || fail "a whitespace-only file has no non-blank content line, so it must behave like an empty file (enabled)"
  [ "$out" = 15 ] || fail "expected the documented 15-minute default, got '$out'"
  pass "fm_idle_compact_threshold_minutes: a whitespace-only file trims to no content and enables the feature at the default"
}

test_config_zero_disabled() {
  local dir rc=0
  dir=$(new_dir config-zero)
  printf '0\n' > "$dir/config/idle-compact"
  fm_idle_compact_threshold_minutes "$dir/config" >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a zero threshold must disable the feature"
  pass "fm_idle_compact_threshold_minutes: zero disables the feature"
}

# --- config parsing (fm_idle_compact_declared_settle_secs, issue #34) -------

test_declared_settle_absent_config_uses_60s_default() {
  local dir out
  dir=$(new_dir declared-settle-absent)
  out=$(fm_idle_compact_declared_settle_secs "$dir/config")
  [ "$out" = 60 ] || fail "an absent config/idle-compact must default the declared settle to 60s, got '$out'"
  pass "fm_idle_compact_declared_settle_secs: absent config/idle-compact defaults to 60s"
}

test_declared_settle_first_line_only_uses_60s_default() {
  local dir out
  dir=$(new_dir declared-settle-first-only)
  printf '30\n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_declared_settle_secs "$dir/config")
  [ "$out" = 60 ] || fail "a config with only the threshold-minutes line must default the declared settle to 60s, got '$out'"
  pass "fm_idle_compact_declared_settle_secs: a config with no second content line defaults to 60s"
}

test_declared_settle_second_line_used_verbatim() {
  local dir out
  dir=$(new_dir declared-settle-valid)
  printf '30\n  90  \n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_declared_settle_secs "$dir/config")
  [ "$out" = 90 ] || fail "expected the configured second-line value 90 (whitespace-trimmed), got '$out'"
  pass "fm_idle_compact_declared_settle_secs: a valid second content line is used verbatim, whitespace-trimmed"
}

test_declared_settle_second_line_skips_comments_and_blanks() {
  local dir out
  dir=$(new_dir declared-settle-comments)
  printf '# leading comment\n30\n\n# another comment\n120\n' > "$dir/config/idle-compact"
  out=$(fm_idle_compact_declared_settle_secs "$dir/config")
  [ "$out" = 120 ] || fail "expected the second CONTENT line 120 (comments and blanks skipped), got '$out'"
  pass "fm_idle_compact_declared_settle_secs: comment and blank lines do not count as content lines"
}

test_declared_settle_invalid_second_line_uses_60s_default() {
  local dir val out
  dir=$(new_dir declared-settle-invalid)
  for val in abc -5 1.5 0; do
    printf '30\n%s\n' "$val" > "$dir/config/idle-compact"
    out=$(fm_idle_compact_declared_settle_secs "$dir/config")
    [ "$out" = 60 ] || fail "invalid second-line value '$val' must fall back to the 60s default, got '$out'"
  done
  pass "fm_idle_compact_declared_settle_secs: an invalid second-line value falls back to the 60s default, never fails the caller"
}

# --- eligibility (fm_idle_compact_eligible) ---------------------------------

test_eligible_excludes_secondmate() {
  (
    local dir
    dir=$(new_dir elig-secondmate)
    write_task_meta "$dir/state" t1 claude secondmate
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a secondmate task must never be eligible (its idle pane is its normal healthy state)"
    fi
    pass "fm_idle_compact_eligible: kind=secondmate is always excluded"
  ) || exit 1
}

test_eligible_excludes_non_claude_harness() {
  (
    local dir h
    dir=$(new_dir elig-harness)
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    for h in codex opencode pi grok kimi muse; do
      write_task_meta "$dir/state" "t-$h" "$h" ship
      touch_status "$dir/state" "t-$h" 3600
      if fm_idle_compact_eligible "$dir/state" "t-$h" 30; then
        fail "harness=$h must be excluded - only claude has a verified /compact today"
      fi
    done
    pass "fm_idle_compact_eligible: every non-claude verified harness is excluded"
  ) || exit 1
}

test_eligible_excludes_idle_too_young() {
  (
    local dir
    dir=$(new_dir elig-young)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 60
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a status only 60s old must not clear a 30-minute threshold"
    fi
    pass "fm_idle_compact_eligible: idle duration under the threshold is excluded"
  ) || exit 1
}

test_eligible_excludes_missing_status() {
  (
    local dir
    dir=$(new_dir elig-nostatus)
    write_task_meta "$dir/state" t1
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a task with no status file yet must not be eligible"
    fi
    pass "fm_idle_compact_eligible: a missing status file excludes the task"
  ) || exit 1
}

test_eligible_excludes_missing_meta() {
  (
    local dir
    dir=$(new_dir elig-nometa)
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "a task with no meta file must not be eligible"
    fi
    pass "fm_idle_compact_eligible: a missing meta file excludes the task"
  ) || exit 1
}

test_eligible_excludes_non_wait_crew_states() {
  (
    local dir s
    dir=$(new_dir elig-crewstates)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    for s in working unknown failed; do
      FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: $s")
      if fm_idle_compact_eligible "$dir/state" t1 30; then
        fail "reconciled crew state '$s' must never be eligible - not a genuine long wait, or mid-task"
      fi
    done
    pass "fm_idle_compact_eligible: working, unknown, and failed are all excluded (never mid-task)"
  ) || exit 1
}

test_eligible_includes_every_wait_state() {
  (
    local dir s
    dir=$(new_dir elig-waitstates)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    for s in parked 'done' blocked paused; do
      FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: $s · source: run-step · detail")
      fm_idle_compact_eligible "$dir/state" t1 30 \
        || fail "reconciled crew state '$s' (with a realistic ' · source: ...' tail) should be eligible when otherwise idle long enough"
    done
    pass "fm_idle_compact_eligible: parked/done/blocked/paused are all eligible, tail content after the state word ignored"
  ) || exit 1
}

# --- declared-state fast path (fm_idle_compact_declared_paused) -------------

test_eligible_declared_state_bypasses_threshold() {
  (
    local dir
    dir=$(new_dir elig-declared)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validation'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    fm_idle_compact_eligible "$dir/state" t1 30 \
      || fail "the exact declared-state phrase must bypass the idle-minutes threshold even when the status is only 5s old"
    pass "fm_idle_compact_eligible: the declared-state phrase bypasses the idle-minutes threshold"
  ) || exit 1
}

test_eligible_declared_state_with_trailing_detail_bypasses_threshold() {
  (
    local dir
    dir=$(new_dir elig-declared-detail)
    write_task_meta "$dir/state" t1
    # The exact line pt-checkin-fidelity-lane8 appended on 2026-09-06: the brief
    # asks the worker to note its measured lane size, so trailing detail after
    # the phrase is the norm. A whole-line equality test missed it, dropped the
    # episode onto the ordinary path, and left the worker unrung for 60 minutes.
    touch_status "$dir/state" t1 5 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    fm_idle_compact_eligible "$dir/state" t1 30 \
      || fail "the declared-state phrase with trailing detail must bypass the idle-minutes threshold"
    pass "fm_idle_compact_eligible: the declared-state phrase bypasses the threshold with trailing detail after it"
  ) || exit 1
}

test_eligible_declared_phrase_must_end_on_a_word_boundary() {
  (
    local dir
    dir=$(new_dir elig-declared-boundary)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validationX of the fixtures'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "the prefix match must end on a word boundary, not swallow a longer word"
    fi
    pass "fm_idle_compact_eligible: the declared-phrase prefix match requires a word boundary after it"
  ) || exit 1
}

test_eligible_other_paused_text_still_gated_by_threshold() {
  (
    local dir
    dir=$(new_dir elig-declared-other)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: waiting on an upstream release'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    if fm_idle_compact_eligible "$dir/state" t1 30; then
      fail "any other paused: text must still be gated by the ordinary idle-minutes threshold"
    fi
    pass "fm_idle_compact_eligible: any paused: text that does not start with the declared phrase gets no bypass"
  ) || exit 1
}

# --- live safety gate (fm_idle_compact_safe_to_send) ------------------------

test_safe_to_send_requires_exact_idle() {
  (
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "a busy verdict must refuse the send"
    fi
    fm_busy_classify() { printf 'unknown none'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "an unproven unknown verdict must refuse the send, not just busy"
    fi
    pass "fm_idle_compact_safe_to_send: only an exact idle busy verdict permits proceeding"
  ) || exit 1
}

test_safe_to_send_requires_exact_empty_composer() {
  (
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'pending'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "a pending composer must refuse the send"
    fi
    fm_backend_composer_state() { printf 'unknown'; }
    if fm_idle_compact_safe_to_send /nonexistent-state t1; then
      fail "an unknown composer verdict must refuse the send"
    fi
    pass "fm_idle_compact_safe_to_send: only an exact empty composer verdict permits proceeding"
  ) || exit 1
}

test_safe_to_send_true_when_idle_and_empty() {
  (
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    fm_idle_compact_safe_to_send /nonexistent-state t1 \
      || fail "an exact idle verdict plus an exact empty composer must permit the send"
    pass "fm_idle_compact_safe_to_send: idle + empty together permit the send"
  ) || exit 1
}

# --- 4-phase marker state machine (fm_idle_compact_process_task) -----------
# fm_busy_classify/fm_backend_composer_state are stubbed idle+empty (safe
# throughout) unless a test says otherwise; fm_idle_compact_send is stubbed
# to record calls to a log file, decoupling the state machine from
# bin/fm-send.sh's own real delivery mechanics (separately owned/tested).

stub_always_safe() {
  fm_busy_classify() { printf 'idle claude-hook'; }
  fm_backend_composer_state() { printf 'empty'; }
}

stub_recording_send() {  # <logfile>
  local log=$1
  # shellcheck disable=SC2317  # invoked indirectly by the state-machine functions under test
  fm_idle_compact_send() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$log"; return 0; }
}

test_no_marker_eligible_sends_save_and_marks_savesent() {
  (
    local dir log marker
    dir=$(new_dir sm-firstsend)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ -f "$marker" ] || fail "a first eligible+safe sweep must write the marker"
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "the marker must record phase=save-sent after the first send"
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one send (the save message) must have gone out"
    grep -q "precompact-notes.md" "$log" || fail "the save message must point at precompact-notes.md"
    grep -q "key file paths" "$log" || fail "the save message must ask for key file paths (the documented save-content list)"
    pass "fm_idle_compact_process_task: no marker + eligible + safe sends the save message and records phase=save-sent"
  ) || exit 1
}

test_no_marker_ineligible_creates_no_marker() {
  (
    local dir log marker
    dir=$(new_dir sm-ineligible)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: working")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ ! -e "$marker" ] || fail "an ineligible (working) task must never get a marker"
    [ ! -s "$log" ] || fail "an ineligible task must never be sent anything"
    pass "fm_idle_compact_process_task: an ineligible task (mid-task) is left untouched"
  ) || exit 1
}

test_no_marker_unsafe_pane_defers_no_send() {
  (
    local dir log marker
    dir=$(new_dir sm-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ ! -e "$marker" ] || fail "an eligible task with a busy pane must not get a marker yet"
    [ ! -s "$log" ] || fail "a busy pane must never be sent anything"
    pass "fm_idle_compact_process_task: eligible but unsafe (busy pane) defers to a later sweep, never sends"
  ) || exit 1
}

test_no_marker_declared_state_skips_save_sends_compact_directly() {
  (
    local dir log marker
    dir=$(new_dir sm-declared)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validation'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = settling ] \
      || fail "the declared-state fast path must jump straight to phase=settling, skipping phase=save-sent"
    [ "$(fm_idle_compact_marker_field "$marker" declared)" = 1 ] \
      || fail "the marker must record declared=1 so the settle transition knows to ring the worker"
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one send (a direct /compact) must have gone out, no notes-save message"
    [ "$(cut -f2 "$log")" = t1 ] || fail "the declared-state send must target t1"
    case "$(cut -f3 "$log")" in
      '/compact '*) : ;;
      *) fail "the declared-state send must be a literal /compact command" ;;
    esac
    grep -q "branch fm/t1" "$log" || fail "the declared-state /compact focus text must name the branch"
    grep -q "brief.md" "$log" || fail "the declared-state /compact focus text must name the brief path"
    grep -q "mode=" "$log" || fail "the declared-state /compact focus text must name the delivery contract"
    pass "fm_idle_compact_process_task: the declared-state phrase skips the notes-save turn and sends /compact directly"
  ) || exit 1
}

test_no_marker_declared_state_ignored_when_pane_unsafe() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 5 'paused: awaiting compaction before validation'
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"

    fm_idle_compact_process_task "$dir/state" t1 30
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    [ ! -e "$marker" ] || fail "the declared-state fast path must still respect the live safety gate"
    [ ! -s "$log" ] || fail "a busy pane must never be sent anything, declared state or not"
    pass "fm_idle_compact_process_task: the declared-state fast path still defers to the live safety gate"
  ) || exit 1
}

test_settling_declared_rings_worker_on_done() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1" declared=1

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window a declared episode must still advance to phase=done"
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one ring message must go out on the declared settle->done transition"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "the ring message must tell the worker to start the validation run now"
    pass "fm_idle_compact_process_task: a declared episode rings the worker with an inbox message once it settles to phase=done"
  ) || exit 1
}

test_settling_declared_unsafe_pane_still_rings() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-ring-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    # shellcheck disable=SC2329 # invoked indirectly through fm_idle_compact_safe_to_send
    fm_busy_classify() { printf 'busy claude-hook'; }
    # shellcheck disable=SC2329 # invoked indirectly through fm_idle_compact_safe_to_send
    fm_backend_composer_state() { printf 'pending'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1" declared=1

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "a durable ring must not be deferred by a live pane verdict"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "the ring is an inbox record, so a busy pane is exactly the case it exists for"
    pass "fm_idle_compact_process_task: the post-settle ring is durable and goes out even over a busy pane"
  ) || exit 1
}

test_settling_declared_send_failure_stays_settling() {
  (
    local dir marker
    dir=$(new_dir sm-declared-ring-fail)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    stub_always_safe
    # shellcheck disable=SC2329 # invoked indirectly through fm_idle_compact_ring_worker
    fm_idle_compact_send() { return 1; }
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1" declared=1

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "the episode must advance to phase=done only after the ring record exists"
    pass "fm_idle_compact_process_task: a failed ring enqueue keeps the episode in phase=settling for a later sweep"
  ) || exit 1
}

test_settling_ordinary_path_rings_a_worker_still_declaring_the_pause() {
  (
    local dir log marker
    dir=$(new_dir sm-ordinary-declared-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600 \
      'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # No declared=1: the ordinary save-then-compact path, which is the path both
    # 2026-09-06 lanes took because their status lines carried trailing detail.
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1"

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window the episode must still advance to phase=done"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "a worker whose status still declares the compaction pause must be rung whichever path the episode took"
    pass "fm_idle_compact_process_task: the ordinary path also rings a worker whose status still declares the compaction pause"
  ) || exit 1
}

test_settling_declared_default_60s_not_yet_elapsed_stays_settling() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-default-wait)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # settle_epoch 10s ago: inside the 60s declared default, so no explicit
    # FM_IDLE_COMPACT_SETTLE_SECS override and no declared-settle-secs arg -
    # this is the fast path's own default, not a test-forced value.
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(( $(date +%s) - 10 ))" declared=1

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "10s into the 60s declared default the episode must still be waiting, not already rung"
    [ ! -s "$log" ] || fail "nothing should be sent before the declared settle window elapses"
    pass "fm_idle_compact_process_task: the declared path's own 60s default is not satisfied by a 10s-old settle_epoch"
  ) || exit 1
}

test_settling_declared_default_60s_elapsed_rings_worker() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-default-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # settle_epoch 61s ago, past the 60s declared default - no
    # FM_IDLE_COMPACT_SETTLE_SECS override and no declared-settle-secs arg.
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(( $(date +%s) - 61 ))" declared=1

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the 60s declared default the episode must advance to phase=done without any override"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "the ring must go out once the default declared settle window elapses"
    pass "fm_idle_compact_process_task: the declared path rings on its own 60s default with no config or env override"
  ) || exit 1
}

test_settling_declared_configured_settle_secs_honored() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-configured)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(( $(date +%s) - 10 ))" declared=1

    # A configured declared-settle-secs of 5, passed as fm_idle_compact_tick
    # would (config/idle-compact's second content line) - 10s past send is
    # already past a 5s window.
    fm_idle_compact_process_task "$dir/state" t1 30 5
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "a configured declared-settle-secs of 5 must be honored over the 60s built-in default"
    grep -q 'compacted - start the validation run now' "$log" \
      || fail "the ring must go out once the configured declared settle window elapses"
    pass "fm_idle_compact_process_task: a configured declared-settle-secs argument overrides the 60s built-in default"
  ) || exit 1
}

test_settling_declared_configured_settle_secs_not_yet_elapsed() {
  (
    local dir log marker
    dir=$(new_dir sm-declared-configured-wait)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(( $(date +%s) - 10 ))" declared=1

    # A configured declared-settle-secs of 120 must extend PAST the 60s
    # built-in default, not just leave it in place.
    fm_idle_compact_process_task "$dir/state" t1 30 120
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "a configured declared-settle-secs of 120 must be honored even though it exceeds the 60s built-in default"
    [ ! -s "$log" ] || fail "nothing should be sent before the configured declared settle window elapses"
    pass "fm_idle_compact_process_task: a configured declared-settle-secs argument can extend past the 60s built-in default"
  ) || exit 1
}

test_settling_ordinary_path_ignores_declared_settle_arg() {
  (
    local dir log marker
    dir=$(new_dir sm-ordinary-ignores-declared-settle)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # No declared=1: an ordinary episode. A tiny declared-settle-secs arg (5)
    # must NOT shorten the ordinary path's own FM_IDLE_COMPACT_INTERVAL wait.
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(( $(date +%s) - 10 ))"

    FM_IDLE_COMPACT_INTERVAL=3600 fm_idle_compact_process_task "$dir/state" t1 30 5
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'settling' ] \
      || fail "the ordinary path's settle wait must come from FM_IDLE_COMPACT_INTERVAL, never the declared-settle-secs arg"
    [ ! -s "$log" ] || fail "an ordinary episode must not send anything before its own interval elapses"
    pass "fm_idle_compact_process_task: the declared-settle-secs argument is scoped to declared episodes only"
  ) || exit 1
}

test_tick_computes_and_threads_declared_settle_from_config() {
  (
    local dir marker
    dir=$(new_dir tick-declared-settle-config)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    stub_always_safe
    # shellcheck disable=SC2329 # invoked indirectly through fm_idle_compact_send
    fm_idle_compact_send() { return 0; }
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: paused")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(( $(date +%s) - 10 ))" declared=1
    # Threshold minutes on the first content line, declared-settle-secs 5 on
    # the second - fm_idle_compact_tick must read both from the same file and
    # thread the second through to the settling transition.
    printf '30\n5\n' > "$dir/config/idle-compact"

    fm_idle_compact_tick "$dir/state" "$dir/config"
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "fm_idle_compact_tick must read config/idle-compact's second content line and honor it as the declared settle seconds"
    pass "fm_idle_compact_tick: reads the declared-settle-secs override from config/idle-compact and threads it through"
  ) || exit 1
}

test_settling_non_declared_never_rings_worker() {
  (
    local dir log marker
    dir=$(new_dir sm-nondeclared-ring)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1"

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window an ordinary episode must still advance to phase=done"
    [ ! -s "$log" ] || fail "an ordinary (non-declared) episode must never send a ring message on settle->done"
    pass "fm_idle_compact_process_task: an ordinary episode settling to phase=done never rings the worker"
  ) || exit 1
}

test_savesent_no_turnended_yet_stays_savesent() {
  (
    local dir log marker
    dir=$(new_dir sm-waiting)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "with no new turn-ended signature, the marker must stay phase=save-sent"
    [ ! -s "$log" ] || fail "/compact must not be sent before the save turn completes"
    pass "fm_idle_compact_process_task: phase=save-sent waits for a new turn-ended signature before compacting"
  ) || exit 1
}

test_savesent_turnended_advanced_sends_compact_and_marks_settling() {
  (
    local dir log marker
    dir=$(new_dir sm-advance)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="
    touch "$dir/state/t1.turn-ended"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = settling ] \
      || fail "a new turn-ended signature must advance the marker to phase=settling"
    case "$(fm_idle_compact_marker_field "$marker" settle_epoch)" in
      ''|*[!0-9]*) fail "phase=settling must record a numeric settle_epoch" ;;
    esac
    [ "$(wc -l < "$log")" = 1 ] || fail "exactly one send (the /compact message) must have gone out"
    [ "$(cut -f2 "$log")" = t1 ] || fail "the send must target task t1"
    case "$(cut -f3 "$log")" in
      '/compact '*) ;;
      *) fail "the sent message must be a literal /compact command with focus text" ;;
    esac
    grep -q "brief.md" "$log" || fail "the /compact focus text must point at the brief"
    grep -q "precompact-notes.md" "$log" || fail "the /compact focus text must point at the precompact notes"
    pass "fm_idle_compact_process_task: a completed save turn sends /compact with focus text and records phase=settling"
  ) || exit 1
}

test_savesent_turnended_advanced_but_unsafe_defers() {
  (
    local dir log marker
    dir=$(new_dir sm-advance-unsafe)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'busy claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="
    touch "$dir/state/t1.turn-ended"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "a completed save turn into a now-busy pane must not advance past save-sent"
    [ ! -s "$log" ] || fail "/compact must never be sent while the pane reads busy"
    pass "fm_idle_compact_process_task: a completed save turn into an unsafe pane defers /compact to a later sweep"
  ) || exit 1
}

test_savesent_turnended_advanced_but_crew_working_defers() {
  (
    local dir log marker
    dir=$(new_dir sm-advance-midtask)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: working")
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=$(date +%s)" "baseline_turnended="
    touch "$dir/state/t1.turn-ended"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "a save-wait interrupted by new work (crew state working) must not advance past save-sent"
    [ ! -s "$log" ] || fail "/compact must never be sent while the reconciled crew state reads working, even between turns"
    pass "fm_idle_compact_process_task: a turn-ended advance from unrelated mid-task work never triggers /compact (eligibility is re-checked)"
  ) || exit 1
}

test_settling_within_window_defers_capture() {
  (
    local dir log marker
    dir=$(new_dir sm-settling-wait)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=$(date +%s)"

    FM_IDLE_COMPACT_SETTLE_SECS=3600 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = settling ] \
      || fail "inside the settle window the marker must stay phase=settling (no baseline captured yet)"
    [ -z "$(fm_idle_compact_marker_field "$marker" pane_sig)" ] \
      || fail "no pane signature may be captured before the compaction render has settled"
    [ ! -s "$log" ] || fail "phase=settling must never send anything"
    pass "fm_idle_compact_process_task: phase=settling inside the settle window defers baseline capture to a later sweep"
  ) || exit 1
}

test_settling_past_window_records_done_and_next_sweep_is_noop() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-settling-done)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # settle_epoch long past: by now the compaction summary has rendered, so
    # the pane content captured below already includes it.
    fm_idle_compact_marker_write "$marker" phase=settling "settle_epoch=1"

    FM_IDLE_COMPACT_SETTLE_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "past the settle window the marker must advance to phase=done"
    fm_idle_compact_task_context "$dir/state" t1
    status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)
    # shellcheck disable=SC2031  # read within the same subshell that just set it above
    pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")
    [ "$(fm_idle_compact_marker_field "$marker" status_sig)" = "$status_sig" ] \
      || fail "phase=done must record the CURRENT (post-render) status signature"
    [ "$(fm_idle_compact_marker_field "$marker" pane_sig)" = "$pane_sig" ] \
      || fail "phase=done must record the CURRENT (post-render) pane signature"
    [ ! -s "$log" ] || fail "settling into phase=done must never send anything"

    # The self-trigger regression: the very next sweep sees its own baseline
    # as unchanged and must NOT start a new save+compact episode.
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "the sweep after settling must keep phase=done, not restart the episode"
    [ ! -s "$log" ] || fail "the compaction's own settled output must never re-trigger a save message"
    pass "fm_idle_compact_process_task: the post-render baseline is captured at settle expiry and the episode never self-triggers"
  ) || exit 1
}

test_savesent_timeout_abandons_without_compact() {
  (
    local dir log marker
    dir=$(new_dir sm-timeout)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # sent long ago, save turn never completed (no turn-ended touch)
    fm_idle_compact_marker_write "$marker" phase=save-sent "sent_epoch=1" "baseline_turnended="

    FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS=1 fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "a save turn that never completes must be abandoned to phase=done past the timeout"
    [ ! -s "$log" ] || fail "an abandoned episode must never send /compact"
    case "$(fm_idle_compact_marker_field "$marker" settle_epoch)" in
      ''|*[!0-9]*) fail "the abandon path must stamp a numeric settle_epoch so the ring backstop scopes to this episode" ;;
    esac
    pass "fm_idle_compact_process_task: a save turn that never completes is abandoned past FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS, without ever sending /compact, and stamps settle_epoch"
  ) || exit 1
}

test_done_unchanged_signatures_is_noop() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-done-noop)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
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

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = 'done' ] \
      || fail "unchanged status and pane signatures must leave the marker at phase=done"
    [ ! -s "$log" ] || fail "an unchanged phase=done episode must never send anything again"
    pass "fm_idle_compact_process_task: phase=done with unchanged status/pane signatures is a pure no-op (already compacted this episode)"
  ) || exit 1
}

test_done_status_change_clears_marker_and_restarts_episode() {
  (
    local dir log marker status_sig pane_sig
    dir=$(new_dir sm-done-restart)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
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

    # A new status append ends the episode. The append is fresh (a real crew
    # writes one now, not an hour ago), so the sweep that observes it must
    # stamp the reset and start no new episode yet.
    printf 'blocked: new episode\n' >> "$dir/state/t1.status"

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a new status append must end the episode and leave a phase=reset activity stamp"
    [ ! -s "$log" ] || fail "a crewmate that just appended a status must not be sent anything on that same sweep"

    # One full idle window later - with nothing further from the crew - the
    # stamp has aged out and the next episode starts.
    backdate "$marker" 3600
    backdate "$dir/state/t1.status" 3600
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = save-sent ] \
      || fail "once the reset stamp has aged past the threshold, a fresh episode must start"
    [ "$(wc -l < "$log")" = 1 ] || fail "a fresh episode must send exactly one new save message"
    pass "fm_idle_compact_process_task: a new status append ends the episode and the next one waits out a full fresh idle window"
  ) || exit 1
}

test_reset_stamp_holds_off_a_new_episode_for_a_full_window() {
  (
    local dir log marker
    dir=$(new_dir sm-reset-holdoff)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 7200
    log="$dir/sends.log"; : > "$log"
    stub_always_safe
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: parked")
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    # Pane activity was observed a minute ago: the status log is ancient, but
    # this crewmate is not idle - its cache is warm and compacting it now is
    # exactly the waste this feature exists to avoid.
    fm_idle_compact_marker_write "$marker" phase=reset
    backdate "$marker" 60

    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a fresh reset stamp must keep holding off the next episode"
    [ ! -s "$log" ] || fail "an ancient status log must not make a just-active crewmate eligible"
    pass "fm_idle_compact_process_task: a fresh pane-activity reset stamp holds off the next episode for a full idle window"
  ) || exit 1
}

test_done_pane_change_clears_marker() {
  (
    local dir log marker status_sig
    dir=$(new_dir sm-done-panechange)
    write_task_meta "$dir/state" t1
    touch_status "$dir/state" t1 3600
    log="$dir/sends.log"; : > "$log"
    fm_busy_classify() { printf 'idle claude-hook'; }
    fm_backend_composer_state() { printf 'empty'; }
    stub_recording_send "$log"
    FM_IDLE_COMPACT_CREW_STATE_BIN=$(write_crew_state_stub "$dir" "state: working")
    fm_idle_compact_task_context "$dir/state" t1
    status_sig=$(fm_idle_compact_status_sig "$dir/state" t1)
    marker=$(fm_idle_compact_marker_path "$dir/state" t1)
    fm_idle_compact_marker_write "$marker" phase=done "status_sig=$status_sig" "pane_sig=stale-pane-sig"

    # Status unchanged, but pane content changed (fm_backend_capture output
    # differs from the fixed stale_pane_sig recorded above) - reconcile as
    # "not eligible right now" (crew state is 'working'), which still must
    # clear the stale marker rather than silently keep it.
    fm_idle_compact_process_task "$dir/state" t1 30
    [ "$(fm_idle_compact_marker_field "$marker" phase)" = reset ] \
      || fail "a changed pane signature must end the phase=done episode even when the crew is not currently eligible"
    pass "fm_idle_compact_process_task: a changed pane signature alone ends phase=done, independent of status"
  ) || exit 1
}

# --- run ---------------------------------------------------------------------

test_config_absent_is_disabled
test_config_empty_file_uses_default_15
test_config_comment_only_uses_default_15
test_config_valid_value_used_verbatim
test_config_invalid_value_disabled
test_config_whitespace_only_line_is_treated_as_empty
test_config_zero_disabled

test_declared_settle_absent_config_uses_60s_default
test_declared_settle_first_line_only_uses_60s_default
test_declared_settle_second_line_used_verbatim
test_declared_settle_second_line_skips_comments_and_blanks
test_declared_settle_invalid_second_line_uses_60s_default

test_eligible_excludes_secondmate
test_eligible_excludes_non_claude_harness
test_eligible_excludes_idle_too_young
test_eligible_excludes_missing_status
test_eligible_excludes_missing_meta
test_eligible_excludes_non_wait_crew_states
test_eligible_includes_every_wait_state

test_eligible_declared_state_bypasses_threshold
test_eligible_declared_state_with_trailing_detail_bypasses_threshold
test_eligible_declared_phrase_must_end_on_a_word_boundary
test_eligible_other_paused_text_still_gated_by_threshold

test_safe_to_send_requires_exact_idle
test_safe_to_send_requires_exact_empty_composer
test_safe_to_send_true_when_idle_and_empty

test_no_marker_eligible_sends_save_and_marks_savesent
test_no_marker_ineligible_creates_no_marker
test_no_marker_unsafe_pane_defers_no_send
test_no_marker_declared_state_skips_save_sends_compact_directly
test_no_marker_declared_state_ignored_when_pane_unsafe
test_settling_declared_rings_worker_on_done
test_settling_declared_unsafe_pane_still_rings
test_settling_declared_send_failure_stays_settling
test_settling_ordinary_path_rings_a_worker_still_declaring_the_pause
test_settling_declared_default_60s_not_yet_elapsed_stays_settling
test_settling_declared_default_60s_elapsed_rings_worker
test_settling_declared_configured_settle_secs_honored
test_settling_declared_configured_settle_secs_not_yet_elapsed
test_settling_ordinary_path_ignores_declared_settle_arg
test_tick_computes_and_threads_declared_settle_from_config
test_settling_non_declared_never_rings_worker
test_savesent_no_turnended_yet_stays_savesent
test_savesent_turnended_advanced_sends_compact_and_marks_settling
test_savesent_turnended_advanced_but_unsafe_defers
test_savesent_turnended_advanced_but_crew_working_defers
test_savesent_timeout_abandons_without_compact
test_settling_within_window_defers_capture
test_settling_past_window_records_done_and_next_sweep_is_noop
test_done_unchanged_signatures_is_noop
test_done_status_change_clears_marker_and_restarts_episode
test_done_pane_change_clears_marker
test_reset_stamp_holds_off_a_new_episode_for_a_full_window

echo "all fm-idle-compact tests passed"
