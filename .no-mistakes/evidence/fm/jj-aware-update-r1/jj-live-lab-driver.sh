#!/usr/bin/env bash
# jj-live-lab-driver.sh - live drive of bin/fm-update.sh against jj colocated
# firstmate homes, run by the no-mistakes Test phase on 2026-09-27.
#
# Each scenario mints a disposable marked lab home (bin/fm-lab-home.sh), builds
# a real repo world from the gate worktree's own history (base 30ef650 = "old
# upstream", target 84e0c00 = "current upstream"), and drives the real product
# script bin/fm-update.sh with real jj 0.45.1. Every fixture lives under a
# fresh mktemp dir and is removed in the same run.
#
# Usage: bash jj-live-lab-driver.sh <evidence-dir> [scenario-name ...]
#   (no scenario names = run all)
set -u

WT=/Users/hotthoughts/.no-mistakes/worktrees/afc49cb2f7e6/01M3G5Q3WK7884EBNB49PWRP4F
BASE=30ef650d7ee93cbaaf2ce63c6cac9b1a7890d81e
TARGET=84e0c0051a0a5aae4460e8319a584b7a49b293dc
EVID="${1:?usage: jj-live-lab-driver.sh <evidence-dir> [scenario ...]}"
shift
SELECTED="${*:-}"

run_scenario() { # <name>
  if [ -n "$SELECTED" ]; then
    case " $SELECTED " in *" $1 "*) : ;; *) return 0 ;; esac
  fi
  echo "===== scenario: $1 ====="
  "s_$1"
}

die() { echo "FAIL: $*" >&2; exit 1; }
grep_q() { grep -qF -- "$2" "$1" || die "$1 missing: $2"; }

# Fresh world: marked lab home + bare origin (main=OLD) + clone checked out at
# OLD. Echoes the world dir.
new_world() {
  local parent
  parent=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$parent/home" >/dev/null || die "lab home create"
  git clone -q --bare "$WT" "$parent/origin.git" 2>/dev/null || die "bare clone"
  git -C "$parent/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$parent/origin.git" update-ref refs/heads/main "$BASE"
  git clone -q "$parent/origin.git" "$parent/main" 2>/dev/null || die "main clone"
  printf '%s\n' "$parent"
}

# Advance the world's upstream to TARGET and refresh the jj home's remote view
# when it is already colocated.
advance_origin() { # <world>
  git -C "$1/origin.git" update-ref refs/heads/main "$TARGET"
}

run_update() { # <world> [extra jj prep already done]
  local w=$1
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    "$WT/bin/fm-update.sh" >"$w/update.out" 2>&1
}

teardown() { # <world>
  rm -rf "$1"
}

s_jj_behind_advances() {
  local w
  w=$(new_world)
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  advance_origin "$w"
  jj -R "$w/main" log -r '@' --no-graph -T 'commit_id' >"$EVID/s1-jj-behind-before-wc.txt"
  run_update "$w"
  cp "$w/update.out" "$EVID/s1-jj-behind-update.txt"
  grep_q "$EVID/s1-jj-behind-update.txt" "firstmate: updated "
  grep_q "$EVID/s1-jj-behind-update.txt" "..84e0c00 (instructions changed: bin, .agents/skills)"
  grep_q "$EVID/s1-jj-behind-update.txt" "reread-firstmate: yes"
  grep_q "$EVID/s1-jj-behind-update.txt" "restart-secondmates: none"
  {
    echo "--- jj home state after update ---"
    jj -R "$w/main" log -r main --no-graph -T 'commit_id ++ " " ++ description.first_line() ++ "\n"' | head -3
    echo "main == main@origin: $([ "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" = "$(jj -R "$w/main" log -r main@origin --no-graph -T 'commit_id')" ] && echo yes || echo NO)"
    echo "working copy empty: $(jj -R "$w/main" log -r '@' --no-graph -T 'empty')"
    echo "working copy parent == main tip: $([ "$(jj -R "$w/main" log -r 'parents(@)' --no-graph -T 'commit_id')" = "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" ] && echo yes || echo NO)"
    echo "target-only file present: $([ -f "$w/main/bin/fm-install-jj.sh" ] && echo yes || echo NO)"
    echo "skill doc at target content: $(grep -c 'jj colocated home advances through the jj fast-forward path' "$w/main/.agents/skills/updatefirstmate/SKILL.md")"
  } >"$EVID/s1-jj-behind-state.txt" 2>&1
  cat "$EVID/s1-jj-behind-state.txt"
  [ "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" = "$TARGET" ] || die "bookmark not at target"
  [ "$(jj -R "$w/main" log -r '@' --no-graph -T 'empty')" = "true" ] || die "working copy not clean"
  [ -f "$w/main/bin/fm-install-jj.sh" ] || die "files not advanced"
  teardown "$w"
  echo "PASS s_jj_behind_advances"
}

