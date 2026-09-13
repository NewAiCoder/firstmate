#!/usr/bin/env bash
# Lane size measurement, its verdicts, and the telemetry row it records.
set -u
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# shellcheck source=bin/fm-diff-size-lib.sh
. "$ROOT/bin/fm-diff-size-lib.sh"

say() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; FAIL=1; fi; }

WT="$TMP/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" config user.email t@t
git -C "$WT" config user.name t
printf 'a\n' > "$WT/base.txt"
git -C "$WT" add base.txt
git -C "$WT" commit -q -m base
BASE=$(git -C "$WT" rev-parse HEAD)

git -C "$WT" checkout -q -b lane
seq 1 120 > "$WT/one.txt"
seq 1 30  > "$WT/two.txt"
git -C "$WT" add one.txt two.txt
git -C "$WT" commit -q -m lane

read -r LINES FILES <<< "$(fm_diff_size "$WT" "$BASE")"
say "changed lines counted" "150" "$LINES"
say "files counted" "2" "$FILES"

say "400 is ok"            "ok"          "$(fm_diff_size_verdict 400)"
say "401 is over target"   "over-target" "$(fm_diff_size_verdict 401)"
say "800 is over target"   "over-target" "$(fm_diff_size_verdict 800)"
say "801 is over cap"      "over-cap"    "$(fm_diff_size_verdict 801)"

read -r LINES FILES <<< "$(fm_diff_size /does/not/exist "$BASE")"
say "a missing worktree yields zeros, never a failure" "0" "$LINES"

DB="$TMP/usage.sqlite"
# Recorded schema lives at ~/.claude/telemetry/store.py, a personal harness
# file outside this repo that a fresh CI checkout never has. This test only
# needs the one table fm-lane-size-record.sh writes to, so it creates that
# table itself instead of depending on host state a portable test can't rely on.
python3 - "$DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("""
    CREATE TABLE IF NOT EXISTS lanes (
        host          TEXT    NOT NULL,
        pr_url        TEXT    NOT NULL,
        project       TEXT,
        task_id       TEXT,
        changed_lines INTEGER NOT NULL,
        files_changed INTEGER NOT NULL,
        opened_at     TEXT    NOT NULL,
        PRIMARY KEY (host, pr_url)
    )
