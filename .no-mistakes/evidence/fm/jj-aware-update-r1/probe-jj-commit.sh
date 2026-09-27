#!/usr/bin/env bash
# Probe: what does real jj 0.45.1 do with `jj commit -m wip` on an empty
# working copy in a colocated fixture? (Evidence for the described-but-empty
# shape named in the user's fix instruction.)
set -u
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-jj-probe.XXXXXX")
export GIT_AUTHOR_NAME=live-test GIT_AUTHOR_EMAIL=live-test@example.com
export GIT_COMMITTER_NAME=live-test GIT_COMMITTER_EMAIL=live-test@example.com
mkdir -p "$T/w/home"
git init -q --bare "$T/w/origin.git"
git -C "$T/w/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/w/origin.git" "$T/w/seed" 2>/dev/null
printf 'v1\n' > "$T/w/seed/AGENTS.md"
git -C "$T/w/seed" add -A && git -C "$T/w/seed" commit -qm c1 && git -C "$T/w/seed" push -q origin main
git clone -q "$T/w/origin.git" "$T/w/main"
git -C "$T/w/main" config user.name live-test
git -C "$T/w/main" config user.email live-test@example.com
( cd "$T/w/main" && jj git init --colocate >/dev/null 2>&1 )
echo "=== post-init state ==="
jj -R "$T/w/main" log --no-graph -T 'commit_id.short(7) ++ " " ++ if(description.first_line(), description.first_line(), "") ++ " " ++ bookmarks ++ "\n"'
echo "=== jj commit -m wip with no edits ==="
( cd "$T/w/main" && jj commit -m wip 2>&1 )
echo "exit=$?"
echo "=== state after ==="
jj -R "$T/w/main" log --no-graph -T 'commit_id.short(7) ++ " " ++ if(description.first_line(), description.first_line(), "") ++ " " ++ bookmarks ++ "\n"'
rm -rf "$T"
