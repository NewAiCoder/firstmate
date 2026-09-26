#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-markfeed.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-markfeed.XXXXXX")

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# A stand-in poll command whose behavior the test selects through its first argument.
POLL="$LAB/poll"
cat > "$POLL" <<'SH'
#!/usr/bin/env bash
case "$1" in
  marks)   printf 'mark decide 2026-09-26-x card-1 choice yes session=abcd1234\n'
           printf 'mark ledger 2026-09-25-y task-2 done true\n' ;;
  idle)    ;;
  fail)    exit 3 ;;
  partial) printf 'mark decide s c k v\n'; exit 4 ;;
  noise)   printf 'not a mark\nstatus: error\nmark ok line\n' ;;
  hostile) printf 'mark decide s $(touch %s/pwned) `touch %s/pwned2` ; touch %s/pwned3 | && \\n' "$2" "$2" "$2" ;;
esac
SH
chmod +x "$POLL"

run_poll() { "$BIN/fm-procevent-markfeed.sh" poll -- "$POLL" "$@"; }
classify_of() { printf '%s\n' "$1" > "$LAB/result"; "$BIN/fm-procevent-markfeed.sh" classify "$LAB/result"; }

if help=$("$BIN/fm-procevent-markfeed.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-markfeed.sh arm [--name <slug>] -- <poll-command>' \
  || fail "help omitted the arm usage"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders only the complete header"

out=$(run_poll marks)
[ "$(classify_of "$out")" = marks ] || fail "printed marks did not classify as marks"
printf '%s\n' "$out" | grep -qx 'marks: 2' || fail "mark count missing"
printf '%s\n' "$out" | grep -qx 'mark decide 2026-09-26-x card-1 choice yes session=abcd1234' || fail "mark line not carried"
printf '%s\n' "$out" > "$LAB/result"
"$BIN/fm-procevent-markfeed.sh" terminal "$LAB/result" && fail "marks result ended the source"
"$BIN/fm-procevent-markfeed.sh" silent "$LAB/result" && fail "marks result was silent"
ok "a mark line wakes and keeps the source armed"

out=$(run_poll idle)
[ "$(classify_of "$out")" = idle ] || fail "clean empty exit did not classify as idle"
printf '%s\n' "$out" > "$LAB/result"
"$BIN/fm-procevent-markfeed.sh" silent "$LAB/result" || fail "idle result was not silent"
"$BIN/fm-procevent-markfeed.sh" terminal "$LAB/result" && fail "idle result ended the source"
ok "a clean exit with no output is a silent re-arm"

out=$(run_poll fail); rc=$?
[ "$rc" -eq 0 ] || fail "poll must exit zero so the runner captures a failure, got $rc"
[ "$(classify_of "$out")" = error ] || fail "failing poll command did not classify as error"
printf '%s\n' "$out" | grep -qx 'exit: 3' || fail "exit status not recorded"
printf '%s\n' "$out" > "$LAB/result"
"$BIN/fm-procevent-markfeed.sh" terminal "$LAB/result" || fail "error result did not stop the source"
"$BIN/fm-procevent-markfeed.sh" silent "$LAB/result" && fail "error result was silent"
ok "a failing poll command surfaces as a source failure"

out=$(run_poll partial)
[ "$(classify_of "$out")" = marks ] || fail "marks before a failing exit were dropped"
printf '%s\n' "$out" | grep -qx 'exit: 4' || fail "partial exit status not recorded"
ok "marks printed before a non-zero exit are still delivered"

out=$(run_poll noise)
printf '%s\n' "$out" | grep -qx 'marks: 1' || fail "non-mark lines were counted"
[ "$(printf '%s\n' "$out" | sed -n 's/^status: //p')" = marks ] || fail "output line forged the header"
[ "$(printf '%s\n' "$out" | grep -c '^status:')" -eq 1 ] || fail "non-mark line leaked into the result"
ok "only mark lines are kept and cannot forge the header"

out=$(run_poll hostile "$LAB")
[ "$(classify_of "$out")" = marks ] || fail "hostile mark line did not classify as marks"
printf '%s\n' "$out" | grep -Fq -- "\$(touch" || fail "hostile text was not carried verbatim"
for f in pwned pwned2 pwned3; do
  [ ! -e "$LAB/$f" ] || fail "hostile mark line executed: $f"
done
printf '%s\n' "$out" > "$LAB/result"
"$BIN/fm-procevent-markfeed.sh" classify "$LAB/result" >/dev/null
ok "a hostile mark line is inert data"

if err=$("$BIN/fm-procevent-markfeed.sh" arm -- relative-poll 2>&1); then
  fail "relative poll command unexpectedly armed"
fi
[ "$err" = "error: the poll command must be an absolute path: relative-poll" ] || fail "relative command returned: $err"
if err=$("$BIN/fm-procevent-markfeed.sh" arm -- "$LAB/missing" 2>&1); then
  fail "missing poll command unexpectedly armed"
fi
[ "$err" = "error: the poll command is not an executable file: $LAB/missing" ] || fail "missing command returned: $err"
if err=$("$BIN/fm-procevent-markfeed.sh" arm --name Bad_Name -- "$POLL" 2>&1); then
  fail "invalid name unexpectedly armed"
fi
[ "$err" = "error: invalid name: Bad_Name" ] || fail "invalid name returned: $err"
ok "arm requires an absolute executable command and a slug name"

[ "$("$BIN/fm-procevent-markfeed.sh" source-id)" = markfeed ] || fail "default source id"
[ "$("$BIN/fm-procevent-markfeed.sh" source-id ledger)" = markfeed-ledger ] || fail "named source id"
ok "source ids are canonical"

export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
out=$("$BIN/fm-procevent-markfeed.sh" arm --name t -- "$POLL" idle) || fail "arm failed: $out"
printf '%s\n' "$out" | grep -qx 'armed: markfeed-t' || fail "arm did not report the source: $out"
"$BIN/fm-procevent.sh" list 2>/dev/null | grep -q 'markfeed-t' || fail "armed source not registered"
out=$("$BIN/fm-procevent-markfeed.sh" retire t)
[ "$out" = "retired: markfeed-t" ] || fail "retire returned: $out"
ok "arm registers and retire removes the source"

printf '# all fm-procevent-markfeed tests passed\n'
