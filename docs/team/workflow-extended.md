# Dev workflow — full design and rationale

This is the detailed version, with the "why" behind every decision. For a
compressed getting-started reference, see [`workflow.md`](workflow.md).

Designed 2026-07-25 for the real team size: Michael + ArchDevs as devs,
BiBip88 as tester, 🐉 (`lemsurlebleu`, GitHub username still unknown) as
admin/PM. Deliberately
**not** a copy of a big-company process — sized for 3 active people plus
one AI reviewer, not a company with dedicated bench depth per role.

## Why this shape (not the first draft)

The original proposal had 5 sequential human gates (assign → code →
requirements-check → test → accept) plus a scheduled next-day AI pass plus
an admin-reassignment loop. Problems with that, in order of how much they
mattered:

- **Team reality**: only 2 people can meaningfully code-review (Michael,
  ArchDevs). A separate "requirements checker" role distinct from "code
  reviewer" would just be one of those same 2 people doing a second pass —
  not independent verification, just latency. Testing is a real distinct
  gate because BiBip88 has a different skill (boots hardware, can't read
  shell) — that's the one gate worth keeping separate from code review.
- **Timing**: "Claude reviews next day at 8am" means a real bug can sit in
  `master` for up to 24h before anything catches it — the opposite of
  "trunk always releasable." Also assumes a shared timezone the team
  doesn't have.
- **Vocabulary mismatch with GitHub**: "reject with a comment," "reopen a
  branch," "branch description," "admin assigns a branch to someone" don't
  map onto real GitHub primitives. See the mapping table below — using the
  actual primitives avoids inventing process that has no tooling support.

## Roles

- **Michael** (dev) — controls both `Michael104634` and `MichaelNovotny10`
  GitHub accounts; keep these two uncorrelated outside this org (see the
  `github-account-separation` memory).
- **ArchDevs** (dev) — can do real code review.
- **BiBip88** (tester) — boots ISOs and checks behavior; not expected to
  code-review. Org member, not owner. In the `testers` team.
- **🐉 / `lemsurlebleu`** (admin/PM) — originated the CatOS idea, sets
  requirements and (with Michael/ArchDevs' input on feasibility) timelines.
  **Not yet invited to the org** — pending his actual GitHub username.

Org structure: `catos-project` owners (`ArchDevs`, `Michael104634`,
`MichaelNovotny10`) get full access to every repo automatically, regardless
of team membership. Role teams (replaced the original flat `core-team` on
2026-07-25 — role-based instead of one undifferentiated write-access
team), each with a repo permission matching what that role actually needs:

| Team | Repo permission | Members |
|---|---|---|
| `devs` | `push` (write) | ArchDevs, MichaelNovotny10, Michael104634 |
| `pms` | `triage` (manage issues/PRs/labels, no code write) | MichaelNovotny10 |
| `testers` | `push` (write — bumped from read 2026-07-25: GitHub doesn't count a read-only approval toward a ruleset's required-reviews check, so testers need write for their PR approval to actually gate merges) | BiBip88, Michael104634 |

`Michael104634` was originally excluded from all teams (representing
Michael's dev/PM roles through `MichaelNovotny10` alone, keeping the two
personal accounts uncorrelated outside plain org ownership — see the
`github-account-separation` memory) but was added to `devs` and `testers`
on 2026-07-25 so Michael can self-approve minor PRs when nobody else is
around. **This is a deliberate, acknowledged exception to "one dev + one
tester" independent review** — Michael can now satisfy both required
reviewer slots on his own PRs. Justified for now by low current PR volume
and no active team availability; revisit once the team is actually
active. It doesn't violate account-separation (that's about not linking
git/commit identities across the two accounts, not about org team
membership depth) — both accounts already shared the org itself.

## The pipeline