s_jj_already_current() {
  local w
  w=$(new_world)
  git -C "$w/origin.git" update-ref refs/heads/main "$TARGET"
  git clone -q "$w/origin.git" "$w/main2" 2>/dev/null && rm -rf "$w/main" && mv "$w/main2" "$w/main"
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  run_update "$w"
  cp "$w/update.out" "$EVID/s2-jj-current-update.txt"
  grep_q "$EVID/s2-jj-current-update.txt" "firstmate: already current"
  grep_q "$EVID/s2-jj-current-update.txt" "reread-firstmate: no"
  cat "$EVID/s2-jj-current-update.txt"
  teardown "$w"
  echo "PASS s_jj_already_current"
}

s_jj_dirty_skipped() {
  local w
  w=$(new_world)
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  advance_origin "$w"
  printf 'unlanded local edit\n' >>"$w/main/AGENTS.md"
  run_update "$w"
  cp "$w/update.out" "$EVID/s3-jj-dirty-update.txt"
  grep_q "$EVID/s3-jj-dirty-update.txt" "firstmate: skipped: dirty working tree"
  {
    echo "bookmark still at old base: $([ "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" = "$BASE" ] && echo yes || echo NO)"
    echo "unlanded line preserved: $(grep -c 'unlanded local edit' "$w/main/AGENTS.md")"
    echo "working copy still non-empty: $(jj -R "$w/main" log -r '@' --no-graph -T 'empty')"
  } >"$EVID/s3-jj-dirty-state.txt" 2>&1
  cat "$EVID/s3-jj-dirty-state.txt"
  grep -q 'unlanded local edit' "$w/main/AGENTS.md" || die "work discarded"
  [ "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" = "$BASE" ] || die "bookmark moved"
  teardown "$w"
  echo "PASS s_jj_dirty_skipped"
}

s_jj_diverged_skipped() {
  local w
  w=$(new_world)
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  printf 'fork work\n' >"$w/main/AGENTS.md"
  jj -R "$w/main" commit -m local-work >/dev/null 2>&1
  jj -R "$w/main" bookmark set main -r @- >/dev/null 2>&1
  advance_origin "$w"
  run_update "$w"
  cp "$w/update.out" "$EVID/s4-jj-diverged-update.txt"
  grep_q "$EVID/s4-jj-diverged-update.txt" "firstmate: skipped: diverged from main@origin"
  {
    echo "bookmark still on local commit: $([ "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" != "$BASE" ] && [ "$(jj -R "$w/main" log -r 'main & main@origin' --no-graph -T 'commit_id' | grep -c .)" = "0" ] && echo yes || echo NO)"
    echo "local commit preserved: $(jj -R "$w/main" log -r main --no-graph -T 'description.first_line()')"
    echo "fork content preserved: $(grep -c 'fork work' "$w/main/AGENTS.md")"
  } >"$EVID/s4-jj-diverged-state.txt" 2>&1
  cat "$EVID/s4-jj-diverged-state.txt"
  grep -q 'fork work' "$w/main/AGENTS.md" || die "diverged work discarded"
  teardown "$w"
  echo "PASS s_jj_diverged_skipped"
}

s_jj_described_reports_description() {
  local w
  w=$(new_world)
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  advance_origin "$w"
  printf 'wip edit\n' >>"$w/main/AGENTS.md"
  jj -R "$w/main" describe -m wip >/dev/null 2>&1
  run_update "$w"
  cp "$w/update.out" "$EVID/s5-jj-described-update.txt"
  grep_q "$EVID/s5-jj-described-update.txt" "firstmate: skipped: described working copy commit"
  if grep -qF "firstmate: skipped: dirty working tree" "$EVID/s5-jj-described-update.txt"; then
    die "described commit mislabeled as dirty"
  fi
  {
    echo "description still on working copy: $(jj -R "$w/main" log -r '@' --no-graph -T 'description.first_line()')"
    echo "wip content preserved: $(grep -c 'wip edit' "$w/main/AGENTS.md")"
  } >"$EVID/s5-jj-described-state.txt" 2>&1
  cat "$EVID/s5-jj-described-state.txt"
  grep -q 'wip edit' "$w/main/AGENTS.md" || die "described work discarded"
  teardown "$w"
  echo "PASS s_jj_described_reports_description"
}

