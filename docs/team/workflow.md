# Dev workflow — quick reference

Compressed. No rationale — see [`workflow-extended.md`](workflow-extended.md)
for the "why" behind any of this.

## Roles / teams

| Team | Permission | Members |
|---|---|---|
| `devs` | push | ArchDevs, MichaelNovotny10, Michael104634 |
| `pms` | triage | MichaelNovotny10 |
| `testers` | push | BiBip88, Michael104634 |

Org owners (`ArchDevs`, `Michael104634`, `MichaelNovotny10`) have full
access to every repo regardless of team membership. 🐉/`lemsurlebleu` (PM)
not yet in the org.

## Pipeline

1. File a GitHub **Issue** (bug or feature — same object, told apart by
   `type:` label / Issue Form), assign a dev.
2. Dev branches from the Issue ("Create a branch" button), codes on
   `type/short-title`, opens PR with `Fixes #N`.
3. **Other dev** reviews → Approve / Request changes.
4. **Tester** boots the build, tests → Approve / Request changes.
   (Not required if the PR only touches `*.md`/`.gitignore`.)
5. Once both approve, **squash-merge** — author merges their own PR, no
   admin needed, merge isn't gated on the AI pass.
6. **Claude reviews the merged commit** post-merge (final check). Clean →
   done. Issue found → auto-files a new Issue, picked up as normal new
   work (back to step 2).

Separately: Claude sweeps all of `master` every 2-3 days, independent of
per-PR review.

## Branching

- No `dev` branch — `master` is trunk.
- Branch names: `type/short-title` (same types as
  [`conventional-commits.md`](conventional-commits.md)).
- Commands: see [`git-workflow.md`](git-workflow.md).

## `master` ruleset

- PR required, no bypass for anyone (including owners).
- 1 approval from `devs` (all files) **and** 1 from `testers`
  (`file_patterns` excludes `*.md`/`.gitignore`-only PRs; `branding/`
  stays in scope), independently required.
- `shellcheck` required status check.
- Squash merge only.

## Issues

- Bug and feature request = same object (Issue), differentiated by
  `type: bug` / `type: feature` label (Issue Forms — not yet built).
- **Stale assignment**: if an Issue is assigned and doesn't get the
  `in-progress` label within 12h (clock restarts on reassignment), an
  Action unassigns it and tags the PM to reassign. Not yet built.
- **Availability**: use your GitHub profile status (Busy flag) — no
  custom system.

## CI

- **`shellcheck`** (`.github/workflows/shellcheck.yml`) — runs on every
  PR, lints only changed `*.sh` files. Required check on `master`.
- **`iso-test-build`** (`.github/workflows/iso-test-build.yml`) — add the
  `test-me` label to a PR to build an ISO (`mkiso.sh -b gnome`) and
  publish it as a pre-release (`pr-<N>-test`, prerelease flag, fixed
  warning title/body). Watermarks baked in: desktop wallpaper, GDM
  login/lock background, boot splash, `/etc/issue`. Not yet exercised
  end-to-end.
- Build target: glibc x86_64 only for now.

## Discord — optional

Bot planned (token pending from Michael). Nothing else depends on it.

## Attribution

Claude Code commit co-author trailer disabled globally
(`~/.claude/settings.json`), verified.

## Status: what's actually real right now

**Done:** `devs`/`pms`/`testers` teams + permissions, `master` ruleset
(reviewers + `shellcheck` check), Projects board (Backlog/Assigned/In
Review/Testing/Done), `shellcheck` workflow, `iso-test-build` workflow
(written, untested end-to-end), `test-me` label, attribution disabled.

**Not built:** Issue Forms + `type:` labels, `in-progress` label + 12h
reassignment Action, PR template, CODEOWNERS, Discord bot, official
versioned releases, 🐉's org invite (waiting on his GitHub username).
