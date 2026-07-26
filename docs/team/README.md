# CatOS-mklive — team docs

Start here. Everything in this directory is committed and meant for the
whole team (devs, PM, testers) — not personal notes.

## Workflow

- **[workflow.md](workflow.md)** — start here. Compressed reference: roles,
  pipeline, ruleset, CI, everything — no explanations, just how it works.
- **[workflow-extended.md](workflow-extended.md)** — the same, but with
  the "why" behind every decision (and what was tried first and rejected).
  Read this if something in `workflow.md` seems arbitrary.
- **[git-workflow.md](git-workflow.md)** — general day-to-day git commands
  (branching, committing, undoing things) plus the short pipeline summary.
- **[conventional-commits.md](conventional-commits.md)** — commit message
  format and types.

## Code architecture reference

Read these before touching the actual build scripts.

- **[build-pipeline.md](build-pipeline.md)** — `mklive.sh`, `mkiso.sh`,
  `mkrootfs.sh`, `mkplatformfs.sh`, `mkimage.sh`, `mknet.sh`, and friends:
  how a live ISO / rootfs tarball / platform image actually gets built,
  script by script, with the full call graph.
- **[dracut-modules.md](dracut-modules.md)** — what runs inside the
  initramfs when the built image boots (user creation, display-manager
  autologin, accessibility, locale, unattended install, PXE netmenu).
- **[branding-and-outputs.md](branding-and-outputs.md)** — branding
  overlay mechanism, boot-menu templates, ARM platform definitions, xbps
  signing keys, and the two build paths that aren't part of the main
  mklive.sh/mkiso.sh pipeline (Packer images, the build-environment
  container).
- **[notes.md](notes.md)** — cross-file gotchas that don't belong in any
  one script's doc (e.g. what actually controls the default desktop
  session at boot).
