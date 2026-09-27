#!/usr/bin/env bash
# Live drive of the jj-aware self-update path (bin/fm-update.sh -> bin/fm-ff-lib.sh
# ff_target_jj) against the real product binaries from the gate worktree, with the
# real pinned jj 0.45.1, on real jj colocated homes. No test seams, no mocks.
#
# Each scenario builds an isolated world (bare origin + firstmate clone + home),
# drives the real bin/fm-update.sh exactly as the fleet does, and asserts the
# observable outcome: reported status vocabulary, reread verdict, and that
# nothing was relocated, discarded, or stranded.
set -u
umask 022

ROOT=/Users/hotthoughts/.no-mistakes/worktrees/afc49cb2f7e6/01M3GNVVWD3J92VSTQQQWQ3B1H
UPDATE="$ROOT/bin/fm-update.sh"
EVID=/Users/hotthoughts/.no-mistakes/evidence/01M3GNVVWD3J92VSTQQQWQ3B1H
LOG="$EVID/jj-live-update-transcript-3.txt"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-jj-live3.XXXXXX")
trap 'rm -rf "$T"' EXIT

: > "$LOG"
note() { printf '%s\n' "$*" >> "$LOG"; }
fail() { note "LIVE DRIVE FAIL: $1"; printf 'LIVE DRIVE FAIL: %s\n' "$1" >&2; FAILED=1; }
check() { # <label> <cmd...> - cmd must exit 0 to pass
  local label=$1; shift
  if "$@" 2>/dev/null; then note "-- $label: yes"; else note "-- $label: NO"; fail "$label"; fi
}
has() { printf '%s' "$1" | grep -qF -- "$2"; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2"; }
eq() { [ "$1" = "$2" ]; }

jjid() { jj -R "$1" log -r "$2" --no-graph -T 'commit_id' 2>/dev/null; }
jjid7() { jj -R "$1" log -r "$2" --no-graph -T 'commit_id.short(7)' 2>/dev/null; }
jjempty() { jj -R "$1" log -r '@' --no-graph -T 'empty' 2>/dev/null; }
jjdesc() { jj -R "$1" log -r "$2" --no-graph -T 'description.first_line()' 2>/dev/null; }
jjlog() { jj -R "$1" log --no-graph -T 'commit_id.short(7) ++ " " ++ if(description.first_line(), description.first_line(), "") ++ " " ++ bookmarks ++ "\n"' 2>/dev/null; }
filecontent() { cat "$1" 2>/dev/null; }

export GIT_AUTHOR_NAME=live-test GIT_AUTHOR_EMAIL=live-test@example.com
export GIT_COMMITTER_NAME=live-test GIT_COMMITTER_EMAIL=live-test@example.com

# Bare origin seeded with one commit (AGENTS.md v1, README, bin/, .agents/skills),
# a firstmate clone on main, and a home dir. Echoes the world dir.
new_world() {
  local name=$1 w
  w="$T/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$w/main" config user.name live-test
  git -C "$w/main" config user.email live-test@example.com
  printf '%s\n' "$w"
}

# jj-colocate the main checkout (the fleet home shape this change is about).
jj_colocate() {
  local w=$1
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 )
}

