---
name: bench-verify
description: Run (or extend) the hardware-in-the-loop regression suite that gates every firmware protocol change — adaptive TX semantics, TRACK upload/commit/reboot durability. Use before shipping firmware, after flashing, or when asked to "verify on hardware".
---

This skill's full procedure lives in the agent-neutral home: **read and follow
[`skills/bench-verify.md`](../../../skills/bench-verify.md)** (repo root `skills/`).

Standing rule (TODO C1): agent-facing procedures are written vendor-neutrally so any
coding agent can use them; files under `.claude/` are Claude Code shims only —
when updating the procedure, edit the neutral file, never this pointer.
