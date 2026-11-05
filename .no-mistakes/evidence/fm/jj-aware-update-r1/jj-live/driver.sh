#!/usr/bin/env bash
# Live driver for the jj-aware /updatefirstmate change.
#
# Builds real isolated firstmate worlds (bare origin + seed clone + a firstmate
# checkout), makes the firstmate checkout a jj colocated home, and runs the real
# bin/fm-update.sh against each shape. Every check reads the product's own
# output and the resulting jj state, not the implementation source.
set -u

WT=/Users/hotthoughts/.no-mistakes/worktrees/afc49cb2f7e6/01M6NQ90SC81ZVCCSCBKATT6JH
UPDATE=$WT/bin/fm-update.sh
JJBIN=$(cat /tmp/fm-jjpin.path)/bin
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-jjlab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

# The host's user-level jj config requests GPG-signed commits and gpg is not
# installed; an empty JJ_CONFIG keeps the fixture jj from signing (CI's pinned
# jj runs with a plain config). This changes no product behavior.
: > "$LAB/jj-config.toml"
export JJ_CONFIG="$LAB/jj-config.toml"

export PATH="$JJBIN:/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.com
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.com

PASS=0
FAILED=0
FAILS=""

ok()  { PASS=$((PASS + 1)); printf '  ok: %s\n' "$*"; }
bad() { FAILED=$((FAILED + 1)); FAILS="$FAILS
  - $*"; printf '  CHECK FAILED: %s\n' "$*"; }
contains() {
  local hay=$1 needle=$2 desc=$3
  if printf '%s' "$hay" | grep -qF -- "$needle"; then ok "$desc"; else bad "$desc (missing: $needle)"; fi
}
not_contains() {
  local hay=$1 needle=$2 desc=$3
  if printf '%s' "$hay" | grep -qF -- "$needle"; then bad "$desc (unexpected: $needle)"; else ok "$desc"; fi
}
eq() {
  local got=$1 want=$2 desc=$3
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (got '$got', want '$want')"; fi
}

# --- fixture builders (mirror a real firstmate home) ------------------------

new_world() {
  local name=$1 w
  w="$LAB/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in main:fm-*) target=$arg ;; esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  # The host's global git config signs commits with gpg; fixtures are unsigned.
  git -C "$w/seed" config commit.gpgsign false
  git -C "$w/seed" config tag.gpgsign false

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
  chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

new_jj_world() {
  local name=$1 w
  w=$(new_world "$name")
  ( cd "$w/main" && jj git init --colocate >/dev/null 2>&1 )
  [ -d "$w/main/.jj" ] || { echo "fixture: jj colocate failed" >&2; exit 90; }
  printf '%s\n' "$w"
}

bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

# Standalone jj colocated secondmate home, as in the repo's own fixture.
add_jj_sm() {
  local w=$1 id=$2
  git clone -q "$w/origin.git" "$w/$id"
  git -C "$w/$id" remote set-head origin main >/dev/null 2>&1 || true
  printf '.fm-secondmate-home\n' >> "$w/$id/.git/info/exclude"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
  ( cd "$w/$id" && jj git init --colocate >/dev/null 2>&1 )
  [ -d "$w/$id/.jj" ] || { echo "fixture: secondmate jj colocate failed" >&2; exit 90; }
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/%s\n' "$w" "$id"
    printf 'kind=secondmate\n'
    printf 'harness=claude\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf 'fm-%s\n' "$id" >> "$w/fake/windows"
}

run_update() {
  local w=$1
  PATH="$w/fakebin:$JJBIN:$PATH" FM_FAKE_DIR="$w/fake" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1
}

jmain()      { jj -R "$1" log -r main --no-graph -T 'commit_id' 2>/dev/null; }
joriginmain(){ jj -R "$1" log -r main@origin --no-graph -T 'commit_id' 2>/dev/null; }
jwc()        { jj -R "$1" log -r @ --no-graph -T 'commit_id' 2>/dev/null; }
jwcempty()   { jj -R "$1" log -r @ --no-graph -T 'empty' 2>/dev/null; }
jwcrev()     { jj -R "$1" log -r @- --no-graph -T 'commit_id' 2>/dev/null; }
jwctitle()   { jj -R "$1" log -r @ --no-graph -T 'description.first_line()' 2>/dev/null; }
jprevtitle() { jj -R "$1" log -r @- --no-graph -T 'description.first_line()' 2>/dev/null; }

SCEN_FAILED=0
scenario() { SCEN_FAILED=$FAILED; printf '\n=== SCENARIO %s ===\n' "$*"; }
verdict()  {
  if [ "$FAILED" -eq "$SCEN_FAILED" ]; then printf 'RESULT: PASS\n'; else printf 'RESULT: FAIL\n'; fi
}

# ===========================================================================
# 1. clean jj home behind origin advances and reports like a git home
# ===========================================================================
scenario jj-clean-behind-advances
w=$(new_jj_world clean-behind) || exit 1
before_main=$(jmain "$w/main")
bump_origin "$w" instr
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: updated " "clean jj home reports an advance"
contains "$out" "(instructions changed: AGENTS.md, bin, .agents/skills)" "advance reports the changed instruction surface"
contains "$out" "reread-firstmate: yes" "instruction change flips reread"
eq "$(jmain "$w/main")" "$(joriginmain "$w/main")" "default bookmark is at origin tip"
eq "$(jwcempty "$w/main")" "true" "working copy is clean after the advance"
eq "$(cat "$w/main/AGENTS.md")" "v2" "tracked files advanced to target content"
[ "$(jmain "$w/main")" != "$before_main" ] && ok "bookmark actually moved" || bad "bookmark did not move"
[ "$(git -C "$w/main" rev-list --parents -n1 main | wc -w | tr -d ' ')" -eq 2 ] \
  && ok "advanced tip is a single-parent fast-forward" || bad "advanced tip is not single-parent"
# Parity control: a plain git home gets the same status vocabulary.
gw=$(new_world git-control)
bump_origin "$gw" instr
gout=$(run_update "$gw")
printf -- '--- git control output ---\n%s\n' "$gout"
printf '%s\n' "$gout" | grep -qE '^firstmate: updated [0-9a-f]{7}\.\.[0-9a-f]{7} \(instructions changed: AGENTS.md, bin, \.agents/skills\)$' \
  && ok "git control emits the reference updated line" || bad "git control line format unexpected"
printf '%s\n' "$out" | grep -qE '^firstmate: updated [0-9a-f]{7}\.\.[0-9a-f]{7} \(instructions changed: AGENTS.md, bin, \.agents/skills\)$' \
  && ok "jj home emits the same updated line shape as the git home" || bad "jj updated line shape differs from git"
verdict

# ===========================================================================
# 2. already-current clean jj home is a no-op
# ===========================================================================
scenario jj-already-current-noop
w=$(new_jj_world already-current) || exit 1
before_main=$(jmain "$w/main"); before_wc=$(jwc "$w/main")
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: already current" "clean current jj home reports already current"
contains "$out" "reread-firstmate: no" "no reread when nothing moved"
eq "$(jmain "$w/main")" "$before_main" "bookmark unchanged"
eq "$(jwc "$w/main")" "$before_wc" "working copy unchanged"
eq "$(jwcempty "$w/main")" "true" "working copy still clean"
verdict PASS

# ===========================================================================
# 3. a plain empty `jj new` above the base still advances (does not wedge)
# ===========================================================================
scenario jj-empty-new-above-base-advances
w=$(new_jj_world empty-new) || exit 1
jj -R "$w/main" new >/dev/null 2>&1
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: updated " "a plain jj new above the base advances"
contains "$out" "reread-firstmate: no" "unchanged files do not trigger a reread"
eq "$(jmain "$w/main")" "$(joriginmain "$w/main")" "bookmark sits at origin tip"
eq "$(jwcempty "$w/main")" "true" "working copy is a clean child of the target"
eq "$(cat "$w/main/AGENTS.md")" "v1" "files unchanged, as expected"
verdict PASS

# ===========================================================================
# 4. described-but-empty working copy (jj describe) skips by description
# ===========================================================================
scenario jj-described-empty-describe-skips-description
w=$(new_jj_world described-empty) || exit 1
bump_origin "$w" instr
jj -R "$w/main" describe -m wip >/dev/null 2>&1
before_main=$(jmain "$w/main"); before_wc=$(jwc "$w/main")
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: skipped: described working copy commit" "described empty WC skips with the description reason"
not_contains "$out" "firstmate: skipped: dirty working tree" "described empty WC is never mislabeled dirty"
eq "$(jwc "$w/main")" "$before_wc" "working-copy commit not relocated"
eq "$(jwctitle "$w/main")" "wip" "working-copy description preserved"
eq "$(jmain "$w/main")" "$before_main" "bookmark untouched"
eq "$(jwcempty "$w/main")" "true" "working copy still empty (no content moved)"
verdict PASS

# ===========================================================================
# 5. described-but-empty shape left by `jj commit -m wip` with no edits
# ===========================================================================
scenario jj-described-empty-commit-skips-parked-outside
w=$(new_jj_world described-commit) || exit 1
bump_origin "$w" instr
jj -R "$w/main" commit -m wip >/dev/null 2>&1
before_main=$(jmain "$w/main"); before_wc=$(jwc "$w/main"); before_prev=$(jwcrev "$w/main")
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: skipped: working copy parked outside main@origin" \
  "jj commit -m wip with no edits skips as a parked working copy"
not_contains "$out" "firstmate: skipped: dirty working tree" "described-but-empty is never reported as unlanded dirt"
eq "$(jwc "$w/main")" "$before_wc" "working-copy commit not relocated"
eq "$(jwcrev "$w/main")" "$before_prev" "the described empty commit is not stranded or discarded"
eq "$(jprevtitle "$w/main")" "wip" "its description is preserved"
eq "$(jmain "$w/main")" "$before_main" "bookmark untouched"
verdict PASS

# ===========================================================================
# 6. working copy parked on a commit the target does not contain
# ===========================================================================
scenario jj-wc-parked-outside-target-skips
w=$(new_jj_world parked-outside) || exit 1
bump_origin "$w" instr
printf 'parked work\n' >> "$w/main/AGENTS.md"
jj -R "$w/main" commit -m parked >/dev/null 2>&1
before_main=$(jmain "$w/main"); before_wc=$(jwc "$w/main"); parked=$(jwcrev "$w/main")
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: skipped: working copy parked outside main@origin" "parked working copy skipped"
eq "$(jwc "$w/main")" "$before_wc" "working-copy commit not relocated"
eq "$(jwcrev "$w/main")" "$parked" "parked commit still in place"
[ -n "$(jj -R "$w/main" log -r "$parked" --no-graph -T 'commit_id' 2>/dev/null)" ] \
  && ok "parked commit still resolvable (nothing stranded)" || bad "parked commit lost"
grep -q 'parked work' "$w/main/AGENTS.md" && ok "parked work preserved on disk" || bad "parked work discarded"
eq "$(jmain "$w/main")" "$before_main" "bookmark untouched"
verdict PASS

# ===========================================================================
# 7. diverged history (local bookmark commit the target lacks) is skipped
# ===========================================================================
scenario jj-diverged-history-skips
w=$(new_jj_world diverged) || exit 1
printf 'fork work\n' > "$w/main/AGENTS.md"
jj -R "$w/main" commit -m local-work >/dev/null 2>&1
jj -R "$w/main" bookmark set main -r @- >/dev/null 2>&1
before_main=$(jmain "$w/main"); before_wc=$(jwc "$w/main")
bump_origin "$w" instr
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: skipped: diverged from main@origin" "diverged bookmark skipped, never forced"
eq "$(jmain "$w/main")" "$before_main" "local bookmark not moved to upstream"
eq "$(jwc "$w/main")" "$before_wc" "working-copy commit untouched"
grep -q 'fork work' "$w/main/AGENTS.md" && ok "local commit content preserved" || bad "local work discarded"
verdict PASS

# ===========================================================================
# 8. unlanded working-copy edit is skipped and preserved
# ===========================================================================
scenario jj-dirty-working-copy-skips
w=$(new_jj_world dirty) || exit 1
bump_origin "$w" instr
printf 'uncommitted local edit\n' >> "$w/main/AGENTS.md"
snapshot=$(jwc "$w/main")   # snapshot the edit, as the next jj command does
before_main=$(jmain "$w/main")
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: skipped: dirty working tree" "unlanded edit skipped as dirty"
eq "$(jwc "$w/main")" "$snapshot" "snapshot commit not relocated"
eq "$(jmain "$w/main")" "$before_main" "bookmark untouched"
grep -q 'uncommitted local edit' "$w/main/AGENTS.md" && ok "unlanded edit preserved on disk" || bad "unlanded edit discarded"
verdict PASS

# ===========================================================================
# 9. a jj colocated secondmate advances and clears its pending record
# ===========================================================================
scenario jj-secondmate-advances-clears-record
w=$(new_jj_world secondmate) || exit 1
add_jj_sm "$w" sm1
marker="$w/home/state/.secondmate-update-reconcile/sm1.pending"
mkdir -p "${marker%/*}"
{
  printf 'schema=fm-secondmate-update-reconcile.v1\n'
  printf 'id=sm1\n'
  printf 'status=diverged\n'
} > "$marker"
bump_origin "$w" instr
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: updated " "jj primary advanced alongside its secondmate"
contains "$out" "secondmate sm1: updated " "jj secondmate home advanced through the jj path"
[ ! -e "$marker" ] && ok "pending reconciliation record cleared on convergence" || bad "pending record left behind"
eq "$(jmain "$w/sm1")" "$(joriginmain "$w/sm1")" "secondmate bookmark at origin tip"
eq "$(cat "$w/sm1/AGENTS.md")" "v2" "secondmate files at target content"
eq "$(jwcempty "$w/sm1")" "true" "secondmate working copy clean"
verdict PASS

# ===========================================================================
# 10. a failed jj diff over-approximates to "instructions changed"
# ===========================================================================
scenario jj-failed-diff-reports-changed
w=$(new_jj_world failed-diff) || exit 1
real_jj="$JJBIN/jj"
cat > "$w/fakebin/jj" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != diff ] || exit 1
exec "$real_jj" "\$@"
SH
chmod +x "$w/fakebin/jj"
bump_origin "$w" instr
out=$(run_update "$w"); rc=$?
printf -- '--- update output (exit %s) ---\n%s\n' "$rc" "$out"
contains "$out" "firstmate: updated " "home still advances when jj diff cannot run"
contains "$out" "reread-firstmate: yes" "failed jj diff over-approximates to changed instruction surface"
verdict PASS

printf '\n==== SUMMARY: %s passed, %s failed ====\n' "$PASS" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  printf 'FAILED CHECKS:%s\n' "$FAILS"
  exit 1
fi