bump_origin() { # <w> <mode: instr|readme>
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

# Run the real self-update against the fixture home, with the gate env stripped.
run_update() {
  local w=$1
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u NO_MISTAKES_GATE \
      -u TASKS_AXI_FILE -u TASKS_AXI_BACKEND \
      FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE"
}

# Show one scenario's product output + before/after jj state in the transcript.
show() { # <w> <out>
  local w=$1 out=$2
  note "---- product output (real bin/fm-update.sh) ----"
  note "$out"
  note "---- jj state after ----"
  note "$(jjlog "$w/main" | sed 's/^/--   /')"
}

note "live drive of bin/fm-update.sh on jj colocated homes (jj $(jj --version), target e90972e)"
note "fixture root: $T"
FAILED=0

# ============================================================================
note ""
note "===== S0 - git-home report form (the 'same form' baseline) ====="
w=$(new_world s0)
bump_origin "$w" instr
out=$(run_update "$w")
note "$out"
check "git home reports updated" has "$out" "firstmate: updated "
check "git home reports instructions changed" has "$out" "(instructions changed: AGENTS.md, bin, .agents/skills)"
check "git home reread yes" has "$out" "reread-firstmate: yes"
check "git home HEAD at origin/main" eq "$(git -C "$w/main" rev-parse HEAD)" "$(git -C "$w/main" rev-parse origin/main)"

# ============================================================================
note ""
note "===== S1 - clean jj colocated home behind origin advances (required outcome) ====="
w=$(new_world s1)
jj_colocate "$w"
bump_origin "$w" instr
note "---- jj state before ----"
note "$(jjlog "$w/main" | sed 's/^/--   /')"
before7=$(jjid7 "$w/main" '@')
out=$(run_update "$w")
base7=$(jjid7 "$w/main" 'main@origin')
check "reports updated in the git-home form" has "$out" "firstmate: updated $before7..$base7"
check "reports instructions changed like a git home" has "$out" "(instructions changed: AGENTS.md, bin, .agents/skills)"
check "reread-firstmate yes" has "$out" "reread-firstmate: yes"
check "default bookmark moved to origin tip" eq "$(jjid "$w/main" main)" "$(jjid "$w/main" 'main@origin')"
check "working copy clean (empty) after advance" eq "$(jjempty "$w/main")" "true"
check "files at target content (AGENTS.md v2)" eq "$(filecontent "$w/main/AGENTS.md")" "v2"
show "$w" "$out"

# ============================================================================
note ""
note "===== S2 - already-current clean jj home reports already current ====="
w=$(new_world s2)
jj_colocate "$w"
main_before=$(jjid "$w/main" main)
at_before=$(jjid "$w/main" '@')
out=$(run_update "$w")
check "reports already current" has "$out" "firstmate: already current"
check "no reread when nothing changed" has "$out" "reread-firstmate: no"
check "bookmark untouched" eq "$(jjid "$w/main" main)" "$main_before"
check "working copy untouched" eq "$(jjid "$w/main" '@')" "$at_before"
show "$w" "$out"

# ============================================================================
note ""
note "===== S3 - dirty jj home (unlanded edit) is skipped, work preserved ====="
w=$(new_world s3)
jj_colocate "$w"
bump_origin "$w" instr
printf 'uncommitted local edit\n' >> "$w/main/AGENTS.md"
main_before=$(jjid "$w/main" main)
at_before=$(jjid "$w/main" '@')
out=$(run_update "$w")
check "skipped with dirty-working-tree vocabulary" has "$out" "firstmate: skipped: dirty working tree"
check "never advanced" lacks "$out" "firstmate: updated "
check "no reread on skip" has "$out" "reread-firstmate: no"
check "bookmark untouched" eq "$(jjid "$w/main" main)" "$main_before"
check "working copy untouched" eq "$(jjid "$w/main" '@')" "$at_before"
check "unlanded edit preserved" has "$(filecontent "$w/main/AGENTS.md")" "uncommitted local edit"
show "$w" "$out"

# ============================================================================
note ""
note "===== S4 - diverged jj home is skipped, local commit preserved, never forced ====="
w=$(new_world s4)
jj_colocate "$w"
printf 'fork work\n' > "$w/main/AGENTS.md"
jj -R "$w/main" commit -m local-work >/dev/null 2>&1
jj -R "$w/main" bookmark set main -r @- >/dev/null 2>&1
bump_origin "$w" instr
main_before=$(jjid "$w/main" main)
out=$(run_update "$w")
check "skipped with diverged vocabulary" has "$out" "firstmate: skipped: diverged from main@origin"
check "never advanced" lacks "$out" "firstmate: updated "
check "no reread on skip" has "$out" "reread-firstmate: no"
check "diverged bookmark commit preserved" eq "$(jjid "$w/main" main)" "$main_before"
check "diverged work preserved on disk" has "$(filecontent "$w/main/AGENTS.md")" "fork work"
check "local commit still exists (not discarded)" test -n "$(jjid "$w/main" "$main_before")"
show "$w" "$out"

# ============================================================================
note ""
note "===== S5 - described-but-empty working copy ('jj describe -m wip', no edits) ====="
w=$(new_world s5)
jj_colocate "$w"
bump_origin "$w" instr
jj -R "$w/main" describe -m wip >/dev/null 2>&1
at_before=$(jjid "$w/main" '@')
main_before=$(jjid "$w/main" main)
note "---- jj state before ----"
note "$(jjlog "$w/main" | sed 's/^/--   /')"
note "-- @ empty = $(jjempty "$w/main"); @ desc = $(jjdesc "$w/main" '@')"
out=$(run_update "$w")
check "reports the description-based skip" has "$out" "firstmate: skipped: described working copy commit"
check "never mislabeled dirty" lacks "$out" "firstmate: skipped: dirty working tree"
check "never advanced" lacks "$out" "firstmate: updated "
check "no reread on skip" has "$out" "reread-firstmate: no"
check "working copy untouched" eq "$(jjid "$w/main" '@')" "$at_before"
check "bookmark untouched" eq "$(jjid "$w/main" main)" "$main_before"
check "description preserved" eq "$(jjdesc "$w/main" '@')" "wip"
check "files untouched (still v1)" eq "$(filecontent "$w/main/AGENTS.md")" "v1"
show "$w" "$out"

# ============================================================================
note ""
note "===== S5b - described-but-empty via 'jj commit -m wip' with no edits ====="
note "-- (real jj 0.45.1 leaves @ empty/undescribed and the described empty wip at @-)"
w=$(new_world s5b)
jj_colocate "$w"
bump_origin "$w" instr
jj -R "$w/main" commit -m wip >/dev/null 2>&1
at_before=$(jjid "$w/main" '@')
wip_before=$(jjid "$w/main" '@-')
main_before=$(jjid "$w/main" main)
note "---- jj state before ----"
note "$(jjlog "$w/main" | sed 's/^/--   /')"
note "-- @ empty = $(jjempty "$w/main"); @ desc = '$(jjdesc "$w/main" '@')'; @- desc = '$(jjdesc "$w/main" '@-')'"
out=$(run_update "$w")
check "skipped for the right reason (stranded described commit at @-)" has "$out" "firstmate: skipped: working copy parked outside main@origin"
check "never mislabeled dirty" lacks "$out" "firstmate: skipped: dirty working tree"
check "never advanced" lacks "$out" "firstmate: updated "
check "no reread on skip" has "$out" "reread-firstmate: no"
check "working copy untouched" eq "$(jjid "$w/main" '@')" "$at_before"
check "bookmark untouched" eq "$(jjid "$w/main" main)" "$main_before"
check "wip commit preserved at @-" eq "$(jjid "$w/main" '@-')" "$wip_before"
check "wip description preserved" eq "$(jjdesc "$w/main" '@-')" "wip"
check "files untouched (still v1)" eq "$(filecontent "$w/main/AGENTS.md")" "v1"
show "$w" "$out"

# ============================================================================
note ""
note "===== S5c - described NON-empty working copy reports the description reason ====="
w=$(new_world s5c)
jj_colocate "$w"
bump_origin "$w" instr
printf 'wip edit\n' >> "$w/main/AGENTS.md"
jj -R "$w/main" describe -m wip >/dev/null 2>&1
at_before=$(jjid "$w/main" '@')
out=$(run_update "$w")
check "reports the description-based skip" has "$out" "firstmate: skipped: described working copy commit"
check "never mislabeled dirty" lacks "$out" "firstmate: skipped: dirty working tree"
check "working copy untouched" eq "$(jjid "$w/main" '@')" "$at_before"
check "description preserved" eq "$(jjdesc "$w/main" '@')" "wip"
check "edit preserved" has "$(filecontent "$w/main/AGENTS.md")" "wip edit"
show "$w" "$out"

# ============================================================================
note ""
note "===== S6 - working copy parked outside the target is skipped, commit preserved ====="
w=$(new_world s6)
jj_colocate "$w"
bump_origin "$w" instr
printf 'parked work\n' >> "$w/main/AGENTS.md"
jj -R "$w/main" commit -m parked >/dev/null 2>&1
at_before=$(jjid "$w/main" '@')
parked_before=$(jjid "$w/main" '@-')
main_before=$(jjid "$w/main" main)
out=$(run_update "$w")
check "skipped with parked-outside vocabulary" has "$out" "firstmate: skipped: working copy parked outside main@origin"
check "never advanced" lacks "$out" "firstmate: updated "
check "no reread on skip" has "$out" "reread-firstmate: no"
check "bookmark untouched" eq "$(jjid "$w/main" main)" "$main_before"
check "working copy untouched" eq "$(jjid "$w/main" '@')" "$at_before"
check "parked commit left behind at @-" eq "$(jjid "$w/main" '@-')" "$parked_before"
check "parked work preserved on disk" has "$(filecontent "$w/main/AGENTS.md")" "parked work"
check "parked commit still exists (nothing stranded)" test -n "$(jjid "$w/main" "$parked_before")"
show "$w" "$out"

# ============================================================================
note ""
note "===== S7 - one plain empty 'jj new' above the base advances instead of wedging ====="
w=$(new_world s7)
jj_colocate "$w"
jj -R "$w/main" new >/dev/null 2>&1
at_before=$(jjid "$w/main" '@')
main_before=$(jjid "$w/main" main)
note "---- jj state before ----"
note "$(jjlog "$w/main" | sed 's/^/--   /')"
out=$(run_update "$w")
check "reports updated (not wedged)" has "$out" "firstmate: updated "
check "no reread (served files unchanged)" has "$out" "reread-firstmate: no"
check "bookmark stays at origin tip" eq "$(jjid "$w/main" main)" "$main_before"
check "new working copy is an empty child of the base" eq "$(jjempty "$w/main")" "true"
check "served files unchanged (still v1)" eq "$(filecontent "$w/main/AGENTS.md")" "v1"
check "previous working-copy commit still exists (not discarded)" test -n "$(jjid "$w/main" "$at_before")"
show "$w" "$out"

# ============================================================================
note ""
note "===== S8 - reread verdict baselines on the working copy, not the bookmark ====="
note "-- (bookmark behind origin, @ parked on the old commit whose files the home serves)"
w=$(new_world s8)
jj_colocate "$w"
bump_origin "$w" instr
run_update "$w" >/dev/null 2>&1
jj -R "$w/main" new 'main@origin-' >/dev/null 2>&1
bump_origin "$w" readme
at_before=$(jjid7 "$w/main" '@')
note "---- jj state before ----"
note "$(jjlog "$w/main" | sed 's/^/--   /')"
note "-- served AGENTS.md = $(filecontent "$w/main/AGENTS.md")"
out=$(run_update "$w")
check "advance reported in the git-home form" has "$out" "firstmate: updated $at_before.."
check "instruction list reflects the working-copy baseline" has "$out" "(instructions changed: AGENTS.md, bin, .agents/skills)"
check "reread-firstmate yes" has "$out" "reread-firstmate: yes"
check "bookmark at origin tip" eq "$(jjid "$w/main" main)" "$(jjid "$w/main" 'main@origin')"
check "files at target content" eq "$(filecontent "$w/main/AGENTS.md")" "v2"
show "$w" "$out"

# ============================================================================
note ""
note "===== S9 - a diverged jj SECONDMATE home is skipped with no durable reconcile record ====="
w=$(new_world s9)
git clone -q "$w/origin.git" "$w/sm1"
git -C "$w/sm1" config user.name live-test
git -C "$w/sm1" config user.email live-test@example.com
( cd "$w/sm1" && jj git init --colocate >/dev/null 2>&1 )
printf 'sm1\n' > "$w/sm1/.fm-secondmate-home"
printf 'fork work\n' > "$w/sm1/AGENTS.md"
jj -R "$w/sm1" commit -m local-work >/dev/null 2>&1
jj -R "$w/sm1" bookmark set main -r @- >/dev/null 2>&1
{
  printf 'window=main:fm-sm1\n'
  printf 'endpoint_task_id=sm1\n'
  printf 'worktree=%s/sm1\n' "$w"
  printf 'project=%s/sm1\n' "$w"
  printf 'kind=secondmate\n'
  printf 'harness=claude\n'
  printf 'home=%s/sm1\n' "$w"
} > "$w/home/state/sm1.meta"
bump_origin "$w" instr
sm1_main_before=$(jjid "$w/sm1" main)
out=$(run_update "$w")
check "git firstmate still advances" has "$out" "firstmate: updated "
check "jj secondmate skipped with diverged vocabulary" has "$out" "secondmate sm1: skipped: diverged from main@origin"
check "jj secondmate never advanced" lacks "$out" "secondmate sm1: updated "
check "no durable reconcile record for a jj home (documented carve-out)" \
  test ! -e "$w/home/state/.secondmate-update-reconcile/sm1.pending"
check "jj secondmate bookmark preserved" eq "$(jjid "$w/sm1" main)" "$sm1_main_before"
check "jj secondmate fork work preserved" has "$(filecontent "$w/sm1/AGENTS.md")" "fork work"
check "skipped jj secondmate gets no restart claim" has "$out" "restart-secondmates: none"
note "$out"

note ""
if [ "$FAILED" -eq 0 ]; then
  note "ALL LIVE SCENARIOS PASSED"
else
  note "LIVE DRIVE HAD FAILURES - SEE ABOVE"
fi
printf 'driver exit: FAILED=%s\n' "$FAILED" >&2
exit "$FAILED"
