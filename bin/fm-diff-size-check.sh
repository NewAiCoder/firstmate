#!/usr/bin/env bash
# Worker-facing lane size check. Usage: fm-diff-size-check.sh <worktree>
# Prints "<changed lines> changed lines across <n> files: <verdict>".
# Exit 0 always: a worker's own measurement must never end its turn.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-diff-size-lib.sh
. "$SCRIPT_DIR/fm-diff-size-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

WT=$(cd "${1:-.}" && pwd)
BASE=""
BRANCH=$(fm_default_branch "$WT") || BRANCH=""
if [ -n "$BRANCH" ]; then
    BASE=$(git -C "$WT" rev-parse --verify --quiet "origin/$BRANCH" 2>/dev/null) \
        || BASE=$(git -C "$WT" rev-parse --verify --quiet "$BRANCH" 2>/dev/null)
fi

if [ -z "$BASE" ]; then
    printf 'cannot measure: no default branch found (checked origin/HEAD, main, master)\n'
    exit 0
fi

read -r LINES FILES <<< "$(fm_diff_size "$WT" "$BASE")"
printf '%s changed lines across %s files: %s\n' \
    "$LINES" "$FILES" "$(fm_diff_size_verdict "$LINES")"
exit 0
