---
name: morning-standup
description: Daily Graphite sync ritual — auto-locate the main repo folder and sibling *-wtN worktrees, remember the current branch, move merged branches to pool before sync, sync trunk with gt sync on every checkout, finalize cleanup from primary, then return to the saved branch only if it is still open. Use at the start of a work session before new changes.
---

# Morning Standup

Start each work session by syncing trunk with Graphite while preserving your working branch.

Follow `/graphite` for all Git/Graphite operations — do **not** use raw `git checkout`, `git pull`, or `git push`.

## Agent behavior

- Run the **standup script** (or the one-shot below) end-to-end without asking the user.
- **Do not stop at cleanup warnings** — fix them and continue unless a merge conflict needs human input.
- If `gt sync` prints *cannot be cleaned up while it is checked out in another worktree*, Step 4 missed a worktree still on a merged branch. Run the Step 4 pool-move block for that path, re-sync it, then finish Steps 6–7.
- Step 3 **intentionally** checks out the pool branch on the starting worktree (you are not "losing" an open branch — Step 5 restores it when still open).
- Start from **any** checkout — main or a `*-wtN` folder. The script finds the rest.

Preferred:

```bash
bash "$HOME/.claude/skills/morning-standup/scripts/standup.sh"
```

Optional start path (when cwd is not the repo): `bash …/standup.sh /path/to/checkout`.

## Locating main and worktree folders

Do **not** hard-code paths or ask the user which folder is main. Discover them:

1. **Current checkout** — walk up from cwd until a directory contains `.git`, then `git rev-parse --show-toplevel`.
2. **Main folder (primary)** — the repo that owns the real `.git` directory:

   ```bash
   GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
   # relative `.git` on primary; absolute `…/repo/.git` on a linked worktree
   PRIMARY_PATH=$(cd "$GIT_COMMON_DIR/.." && pwd)
   ```

3. **Repo stem** — `basename` of the main folder (`fintech-fun`, `my-oops-stacks`).
4. **Worktree folders** — union, then keep only paths that contain `.git`:
   - `git worktree list` from the main folder (covers linked checkouts anywhere)
   - sibling directories named `{stem}-wtN` (`my-oops-stacks-wt1`, `fintech-fun-wt2`, …)

Primary is the folder **without** a `-wtN` suffix (`.git` is a directory). Linked worktrees are `{stem}-wtN` (`.git` is a file pointing at the main repo). Ignore unrelated siblings.

```bash
git worktree list
git worktree list --porcelain
ls "$(git rev-parse --git-common-dir)/worktrees/" 2>/dev/null
```

Each discovered path is valid for `gt … --cwd`.

## Worktree pool branches

Git allows only **one** checkout of `main` at a time. In a multi-worktree setup, `main` lives on the **primary** worktree. Linked worktrees use a **pool branch** as their idle branch:

| Worktree path suffix | Pool branch |
|----------------------|-------------|
| (primary — no `-wtN` suffix) | `main` |
| `*-wt1` | `dev/wt1` |
| `*-wt2` | `dev/wt2` |
| `*-wtN` | `dev/wtN` |

Pool branches are placeholders — **never commit PR work on `dev/wt*`**. Start new stacks from `main` via `gt sync` + a feature branch.

If `gt checkout main` fails with *`main` is already used by worktree at …*, you are on a linked worktree. Switch to that worktree's pool branch instead (e.g. `gt checkout dev/wt1`).

Move off **merged** feature branches before sync — Graphite cannot delete merged PR branches while they remain checked out in any worktree. Step 3 does this on the starting worktree; Step 4 does it on every other worktree; Step 5 does **not** return to a merged branch (stay on the pool branch so local cleanup can finish).

## Workflow

Discovery runs first. The remaining steps use `PRIMARY_PATH` and the collected worktree list — not cwd guesses.

