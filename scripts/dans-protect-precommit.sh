#!/bin/sh
# Refuse to commit changes to paths protected by .dans_protected (globs, one per
# line, # comments ok -- e.g. vendor/*). Mirrors the editor read-only guard in
# lua/custom/dans_protect.lua so the two agree.
#
# Install (per repo):
#   ln -sf ../../scripts/dans-protect-precommit.sh .git/hooks/pre-commit
# or point git at a tracked hooks dir:
#   git config core.hooksPath scripts/githooks   # (and place this there)
#
# Override a single commit with: git commit --no-verify

root="$(git rev-parse --show-toplevel)" || exit 0
conf="$root/.dans_protected"
[ -f "$conf" ] || exit 0

blocked=""
for f in $(git diff --cached --name-only); do
  while IFS= read -r pat; do
    case "$pat" in '' | \#*) continue ;; esac
    # shellcheck disable=SC2254  -- $pat is intentionally a glob
    case "$f" in
      $pat)
        blocked="$blocked  $f
"
        break
        ;;
    esac
  done <"$conf"
done

if [ -n "$blocked" ]; then
  printf 'dans-protect: refusing to commit protected paths (.dans_protected):\n%s' "$blocked" >&2
  echo 'override with: git commit --no-verify' >&2
  exit 1
fi
exit 0
