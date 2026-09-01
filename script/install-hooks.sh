#!/usr/bin/env sh
# Install the repo's git hooks. Run once per clone:  sh script/install-hooks.sh
#
# WHY THIS EXISTS. `script/mutate.py` edits `src/` in place. PITFALLS 5.79 said "do not run forge
# while it is running", 5.86 said prose is not an interlock and gave `forge test` a real marker
# check — and then a session committed a MUTANT into `src/` twice with `git add -A`, in commits
# whose messages said "no production code changed". The forge interlock could not see it, because
# committing is not running a test. So the interlock now covers the other way in.
set -e
root=$(git rev-parse --show-toplevel)
mkdir -p "$root/.git/hooks"
cp "$root/script/hooks/pre-commit" "$root/.git/hooks/pre-commit"
chmod +x "$root/.git/hooks/pre-commit"
echo "installed: .git/hooks/pre-commit (refuses to commit while a mutation campaign holds src/)"