s_jj_plain_new_advances() {
  local w
  w=$(new_world)
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  advance_origin "$w"
  jj -R "$w/main" new >/dev/null 2>&1
  run_update "$w"
  cp "$w/update.out" "$EVID/s6-jj-plainnew-update.txt"
  grep_q "$EVID/s6-jj-plainnew-update.txt" "firstmate: updated "
  grep_q "$EVID/s6-jj-plainnew-update.txt" "reread-firstmate: yes"
  {
    echo "main == main@origin: $([ "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" = "$(jj -R "$w/main" log -r main@origin --no-graph -T 'commit_id')" ] && echo yes || echo NO)"
    echo "working copy empty: $(jj -R "$w/main" log -r '@' --no-graph -T 'empty')"
    echo "target-only file present: $([ -f "$w/main/bin/fm-install-jj.sh" ] && echo yes || echo NO)"
  } >"$EVID/s6-jj-plainnew-state.txt" 2>&1
  cat "$EVID/s6-jj-plainnew-state.txt"
  [ "$(jj -R "$w/main" log -r main --no-graph -T 'commit_id')" = "$TARGET" ] || die "bookmark not at target"
  teardown "$w"
  echo "PASS s_jj_plain_new_advances"
}

s_jj_parked_side_commit_skipped() {
  local w
  w=$(new_world)
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  advance_origin "$w"
  printf 'side work\n' >>"$w/main/AGENTS.md"
  jj -R "$w/main" commit -m side >/dev/null 2>&1
  parked=$(jj -R "$w/main" log -r '@-' --no-graph -T 'commit_id')
  run_update "$w"
  cp "$w/update.out" "$EVID/s7-jj-parked-update.txt"
  grep_q "$EVID/s7-jj-parked-update.txt" "firstmate: skipped: working copy parked outside main@origin"
  {
    echo "parked commit still parent of @: $([ "$(jj -R "$w/main" log -r '@-' --no-graph -T 'commit_id')" = "$parked" ] && echo yes || echo NO)"
    echo "parked commit description: $(jj -R "$w/main" log -r '@-' --no-graph -T 'description.first_line()')"
    echo "side content preserved: $(grep -c 'side work' "$w/main/AGENTS.md")"
  } >"$EVID/s7-jj-parked-state.txt" 2>&1
  cat "$EVID/s7-jj-parked-state.txt"
  grep -q 'side work' "$w/main/AGENTS.md" || die "parked work discarded"
  teardown "$w"
  echo "PASS s_jj_parked_side_commit_skipped"
}

s_git_behind_advances_same_form() {
  local w
  w=$(new_world)
  advance_origin "$w"
  run_update "$w"
  cp "$w/update.out" "$EVID/s8-git-behind-update.txt"
  grep_q "$EVID/s8-git-behind-update.txt" "firstmate: updated "
  grep_q "$EVID/s8-git-behind-update.txt" "..84e0c00 (instructions changed: bin, .agents/skills)"
  grep_q "$EVID/s8-git-behind-update.txt" "reread-firstmate: yes"
  {
    echo "HEAD at target: $([ "$(git -C "$w/main" rev-parse HEAD)" = "$TARGET" ] && echo yes || echo NO)"
    echo "on main: $(git -C "$w/main" symbolic-ref --short HEAD)"
    echo "target-only file present: $([ -f "$w/main/bin/fm-install-jj.sh" ] && echo yes || echo NO)"
  } >"$EVID/s8-git-behind-state.txt" 2>&1
  cat "$EVID/s8-git-behind-state.txt"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$TARGET" ] || die "git home not advanced"
  teardown "$w"
  echo "PASS s_git_behind_advances_same_form"
}

