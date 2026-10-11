---
name: no-claude-coauthor
description: Commits in this repo must not carry a Claude Co-Authored-By trailer
metadata:
  node_type: memory
  type: feedback
  originSessionId: 82e4ea82-570a-4648-b8b8-8e1276338981
  modified: 2026-10-10T13:42:41.489Z
---

On 2026-10-10 the owner asked me to remove the `Co-Authored-By: Claude …` line from a commit. Commits in this repo carry no Claude attribution trailer; only the owner (besaoct) appears.

**Why:** the owner wants their commits attributed to themselves only. This overrides the default commit attribution reminder.
**How to apply:** leave the trailer out of every commit message. For pull request descriptions, also leave out the "Generated with Claude Code" line unless the owner says otherwise. Related: [[video-editor-build]].
