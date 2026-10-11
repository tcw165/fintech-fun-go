#!/usr/bin/env bash
# Morning standup: locate main + *-wtN folders, then Graphite-sync every checkout.
set -u

find_git_root() {
  local d
  d=$(cd "${1:-.}" && pwd)
  while [ "$d" != "/" ]; do
    if [ -e "$d/.git" ]; then
      git -C "$d" rev-parse --show-toplevel 2>/dev/null && return 0
    fi
    d=$(dirname "$d")
  done
  return 1
}

resolve_primary() {
  local checkout="$1"
  local git_common
  git_common=$(git -C "$checkout" rev-parse --git-common-dir)
  case "$git_common" in
    /*) ;;
    *) git_common="$checkout/$git_common" ;;
  esac
  (cd "$git_common/.." && pwd)
}

pool_branch_for() {
  local basename_wt num
  basename_wt=$(basename "$1")
  num=$(printf '%s' "$basename_wt" | sed -n 's/.*-wt\([0-9][0-9]*\)$/\1/p')
  if [ -n "$num" ]; then
    printf 'dev/wt%s\n' "$num"
  else
    printf 'main\n'
  fi
}

collect_worktrees() {
  local primary="$1"
  local stem parent
  stem=$(basename "$primary")
  parent=$(dirname "$primary")
  {
    git -C "$primary" worktree list --porcelain | awk '/^worktree / {print $2}'
    printf '%s\n' "$primary"
    find "$parent" -maxdepth 1 \( -type d -o -type l \) \
      -name "${stem}-wt[0-9]*" 2>/dev/null
  } | while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$p/.git" ] || continue
    printf '%s\n' "$p"
  done | awk 'NF && !seen[$0]++'
}

START_PATH="${1:-.}"
REPO_ROOT=$(find_git_root "$START_PATH") || {
  echo "ERROR: not inside a git checkout — cd into the main repo or a *-wtN folder."
  exit 1
}

PREVIOUS_BRANCH=$(git -C "$REPO_ROOT" branch --show-current)
if [ -z "${PREVIOUS_BRANCH:-}" ]; then
  echo "ERROR: detached HEAD at $REPO_ROOT — say which branch to return to after sync."
  exit 1
fi

PRIMARY_PATH=$(resolve_primary "$REPO_ROOT")
POOL_BRANCH=$(pool_branch_for "$REPO_ROOT")

WT_LIST=$(mktemp)
trap 'rm -f "$WT_LIST"' EXIT
collect_worktrees "$PRIMARY_PATH" > "$WT_LIST"

echo "Saved branch: $PREVIOUS_BRANCH"
echo "Saved worktree: $REPO_ROOT"
echo "Pool branch: $POOL_BRANCH"
echo "Main folder: $PRIMARY_PATH"
echo "Worktree folders:"
if [ -s "$WT_LIST" ]; then
  cat "$WT_LIST"
else
  echo "  (none found)"
  exit 1
fi

# Step 3: pool branch on the starting worktree, then sync
if [ "$POOL_BRANCH" = "main" ]; then
  gt checkout main --cwd "$REPO_ROOT"
else
  gt checkout "$POOL_BRANCH" --cwd "$REPO_ROOT"
fi
gt sync --cwd "$REPO_ROOT"

# Step 4: every other main / *-wtN checkout
while IFS= read -r wt_path; do
  [ "$wt_path" = "$REPO_ROOT" ] && continue
  wt_pool=$(pool_branch_for "$wt_path")
  wt_branch=$(git -C "$wt_path" branch --show-current)
  if [ -n "$wt_branch" ] && [ "$wt_branch" != "$wt_pool" ] && \
     gt info --branch "$wt_branch" --cwd "$wt_path" 2>/dev/null | head -1 | grep -q '(merged)'; then
    echo "Moving $wt_path off merged branch $wt_branch → $wt_pool"
    gt checkout "$wt_pool" --cwd "$wt_path"
  fi
  echo "Syncing worktree: $wt_path"
  gt sync --cwd "$wt_path"
done < "$WT_LIST"

# Step 5: return to the remembered branch (open only) on the starting worktree
if [ -n "$PREVIOUS_BRANCH" ] && [ "$PREVIOUS_BRANCH" != "$POOL_BRANCH" ]; then
  if gt info --branch "$PREVIOUS_BRANCH" --cwd "$REPO_ROOT" 2>/dev/null | head -1 | grep -q '(merged)'; then
    echo "Saved branch $PREVIOUS_BRANCH is merged — staying on $POOL_BRANCH"
  else
    gt checkout "$PREVIOUS_BRANCH" --cwd "$REPO_ROOT"
    echo "Back on $PREVIOUS_BRANCH"
  fi
else
  echo "Staying on $POOL_BRANCH"
fi

# Step 6: final sync from primary
echo "Final sync from primary: $PRIMARY_PATH"
gt sync --cwd "$PRIMARY_PATH"

# Step 7: delete stale merged locals not checked out in any worktree
while IFS= read -r branch; do
  case "$branch" in main|dev/wt*) continue ;; esac
  if git -C "$PRIMARY_PATH" worktree list | grep -q "\[$branch\]"; then
    continue
  fi
  if gt info --branch "$branch" --cwd "$PRIMARY_PATH" 2>/dev/null | head -1 | grep -q '(merged)'; then
    echo "Deleting stale merged branch $branch"
    gt delete "$branch" -q --cwd "$PRIMARY_PATH"
  fi
done < <(git -C "$PRIMARY_PATH" branch --format='%(refname:short)')