""")
conn.commit()
conn.close()
PY
TELEMETRY_DB="$DB" bash "$ROOT/bin/fm-lane-size-record.sh" \
    demo-task "$WT" "$BASE" "https://github.com/o/r/pull/7"
GOT=$(python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute('SELECT changed_lines, files_changed, pr_url FROM lanes').fetchone())
" "$DB")
case "$GOT" in
  *"150, 2, 'https://github.com/o/r/pull/7'"*) echo "ok - lane row recorded" ;;
  *) echo "FAIL - lane row wrong: $GOT"; FAIL=1 ;;
esac

TELEMETRY_DB=/nope/nope.sqlite bash "$ROOT/bin/fm-lane-size-record.sh" \
    demo-task "$WT" "$BASE" "https://x/1"
say "an unusable store is not a failure" "0" "$?"

# A worktree that doesn't exist, or a base ref that doesn't resolve in it
# (e.g. a registered PR whose worktree was already torn down, or one that
# never fetched origin/HEAD), is an unresolved measurement, not a real
# zero-line lane. Recording it as "0 0" would corrupt the size/rounds
# telemetry, so both cases must be skipped rather than stored.
TELEMETRY_DB="$DB" bash "$ROOT/bin/fm-lane-size-record.sh" \
    demo-task-missing-wt "/does/not/exist" "$BASE" "https://github.com/o/r/pull/8"
GOT=$(python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute('SELECT 1 FROM lanes WHERE pr_url=?', (sys.argv[2],)).fetchone())
" "$DB" "https://github.com/o/r/pull/8")
say "a missing worktree records no lane row" "None" "$GOT"

TELEMETRY_DB="$DB" bash "$ROOT/bin/fm-lane-size-record.sh" \
    demo-task-bad-base "$WT" "not-a-real-ref" "https://github.com/o/r/pull/9"
GOT=$(python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute('SELECT 1 FROM lanes WHERE pr_url=?', (sys.argv[2],)).fetchone())
" "$DB" "https://github.com/o/r/pull/9")
say "an unresolvable base ref records no lane row" "None" "$GOT"

# A base ref can resolve to a real commit in the worktree yet still share no
# history with HEAD (e.g. origin/HEAD rewritten onto unrelated history after
# a force-push): "base...HEAD" then has no merge base and the diff itself
# fails. fm_diff_size swallows that failure into the same "0 0" it returns
# for a genuine zero-line lane, so this must still be skipped, not stored.
UNRELATED="$TMP/unrelated"
mkdir -p "$UNRELATED"
git -C "$UNRELATED" init -q -b other
git -C "$UNRELATED" config user.email t@t
git -C "$UNRELATED" config user.name t
printf 'z\n' > "$UNRELATED/z.txt"
git -C "$UNRELATED" add z.txt
git -C "$UNRELATED" commit -q -m unrelated
UNRELATED_HEAD=$(git -C "$UNRELATED" rev-parse HEAD)
git -C "$WT" fetch -q "$UNRELATED" "$UNRELATED_HEAD:refs/unrelated-head"

TELEMETRY_DB="$DB" bash "$ROOT/bin/fm-lane-size-record.sh" \
    demo-task-unrelated-history "$WT" refs/unrelated-head "https://github.com/o/r/pull/10"
GOT=$(python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute('SELECT 1 FROM lanes WHERE pr_url=?', (sys.argv[2],)).fetchone())
" "$DB" "https://github.com/o/r/pull/10")
say "a base with no common history records no lane row" "None" "$GOT"

# fm-diff-size-check.sh is the worker-facing entry point (Rule 8): it must
# resolve the same base branch the rest of the fleet does (fm_default_branch:
# origin/HEAD, then local main, then local master) instead of falling back to
# a bare HEAD, which would silently diff HEAD against itself and always
# report zero changed lines for a real lane.
MASTER_WT="$TMP/master-wt"
mkdir -p "$MASTER_WT"
git -C "$MASTER_WT" init -q -b master
git -C "$MASTER_WT" config user.email t@t
git -C "$MASTER_WT" config user.name t
printf 'a\n' > "$MASTER_WT/base.txt"
git -C "$MASTER_WT" add base.txt
git -C "$MASTER_WT" commit -q -m base

git -C "$MASTER_WT" checkout -q -b lane
seq 1 50 > "$MASTER_WT/one.txt"
git -C "$MASTER_WT" add one.txt
git -C "$MASTER_WT" commit -q -m lane

OUT=$(bash "$ROOT/bin/fm-diff-size-check.sh" "$MASTER_WT")
say "diff-size-check falls back to local master, no origin" \
    "50 changed lines across 1 files: ok" "$OUT"

# No origin/HEAD, no local main, no local master: the base branch genuinely
# cannot be resolved, so the check must say so rather than fabricate a
# zero-line "ok" by diffing HEAD against itself.
NOBASE_WT="$TMP/nobase-wt"
mkdir -p "$NOBASE_WT"
git -C "$NOBASE_WT" init -q -b trunk
git -C "$NOBASE_WT" config user.email t@t
git -C "$NOBASE_WT" config user.name t
printf 'a\n' > "$NOBASE_WT/base.txt"
git -C "$NOBASE_WT" add base.txt
git -C "$NOBASE_WT" commit -q -m base

git -C "$NOBASE_WT" checkout -q -b lane
seq 1 50 > "$NOBASE_WT/one.txt"
git -C "$NOBASE_WT" add one.txt
git -C "$NOBASE_WT" commit -q -m lane

OUT=$(bash "$ROOT/bin/fm-diff-size-check.sh" "$NOBASE_WT")
RC=$?
say "diff-size-check reports unresolved base rather than a fake zero" \
    "cannot measure: no default branch found (checked origin/HEAD, main, master)" "$OUT"
say "diff-size-check still exits 0 with no resolvable base" "0" "$RC"

exit "$FAIL"