### Step 1: Remember the current branch and locate folders

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)   # after walking up to .git if needed
PREVIOUS_BRANCH=$(git -C "$REPO_ROOT" branch --show-current)
PRIMARY_PATH=$(cd "$(git -C "$REPO_ROOT" rev-parse --git-common-dir)/.." && pwd)
# if git-common-dir is relative (`.git`), prefix with $REPO_ROOT first
POOL_BRANCH=main   # or dev/wtN from basename *-wtN
```

If the branch name is empty (detached HEAD), stop and ask the user which branch to return to after sync.

`PREVIOUS_BRANCH` is only restored in Step 5 when Graphite still considers it open (`gt info` does not show `(merged)`).

### Step 2: List discovered worktrees

Print `PRIMARY_PATH` and every `{stem}-wtN` / `git worktree list` path. Standup syncs **each** one in Step 4.

### Step 3: Sync trunk from this worktree

Step 3 always moves the **starting** worktree to its pool branch first (`main` on primary, `dev/wtN` on linked). That is required for sync; Step 5 restores an open `PREVIOUS_BRANCH` afterward.

On the **primary** worktree (pool branch `main`):

```bash
gt checkout main --cwd "$REPO_ROOT"
gt sync --cwd "$REPO_ROOT"
```

On a **linked** worktree (`main` is checked out elsewhere — do **not** run `gt checkout main`):

```bash
gt checkout dev/wt1 --cwd "$REPO_ROOT"   # use dev/wt2, … matching this worktree
gt sync --cwd "$REPO_ROOT"
```

This pulls the latest trunk, cleans up merged branches, syncs open PR branches, and restacks.

If `gt sync` stops on a merge conflict, resolve it per `/graphite` (`gt continue` after fixing), then finish sync before moving to the next worktree or returning to the saved branch.

### Step 4: Sync every other discovered worktree

For each **additional** path from Step 2 (skip the worktree synced in Step 3), derive that worktree's pool branch (`main` for the primary path, `dev/wtN` for `*-wtN`). If it is checked out on a **merged** feature branch, move it to the pool branch first so `gt sync` can delete stale locals:

```bash
wt_path="/path/to/worktree"
wt_basename=$(basename "$wt_path")
wt_num=$(printf '%s' "$wt_basename" | sed -n 's/.*-wt\([0-9][0-9]*\)$/\1/p')
if [ -n "$wt_num" ]; then
  wt_pool="dev/wt${wt_num}"
else
  wt_pool="main"
fi
wt_branch=$(git -C "$wt_path" branch --show-current)
if [ -n "$wt_branch" ] && [ "$wt_branch" != "$wt_pool" ] && \
   gt info --branch "$wt_branch" --cwd "$wt_path" 2>/dev/null | head -1 | grep -q '(merged)'; then
  echo "Moving $wt_path off merged branch $wt_branch → $wt_pool"
  gt checkout "$wt_pool" --cwd "$wt_path"
fi
gt sync --cwd "$wt_path"
```

Run one pool-check + `gt sync --cwd` per extra worktree. Leave **open** feature branches checked out — only move merged ones to pool.

If a linked worktree hits a conflict, resolve it there (`gt continue --cwd "/path/to/worktree"` or `cd` into that worktree first), then continue syncing the remaining worktrees.

### Step 5: Return to the remembered branch (open only)

Back on the worktree where you started — already on the pool branch after Step 3:

```bash
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
```

### Step 6: Final sync from primary

After every worktree releases merged branches (Steps 3–4), run **one more** `gt sync` from the **discovered main folder**:

```bash
echo "Final sync from primary: $PRIMARY_PATH"
gt sync --cwd "$PRIMARY_PATH"
```

### Step 7: Delete stale merged locals

`gt sync` may leave merged branch refs when they were blocked mid-standup. Delete any merged branch that is **not** checked out in any worktree:

```bash
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
```

### Step 8: List every worktree, its branch, and its PR

After cleanup, print one block per discovered checkout. Put the path, the branch, and — when Graphite has an open PR — the `PR #` line and Graphite link on their own lines so a long branch name does not wrap into the path.

```bash
echo "Worktrees:"
while IFS= read -r wt_path; do
  wt_branch=$(git -C "$wt_path" branch --show-current)
  echo "- $wt_path"
  if [ -z "$wt_branch" ]; then
    echo "  <detached>"
    continue
  fi
  echo "  $wt_branch"
  info=$(gt info --branch "$wt_branch" --cwd "$wt_path" 2>/dev/null || true)
  pr_line=$(printf '%s\n' "$info" | sed -n '/^PR #/p' | head -1)
  pr_url=$(printf '%s\n' "$info" | sed -n '/^https:\/\/app\.graphite\.com\//p' | head -1)
  if [ -n "$pr_line" ]; then
    echo "  $pr_line"
  fi
  if [ -n "$pr_url" ]; then
    echo "  $pr_url"
  fi
done < "$WT_LIST"
```

## One-shot script

Prefer `scripts/standup.sh`. If that file is missing, run this block from any checkout of the repo:

