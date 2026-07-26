# Conventional Commits quick reference

Format: `type(scope): description`

Scope is optional. Description is lowercase, imperative, no trailing period.

## Types
- `feat` — new feature
- `fix` — bug fix
- `docs` — documentation only
- `style` — formatting, no code meaning change (whitespace, semicolons)
- `refactor` — code change that's neither a fix nor a feature
- `perf` — performance improvement
- `test` — adding or fixing tests
- `build` — build system or dependencies (npm, cargo, docker, etc)
- `ci` — CI config/scripts
- `chore` — everything else (repo maintenance, no src/test change)
- `revert` — reverts a previous commit

## Breaking changes
Two ways to mark one, use either:
- `!` after type/scope: `feat(api)!: remove v1 endpoints`
- footer: `BREAKING CHANGE: <description>`

## Body and footer (optional)
```
type(scope): short summary

Longer explanation of why, if the summary isn't enough.

BREAKING CHANGE: describe what breaks and how to migrate
Fixes #123
```

## Examples
- `feat(auth): add refresh token support`
- `fix(parser): handle empty input without crashing`
- `docs(readme): add install instructions`
- `refactor(db): extract connection pool into its own module`
- `chore(deps): bump go version to 1.23`
- `feat(api)!: drop support for v1 endpoints`

## Why bother
- Commit type is machine-readable → tools can auto-generate changelogs and bump semver (feat = minor, fix = patch, breaking = major).
- Skimmable history — `git log --oneline` tells you what kind of change each commit is without opening it.
- Forces you to state one clear reason per commit instead of "misc changes".

Full spec: conventionalcommits.org
