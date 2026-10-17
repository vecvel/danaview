# Agent notes

## Git workflow

- Editor work lands on `editor-wip`. The Android lane exists only as the remote
  branch `origin/editor-android` (no local copy); bring it in with
  `git merge --no-ff origin/editor-android` and the message
  `Merge remote-tracking branch 'origin/editor-android' into editor-wip`.
- Mac and Windows/Android lanes checkpoint independently as
  `chore(editor): work-in-progress backup (<lane> lane)` commits, so `editor-wip`
  and `editor-android` routinely diverge; expect merges, not fast-forwards.
- `editor-wip` is shared: rewriting a published commit needs
  `git push --force-with-lease`, and other lanes must fetch + reset rather than pull.
- Never add Codebuff/AI attribution to commits in this repo — no
  `Co-Authored-By: Codebuff` line and no "Generated with" footer. The owner
  asked for this explicitly.
- When a change is done, commit it and push to `origin/editor-wip` without waiting
  to be asked; the owner asked for this explicitly.

## Local-only state

- `.freebuff/` holds machine-local Freebuff state (e.g. `project-id`); it is
  gitignored and should never be tracked or swept into WIP backup commits.
- Delete scratch files you create for checks (preview HTML, copied assets, temp
  dirs) once the check passes; that directory is ignored, so leftovers go unnoticed.

## Tool quirks

- `register_preview` with `htmlPath` serves only that one file: sibling and relative
  asset paths 404. To preview HTML against real repo assets, serve the repo root
  (`python3 -m http.server <port> --bind 127.0.0.1`) and open it via `preview_open`.
- Backgrounding a server inside a SYNC command does not survive tool cleanup; start
  it with `process_type: BACKGROUND` and probe it with HTTP before previewing.
