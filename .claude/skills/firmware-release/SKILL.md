---
name: firmware-release
description: Edit fork firmware correctly (clone vs tracked artifacts), build the three T1000-E flavors, and cut a provenance-pinned release (uf2 + dfu.zip + SHA256SUMS + RELEASE.md). Use for any firmware change or "cut release vX.Y".
---

This skill's full procedure lives in the agent-neutral home: **read and follow
[`skills/firmware-release.md`](../../../skills/firmware-release.md)** (repo root `skills/`).

Standing rule (TODO C1): agent-facing procedures are written vendor-neutrally so any
coding agent can use them; files under `.claude/` are Claude Code shims only —
when updating the procedure, edit the neutral file, never this pointer.