s_jj_secondmate_via_registry() {
  local w
  w=$(new_world)
  # Primary: plain git checkout at target (already current). Secondmates:
  # sm1 = jj colocated behind origin (must advance), sm2 = jj colocated diverged.
  git -C "$w/origin.git" update-ref refs/heads/main "$TARGET" >/dev/null 2>&1 || true
  git clone -q "$w/origin.git" "$w/main2" 2>/dev/null && rm -rf "$w/main" && mv "$w/main2" "$w/main"
  git -C "$w/origin.git" update-ref refs/heads/main "$BASE"
  for id in sm1 sm2; do
    git clone -q "$w/origin.git" "$w/$id" 2>/dev/null || die "clone $id"
    ( cd "$w/$id" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate $id"
    printf '%s\n' "$id" >"$w/$id/.fm-secondmate-home"
  done
  # sm2 diverges: local commit on its bookmark, origin advances past it.
  printf 'fork work\n' >>"$w/sm2/AGENTS.md"
  jj -R "$w/sm2" commit -m local-work >/dev/null 2>&1
  jj -R "$w/sm2" bookmark set main -r @- >/dev/null 2>&1
  advance_origin "$w"
  {
    printf '# secondmates\n'
    printf -- '- sm1 - live jj secondmate behind origin (home: %s/sm1; scope: ops; projects: none; added 2026-09-27)\n' "$w"
    printf -- '- sm2 - live jj secondmate diverged (home: %s/sm2; scope: ops; projects: none; added 2026-09-27)\n' "$w"
  } >"$w/home/data/secondmates.md"
  run_update "$w"
  cp "$w/update.out" "$EVID/s9-jj-secondmates-update.txt"
  grep_q "$EVID/s9-jj-secondmates-update.txt" "firstmate: already current"
  grep_q "$EVID/s9-jj-secondmates-update.txt" "secondmate sm1: updated "
  grep_q "$EVID/s9-jj-secondmates-update.txt" "secondmate sm2: skipped: diverged from main@origin"
  {
    echo "sm1 bookmark at target: $([ "$(jj -R "$w/sm1" log -r main --no-graph -T 'commit_id')" = "$TARGET" ] && echo yes || echo NO)"
    echo "sm1 target-only file present: $([ -f "$w/sm1/bin/fm-install-jj.sh" ] && echo yes || echo NO)"
    echo "sm2 local commit preserved: $(jj -R "$w/sm2" log -r main --no-graph -T 'description.first_line()')"
    echo "sm2 fork content preserved: $(grep -c 'fork work' "$w/sm2/AGENTS.md")"
    echo "no durable reconcile record for jj divergence: $([ -e "$w/home/state/.secondmate-update-reconcile/sm2.pending" ] && echo RECORD-EXISTS || echo none)"
    ls "$w/home/state/.secondmate-update-reconcile" 2>/dev/null || echo "(no reconcile dir)"
  } >"$EVID/s9-jj-secondmates-state.txt" 2>&1
  cat "$EVID/s9-jj-secondmates-state.txt"
  [ "$(jj -R "$w/sm1" log -r main --no-graph -T 'commit_id')" = "$TARGET" ] || die "sm1 not advanced"
  grep -q 'fork work' "$w/sm2/AGENTS.md" || die "sm2 work discarded"
  teardown "$w"
  echo "PASS s_jj_secondmate_via_registry"
}

s_sanctioned_lab_no_override() {
  # The runbook shape: plain FM_HOME=<marked lab>, no FM_*_OVERRIDE, scripts run
  # from the gate worktree. Primary is the gate worktree itself (detached at the
  # target commit, no local main branch, no origin/HEAD symref), so the git path
  # must skip it safely and the sweep must complete with the full summary.
  local w
  w=$(new_world)
  run_update_no_override() {
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$w/home" "$WT/bin/fm-update.sh" >"$w/update.out" 2>&1
  }
  ( cd "$WT" && run_update_no_override )
  cp "$w/update.out" "$EVID/s10-sanctioned-no-override-update.txt"
  grep_q "$EVID/s10-sanctioned-no-override-update.txt" "firstmate: skipped: cannot determine default branch"
  grep_q "$EVID/s10-sanctioned-no-override-update.txt" "reread-firstmate: no"
  grep_q "$EVID/s10-sanctioned-no-override-update.txt" "restart-secondmates: none"
  grep_q "$EVID/s10-sanctioned-no-override-update.txt" "nudge-secondmates: none"
  cat "$EVID/s10-sanctioned-no-override-update.txt"
  teardown "$w"
  echo "PASS s_sanctioned_lab_no_override"
}

s_jj_home_without_jj_skipped() {
  # A .jj dir without a usable jj on PATH must skip with the dedicated report,
  # never fall through to the git guards that misread the colocated export.
  local w
  w=$(new_world)
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 ) || die "colocate"
  advance_origin "$w"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE \
    PATH="/usr/bin:/bin" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    "$WT/bin/fm-update.sh" >"$w/update.out" 2>&1
  cp "$w/update.out" "$EVID/s11-jj-no-binary-update.txt"
  grep_q "$EVID/s11-jj-no-binary-update.txt" "firstmate: skipped: jj-managed home but jj is not on PATH"
  grep_q "$EVID/s11-jj-no-binary-update.txt" "reread-firstmate: no"
  cat "$EVID/s11-jj-no-binary-update.txt"
  teardown "$w"
  echo "PASS s_jj_home_without_jj_skipped"
}

run_scenario jj_behind_advances
run_scenario jj_already_current
run_scenario jj_dirty_skipped
run_scenario jj_diverged_skipped
run_scenario jj_described_reports_description
run_scenario jj_plain_new_advances
run_scenario jj_parked_side_commit_skipped
run_scenario git_behind_advances_same_form
run_scenario jj_secondmate_via_registry
run_scenario sanctioned_lab_no_override
run_scenario jj_home_without_jj_skipped
echo "ALL SCENARIOS DONE"