```
Issue filed (feature/bug), assigned to a dev
        │  (dev uses the Issue's "Create a branch" button —
        │   auto-names + auto-links branch↔issue)
        ▼
Dev codes on type/short-title, opens PR (description: "Fixes #N")
        │
        ▼
Other dev reviews — Approve, or "Request changes" (→ back to coding,
        │            same PR, no new branch needed)
        ▼ (approved)
Tester boots the PR's build, tests — Approve, or "Request changes"
        │ (approved)                 (→ back to coding, same PR)
        ▼
Author squash-merges their own PR (both approvals in hand — no need
        │  to wait on an admin, and merge isn't gated on the AI pass)
        ▼
Claude reviews the merged commit, post-merge (deliberately fires on
        │  the merge event, not on every push — so it reviews the
        │  finished, human-approved version that actually landed on
        │  `master`, not WIP)
        │
   ┌────┴────┐
clean      finds something
   │            │
   ▼            ▼
done       auto-files a new Issue (checked first for an existing one
           referencing this PR, to avoid duplicates on a retried run),
           assigned to the merged PR's original author if determinable,
           else any `devs` member — picked up as normal new work
```

Separately, **not** tied to any single PR: Claude sweeps the whole
`master` branch a few times a week (roughly every 2-3 days), independent
of the per-PR review. This is a second, broader pass — it doesn't replace
the per-PR review above.

## Issues: bugs and feature requests are the same object

GitHub has no separate object type for a "feature request" — both are
**Issues**. They're told apart by **Issue Forms** (structured YAML
templates under `.github/ISSUE_TEMPLATE/`): a "Bug report" form and a
"Feature request" form, each auto-applying a label (`type: bug` /
`type: feature`) on submission. Not yet implemented.

## Stale-assignment auto-reassignment

If an assigned Issue has gone **12h since assignment** without the
**`in-progress`** label applied, automation flags it:

- Label name: `in-progress`, not "working" — matches the de facto GitHub
  convention, reads as a state rather than a vague category.
- **The clock is "time since last assignment," not "time since Issue
  creation."** It restarts every time the Issue is reassigned, so a fresh
  assignee always gets their own full 12h window rather than inheriting
  whatever was left on the original assignee's clock.
- On expiry: the bot **unassigns and comments, tagging the PM** — it does
  **not** auto-pick a replacement dev itself. Picking a good replacement
  depends on judgment (who's actually free, who has context, is this
  urgent) that isn't safe to fully automate; a bot blindly reassigning to
  someone whose GitHub status is stale or who's mid-vacation is worse than
  just flagging a human. The PM makes the actual reassignment call.
- Mechanism: a scheduled GitHub Action (hourly cron) queries open,
  assigned Issues lacking `in-progress`, checks time since the assignment
  event (not `created_at`), acts on anything past 12h. Not yet
  implemented.

## Availability

