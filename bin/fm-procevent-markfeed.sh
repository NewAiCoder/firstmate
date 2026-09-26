#!/usr/bin/env bash
# Mark-feed process-event adapter.
#
# Usage:
#   fm-procevent-markfeed.sh arm [--name <slug>] -- <poll-command> [<arg>...]
#   fm-procevent-markfeed.sh poll -- <poll-command> [<arg>...]
#   fm-procevent-markfeed.sh classify <result-file>
#   fm-procevent-markfeed.sh terminal <result-file>
#   fm-procevent-markfeed.sh silent <result-file>
#   fm-procevent-markfeed.sh source-id [<slug>]
#   fm-procevent-markfeed.sh retire [<slug>]
#
# A mark feed is a page-side stream of owner clicks. Its poll command blocks
# until the next mark, prints one line per mark, and exits:
#
#   mark <surface> <slug> <kind> <item> <value> [session=<8 chars>]
#
# This adapter registers that command as a source so each batch of marks arrives
# as one durable `check: procevent:markfeed:<seq>` wake.
#
# arm        Register the operator-supplied poll command. It must be an absolute
#            path to an executable file; everything after `--` is its argv, stored
#            one argument per line and executed directly with no shell. --name
#            names a second feed (source id `markfeed-<slug>`); without it the
#            source id is `markfeed`. Example:
#              fm-procevent-markfeed.sh arm -- /absolute/path/to/poll-script [args...]
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. It runs the poll command once and
#            prints a result document: a header this adapter writes, then `output:`,
#            then the accepted mark lines.
# classify   Print the outcome class: marks, idle, error, or unknown.
# terminal   Exit 0 only for `error`, so a broken poll command stops the source
#            and wakes once instead of waking on every restart. Re-arm after
#            fixing it. `marks`, `idle` and `unknown` keep the source armed.
# silent     Exit 0 for `idle` (clean exit, nothing printed): the runner records
#            it handled without a wake and restarts the poll.
# source-id  Print the canonical source id.
# retire     Stop the watch and retire the registration.
#
# Mark lines are data. Only lines that start with `mark ` are kept, control
# characters are stripped, each line is capped at 1024 bytes and a batch at 200
# lines; nothing is evaluated, interpolated into a shell, or used as a path.
# The header is written by this adapter before `output:`, and classification reads
# only that header, so a mark line can never forge an outcome. Marks printed by a
# command that then exits non-zero are still delivered, with the exit status
# recorded in the header.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

SOURCE_ID_BASE=markfeed
MAX_LINES=200
MAX_LINE_BYTES=1024

CANONICAL_SOURCE_ID=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

resolve_source() {
  local LC_ALL=C name=${1:-}
  if [ -n "$name" ]; then
    [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "invalid name: $name"
    CANONICAL_SOURCE_ID="$SOURCE_ID_BASE-$name"
  else
    CANONICAL_SOURCE_ID=$SOURCE_ID_BASE
  fi
  fm_procevent_source_id_valid "$CANONICAL_SOURCE_ID" || die "source id is not path-safe: $CANONICAL_SOURCE_ID"
}

# check_command <path>: the poll command must be an absolute executable file.
check_command() {
  case "$1" in
    /*) ;;
    *) die "the poll command must be an absolute path: $1" ;;
  esac
  case "$1" in *$'\n'*) die "the poll command path cannot contain newlines" ;; esac
  [ -f "$1" ] && [ -x "$1" ] || die "the poll command is not an executable file: $1"
}

cmd_source_id() {
  resolve_source "${1-}"
  printf '%s\n' "$CANONICAL_SOURCE_ID"
}

cmd_arm() {
  local name=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ -n "${2-}" ] || die "--name needs a value"; name=$2; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ "$#" -ge 1 ] || usage
  resolve_source "$name"
  check_command "$1"
  "$SCRIPT_DIR/fm-procevent.sh" register markfeed "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-markfeed.sh" poll -- "$@" || exit 1
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'command: %s\n' "$1"
}

# One run of the poll command. Always exits 0 so the runner captures the result;
# a non-zero exit with no output would otherwise be an uncaptured no-result that
# re-arms silently and hides a broken command.
cmd_poll() {
  [ "${1-}" = -- ] || usage
  shift
  [ "$#" -ge 1 ] || usage
  local raw rc marks status
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-markfeed-poll.XXXXXX") || die "cannot stage the poll output"
  # shellcheck disable=SC2064 # expand now, while the staged path is set.
  trap "rm -f -- '$raw'" EXIT
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # expand now, while both are set.
    trap "rm -f -- '$raw'; trap - $signal; kill -$signal $$" "$signal"
  done
  "$@" >"$raw" 2>/dev/null </dev/null
  rc=$?
  marks=$(LC_ALL=C tr -d '\000-\010\013-\037\177' <"$raw" \
    | LC_ALL=C awk -v max="$MAX_LINES" -v cap="$MAX_LINE_BYTES" '
        /^mark / && n < max { n++; print substr($0, 1, cap) }
      ')
  local count=0
  [ -z "$marks" ] || count=$(printf '%s\n' "$marks" | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    status=marks
  elif [ "$rc" -eq 0 ]; then
    status=idle
  else
    status=error
  fi
  printf 'status: %s\n' "$status"
  printf 'exit: %s\n' "$rc"
  printf 'marks: %s\n' "$count"
  printf 'output:\n'
  [ "$count" -eq 0 ] || printf '%s\n' "$marks"
  exit 0
}

result_status() {
  awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(result_status "$file")
  case "$status" in
    marks|idle|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = error ]
}

cmd_silent() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = idle ]
}

cmd_retire() {
  resolve_source "${1-}"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$CANONICAL_SOURCE_ID"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  source-id) shift; cmd_source_id "${1-}" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
