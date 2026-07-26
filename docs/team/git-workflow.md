# Git workflow quick reference

## Branching in this repo

No persistent `dev`/integration branch — `master` is the trunk, always
kept working. Everything else is a short-lived branch merged back via PR.

Branch names: `<type>/<short-title>`, using the same `type` prefixes as
[`conventional-commits.md`](conventional-commits.md) (`feat`, `fix`,
`docs`, `chore`, `refactor`, ...). Lowercase, hyphens, no ticket numbers.

```
feat/xfce-wallpaper-branding
fix/uefi-boot-splash
docs/update-branch-conventions
```

Workflow:
```
git checkout master && git pull          # start from a current trunk
git checkout -b feat/short-title         # branch
# ...make changes, commit(s)...
git push -u origin feat/short-title      # push the branch
gh pr create --base master               # open a PR into master
# after review/approval, merge on GitHub (or):
git checkout master && git pull          # bring the merge down locally
git branch -d feat/short-title           # delete the local branch, done
```

A ruleset on `master` enforces this for everyone, including owners
(`current_user_can_bypass: never`, no exceptions): every change lands via
PR, requiring 1 approval from `devs` and 1 from `testers` independently.
There is no direct-push shortcut, even for trivial doc fixes.

## Full dev workflow (short version)

Compressed reference: [`docs/team/workflow.md`](workflow.md). Full
rationale: [`docs/team/workflow-extended.md`](workflow-extended.md).

1. Work starts from a GitHub **Issue** (feature/bug), assigned to a dev.
   Use the Issue's "Create a branch" button so the branch auto-links back
   to it.
2. Dev codes on `type/short-title`, opens a PR, description includes
   `Fixes #<issue>`.
3. **The other dev** reviews (code quality + does it meet the ask) —
   approve or "Request changes" on the PR.
4. **Tester** boots the PR's build and tests it — approve or "Request
   changes".
5. Once both approve: **Squash-merge**, author merges their own PR — no
   need to wait on an admin, and merge isn't gated on the AI pass.
6. **Claude reviews the merged commit**, post-merge (catches what humans
   missed, triggered by the merge itself rather than every push). Clean →
   done. Finds something → auto-files a new Issue against the merged
   change, picked up as normal new work (back to step 2).
7. To get a test ISO built for a PR: add the `test-me` label. CI builds it
   and publishes a clearly-marked pre-release (never on every push, only
   when labeled).

Separately, not tied to any one PR: Claude does a broader sweep of `master`
a few times a week.

## Daily loop
- `git status` — what's changed
- `git add <file>` (or `git add -p` to review hunks) — stage
- `git commit -m "..."` — commit staged changes
- `git push` — send to remote
- `git pull` — get remote changes (fetch + merge)

## Starting work
- `git clone <url>` — get a repo (use the host alias for the right account)
- `git checkout -b feature-name` — new branch off current
- `git branch` — list branches, `*` = current
- `git checkout main` — switch branch

## Before pushing
- `git diff` — unstaged changes
- `git diff --staged` — staged changes
- `git log --oneline -10` — recent commits

## Merging your branch back
- `git checkout main && git pull` — update main first
- `git merge feature-name` — merge feature into main
- or open a PR on GitHub and merge there (preferred for anything shared)

## Undoing things
- `git restore <file>` — discard unstaged changes to a file
- `git restore --staged <file>` — unstage (keep changes)
- `git commit --amend` — fix the last commit message/content (only if not pushed yet)
- `git reset --soft HEAD~1` — undo last commit, keep changes staged
- `git stash` / `git stash pop` — shelve changes temporarily

## Remotes
- `git remote -v` — show remote URLs
- `git remote set-url origin <url>` — fix a wrong remote (e.g. wrong account alias)

## Rule of thumb
Small commits, pull before you push, branch for anything not trivial, never force-push a shared branch without asking.