```bash
find_git_root() {
  d=$(cd "${1:-.}" && pwd)
  while [ "$d" != "/" ]; do
    if [ -e "$d/.git" ]; then
      git -C "$d" rev-parse --show-toplevel 2>/dev/null && return 0
    fi
    d=$(dirname "$d")
  done
  return 1
}

REPO_ROOT=$(find_git_root) || { echo "ERROR: not inside a git checkout"; exit 1; }
PREVIOUS_BRANCH=$(git -C "$REPO_ROOT" branch --show-current)
GIT_COMMON_DIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir)
case "$GIT_COMMON_DIR" in
  /*) ;;
  *) GIT_COMMON_DIR="$REPO_ROOT/$GIT_COMMON_DIR" ;;
esac
PRIMARY_PATH=$(cd "$GIT_COMMON_DIR/.." && pwd)
REPO_STEM=$(basename "$PRIMARY_PATH")
REPO_PARENT=$(dirname "$PRIMARY_PATH")
WT_BASENAME=$(basename "$REPO_ROOT")
WT_NUM=$(printf '%s' "$WT_BASENAME" | sed -n 's/.*-wt\([0-9][0-9]*\)$/\1/p')
if [ -n "$WT_NUM" ]; then
  POOL_BRANCH="dev/wt${WT_NUM}"
else
  POOL_BRANCH="main"
fi

WT_LIST=$(mktemp)
{
  git -C "$PRIMARY_PATH" worktree list --porcelain | awk '/^worktree / {print $2}'
  echo "$PRIMARY_PATH"
  find "$REPO_PARENT" -maxdepth 1 \( -type d -o -type l \) -name "${REPO_STEM}-wt[0-9]*" 2>/dev/null
} | awk 'NF && !seen[$0]++' | while IFS= read -r p; do
  [ -e "$p/.git" ] && echo "$p"
done > "$WT_LIST"

echo "Saved branch: ${PREVIOUS_BRANCH:-<none>}"
echo "Saved worktree: $REPO_ROOT"
echo "Pool branch: $POOL_BRANCH"
echo "Main folder: $PRIMARY_PATH"
echo "Worktree folders:"; cat "$WT_LIST"

if [ "$POOL_BRANCH" = "main" ]; then
  gt checkout main --cwd "$REPO_ROOT"
else
  gt checkout "$POOL_BRANCH" --cwd "$REPO_ROOT"
fi
gt sync --cwd "$REPO_ROOT"

while IFS= read -r wt_path; do
  [ "$wt_path" = "$REPO_ROOT" ] && continue
  wt_basename=$(basename "$wt_path")
  wt_num=$(printf '%s' "$wt_basename" | sed -n 's/.*-wt\([0-9][0-9]*\)$/\1/p')
  if [ -n "$wt_num" ]; then
    wt_pool="dev/wt${wt_num}"
  else
    wt_pool="main"
  fi
  wt_branch=$(git -C "$wt_path" branch --show-current)
  if [ -n "$wt_branch" ] && [ "$wt_branch" != "$wt_pool" ] && \
     gt info --branch "$wt_branch" --cwd "$wt_path" 2>/dev/null | head -1 | grep -q '(merged)'; then
    echo "Moving $wt_path off merged branch $wt_branch → $wt_pool"
    gt checkout "$wt_pool" --cwd "$wt_path"
  fi
  echo "Syncing worktree: $wt_path"
  gt sync --cwd "$wt_path"
done < "$WT_LIST"

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

echo "Final sync from primary: $PRIMARY_PATH"
gt sync --cwd "$PRIMARY_PATH"

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

echo "Worktrees:"
while IFS= read -r wt_path; do
  wt_branch=$(git -C "$wt_path" branch --show-current)
  echo "- $wt_path"
  if [ -z "$wt_branch" ]; then
    echo "  <detached>"
    continue
  fi
  echo "  $wt_branch"
  info=$(gt info --branch "$wt_branch" --cwd "$wt_path" 2>/dev/null || true)
  pr_line=$(printf '%s\n' "$info" | sed -n '/^PR #/p' | head -1)
  pr_url=$(printf '%s\n' "$info" | sed -n '/^https:\/\/app\.graphite\.com\//p' | head -1)
  if [ -n "$pr_line" ]; then
    echo "  $pr_line"
  fi
  if [ -n "$pr_url" ]; then
    echo "  $pr_url"
  fi
done < "$WT_LIST"
rm -f "$WT_LIST"
```

## After standup

- Paste the script's `Worktrees:` block as a code block. One checkout per entry: path, branch, and the Graphite `PR #` line plus link when the branch has an open PR. Include idle `dev/wtN` worktrees.
- Start new work only after sync completes on **all** worktrees.
- Use `/graphite` for create/modify/submit when making changes.