Don't build a custom system for this — **GitHub already has it**. Every
user can set a **profile status** (their GitHub profile → "Edit status"):
an emoji + short text, plus an optional **"Busy" flag**. It's visible on
hover wherever someone's `@mentioned` and on their profile, it's
self-service (each person sets their own, no PR/commit needed, no PM
overhead to keep it current), and — the part that matters for the
reassignment automation above — it's **queryable via the GraphQL API**
(`user.status.indicatesLimitedAvailability`), so the PM (or eventually the
reassignment bot, if that's ever automated further) can actually check it
rather than relying on someone remembering to ping Discord. Rejected
alternatives: a roster file in the repo (needs a commit to update — too
much friction for something that changes daily), a Discord role (works,
but disconnected from where assignment actually happens on GitHub).

## GitHub mechanics — what each stage actually is

The original proposal used vocabulary that doesn't exist in GitHub. This
table is the actual mapping, so nobody goes looking for a "reopen branch"
button that isn't there.

| What we call it | What it actually is on GitHub |
|---|---|
| Filing a request/bug with context | A GitHub **Issue** (body = the requirements/repro steps) |
| Admin assigns work to a dev | Issue **assignee** (`gh issue edit --add-assignee <user>`) |
| Branch tied to its request | Issue's **"Create a branch"** button — auto-links, don't create branches by hand for tracked work |
| "Someone checks requirements are met" | A **PR review**, requested from a specific person |
| "Reject with a comment" | PR review state **Request changes** — PR stays open, new commits to the same branch land on it automatically |
| "Testers test, reject if buggy" | Also a PR review (Approve / Request changes) — or a Projects board "Testing" column if you want status visible outside formal review |
| Enforcing reviews + CI before merge | A **ruleset** on `master` — **live as of 2026-07-25** ([`master protection`](https://github.com/catos-project/CatOS-mklive/rules/19734247)): requires PR, requires 1 approval from `devs` (all files, `file_patterns: ["**"]`) and 1 from `testers` *independently* (the [required-reviewer rule](https://github.blog/changelog/2025-11-03-required-review-by-specific-teams-now-available-in-rulesets/), GA Feb 2026 — this is what makes "one dev + one tester" an actual gate instead of "any 2 approvals from anyone"), plus `shellcheck` as a required status check, no bypass for anyone including owners. **`testers`' requirement is scoped** (`file_patterns: ["**", "!*.md", "!**/*.md", "!.gitignore"]`, using [negation-pattern support](https://github.blog/changelog/2026-02-17-required-reviewer-rule-is-now-generally-available/)) — a PR touching only Markdown/`.gitignore` doesn't need a tester, since there's nothing to boot-test. `branding/` changes deliberately stay in scope for testers even though they're not code, since they affect what gets built into the actual ISO — exactly what a tester should eyeball. `devs`' requirement is not scoped, applies to everything including docs. |
| "Reopen a branch" after a post-merge bug | Doesn't exist. Either file a new Issue + new branch (normal case), or `git revert` the merge commit if it's actively broken (urgent case) |
| Tracking status across the pipeline | A **GitHub Projects** board (Backlog → Assigned → In Review → Testing → Done) |

## CI / automation

- **Trigger for building a test ISO: the `test-me` label**, not every
  push. Dev adds it when the PR is actually ready for BiBip88 to test —
  avoids burning CI time and cluttering Releases with WIP builds.
- Public repos get **free, unlimited minutes** on GitHub-hosted Linux
  runners — this was a real misconception worth correcting; the actual
  cost is wall-clock build time (~5-6 min locally, similar order on CI),
  not quota.
- The friction in "devs don't want to manually upload a 2GB ISO and write
  a release message" is solved by automating exactly that step — a GitHub
  Action runs `gh release create` with a fixed template, no dev ever
  touches a release page by hand.
- **Build target: glibc x86_64 only for now.** musl (Alpine's base libc,
  smaller/stricter, less binary-compatible with proprietary software) and
  aarch64/platform builds are explicitly deferred — expand the CI matrix
  once the core workflow is proven, not before.
- Add `shellcheck` as an early, cheap automated gate on every PR (before
  any human review) — catches syntax errors for free. Not yet implemented.

## Release marking (so nobody installs a test build by accident)

- Every CI-built release is a GitHub **pre-release**, public (repo is
  public — no tester-only distribution mechanism was worth the extra
  infrastructure for a team this size), named e.g. `pr-<number>-test`,
  with a fixed, non-editable title/body template:
  `⚠️ TEST BUILD — pr-42 — NOT FOR INSTALLATION`.
- The ISO itself gets a **watermark baked in**, so the warning survives
  even if someone ignores the release notes — and it needs to be visible
  *while using the desktop*, not just once at boot (the first
  implementation only watermarked the boot splash + `/etc/issue`, both of
  which vanish once the desktop loads; that's not what "big enough to
  notice in the first 5 seconds when you look at the screen" meant).
  Implemented as of 2026-07-25, via the postsetup script in
  `.github/workflows/iso-test-build.yml`: a generated image with the
  warning banner repeated top/center/bottom (so it survives icons/dock/
  panel covering part of it) is set as **both the desktop wallpaper and
  the GDM login/lock screen background** via dconf, plus kept as the boot
  splash and prepended to `/etc/issue` as cheap extra layers. The dconf/
  GDM mechanism is GNOME-specific (matches `-b gnome`, what this workflow
  currently builds) and **unverified against Void's actual GNOME/GDM
  packaging** — same "written but not exercised end-to-end" caveat as the
  rest of this workflow.

## GitHub secrets — what's actually true (came up re: the Discord webhook)

Once a value is saved into a GitHub Actions secret, **it's write-only** —
nobody, not even org owners, can view the plaintext again via the UI or
API, only overwrite it. The real access boundary is **who can edit
workflow files or push branches those workflows trust** (since a workflow
step can always `echo` a secret it has access to) — currently that's org
owners plus the `devs` team (`push` permission — Michael via
MichaelNovotny10, ArchDevs). Forked-repo PRs don't get
secret access by default; don't opt into `pull_request_target` carelessly
once external contributors show up.

## Discord integration — **optional**

Superseded 2026-07-25: originally planned as a native GitHub→Discord
webhook (no bot, no hosting — see git history of this file for that
version's reasoning). Michael now wants an actual Discord bot instead, and
will provide its token + channel/chat ID + granted permissions when ready.
This is explicitly **optional** — nothing else in this workflow depends on
it existing. Setup will most likely happen in a separate session once the
token is available; see the `discord-bot-plan` memory for the context a
future session needs to pick this up (never the token itself — that goes
straight into a GitHub Actions secret the moment it's provided, never into
a file or memory).

## Attribution

Claude Code's automatic `Co-Authored-By: Claude` commit trailer is
disabled globally on this machine (`~/.claude/settings.json`:
`attribution.commit`/`attribution.pr` set to `""`). Verified end-to-end on
a throwaway test repo: clean commit body, and Claude does not appear in
GitHub's contributors list.

## Implemented so far

Real, as of 2026-07-25:
- `devs`/`pms`/`testers` teams and their repo permissions (see Roles
  table above), replacing the original flat `core-team`.
- Claude Code commit attribution disabled and verified (see § Attribution
  below).
- `master` ruleset requiring 1 approval each from `devs` and `testers`,
  no bypass for anyone (see § GitHub mechanics above).
- GitHub Projects board (org project #1,
  https://github.com/orgs/catos-project/projects/1), `Status` field set to
  Backlog / Assigned / In Review / Testing / Done, linked to this repo.
  Currently private visibility (org members only) — flip to public later
  if wanted, not decided either way.
- `shellcheck` CI workflow (`.github/workflows/shellcheck.yml`) — lints
  only the files a PR actually changes, not the whole tree (the first cut
  linted everything and failed immediately on pre-existing warnings in
  inherited upstream Void scripts it never touched; fixed to diff-only).
  Verified live on a real PR, now wired into the `master` ruleset as a
  required status check (context `shellcheck`).
- The `test-me` label exists.
- CI ISO-build workflow (`.github/workflows/iso-test-build.yml`) —
  triggers on the `test-me` label, builds via `mkiso.sh -b gnome`,
  watermarks the desktop wallpaper, GDM login/lock screen, boot splash,
  and `/etc/issue` (see § Release marking above), publishes a
  `pre-release` tagged `pr-<number>-test`. **Written but not yet exercised
  end-to-end** — needs a real `test-me` label test to confirm the build
  actually completes on a hosted runner (disk space / timeout are the
  main risks) before trusting it fully.

Everything else in this doc is still design, not built yet.

## Still open / not yet implemented

- `lemsurlebleu`'s GitHub username + the actual org invite.
- Bug report / feature request Issue Forms + their `type:` labels.
- The `in-progress` label itself, and the 12h stale-assignment
  auto-reassignment Action.
- PR template.
- CODEOWNERS for sensitive paths like `dracut/`, `mklive.sh` — a maybe,
  not decided.
- Live end-to-end test of the ISO-build workflow (see above).
- Discord webhook itself (Michael needs to create it in the Discord server
  first — this can't be done from here) and the GitHub-side wiring.
- A real "official" versioned release process (v0.x, distinct from these
  continuous test builds) — not needed yet, revisit once the team actually
  ships something.
- Availability itself needs no implementation (GitHub profile status
  already exists) — just needs each dev to actually set theirs.
