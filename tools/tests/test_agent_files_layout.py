"""Enforce the agent-files genericity rule (AGENTS.md header; TODO C1).

Agent-facing material lives ONLY in the shared standard layout:

  AGENTS.md                          the single guidance source of truth (a real file)
  .agents/skills/<name>/SKILL.md     procedures, standard name/description frontmatter

Tool-specific locations may only LINK into it — `CLAUDE.md` is a symlink to AGENTS.md,
every entry under `.claude/skills/` is a symlink into `.agents/skills/`, and the same goes
for any other vendor entry file that ever appears. This test exists because the rule was
violated once (an ad-hoc repo-root `skills/` home, 2026-07-26) — it fails closed so the
problem is never revisited.
"""

import os
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
STANDARD_SKILLS = REPO / ".agents/skills"
# Known vendor entry-point files: if present, each MUST be a symlink to AGENTS.md.
VENDOR_ENTRY_FILES = [
    "CLAUDE.md",
    "GEMINI.md",
    ".cursorrules",
    ".github/copilot-instructions.md",
    ".windsurfrules",
]
_FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)


class AgentFilesLayoutTests(unittest.TestCase):
    def test_agents_md_is_the_real_root_source(self):
        agents = REPO / "AGENTS.md"
        self.assertTrue(agents.is_file(), "AGENTS.md must exist at the repo root")
        self.assertFalse(agents.is_symlink(), "AGENTS.md is the source of truth, not a link")

    def test_vendor_entry_files_are_symlinks_to_agents_md(self):
        agents_real = os.path.realpath(REPO / "AGENTS.md")
        for name in VENDOR_ENTRY_FILES:
            path = REPO / name
            if not path.exists() and not path.is_symlink():
                continue  # absent vendor files are fine; present ones must link
            self.assertTrue(
                path.is_symlink(),
                name + " must be a SYMLINK to AGENTS.md (no vendor-specific content)",
            )
            self.assertEqual(
                os.path.realpath(path),
                agents_real,
                name + " must resolve to AGENTS.md",
            )

    def test_standard_skills_home_exists_with_valid_frontmatter(self):
        self.assertTrue(STANDARD_SKILLS.is_dir(), ".agents/skills/ must exist")
        skill_dirs = sorted(
            entry for entry in STANDARD_SKILLS.iterdir()
            if entry.is_dir() and not entry.name.startswith(".")
        )
        self.assertTrue(skill_dirs, ".agents/skills/ must contain at least one skill")
        for skill_dir in skill_dirs:
            skill = skill_dir / "SKILL.md"
            self.assertTrue(skill.is_file(), skill_dir.name + " must contain SKILL.md")
            match = _FRONTMATTER.match(skill.read_text(encoding="utf-8"))
            self.assertIsNotNone(
                match, skill_dir.name + "/SKILL.md must start with YAML frontmatter"
            )
            front = match.group(1)
            self.assertRegex(
                front,
                r"(?m)^name:\s*" + re.escape(skill_dir.name) + r"\s*$",
                skill_dir.name + " frontmatter name must match its directory",
            )
            self.assertRegex(
                front,
                r"(?m)^description:\s*\S",
                skill_dir.name + " frontmatter must carry a description",
            )

    def test_tool_skill_dirs_only_symlink_into_the_standard_home(self):
        standard_real = os.path.realpath(STANDARD_SKILLS)
        claude_skills = REPO / ".claude/skills"
        if not claude_skills.is_dir():
            return
        for entry in sorted(claude_skills.iterdir()):
            if entry.name.startswith("."):
                continue  # .DS_Store and friends
            self.assertTrue(
                entry.is_symlink(),
                ".claude/skills/" + entry.name
                + " must be a symlink into .agents/skills (no copies, no shim files)",
            )
            target = os.path.realpath(entry)
            self.assertEqual(
                os.path.commonpath([target, standard_real]),
                standard_real,
                ".claude/skills/" + entry.name + " must resolve inside .agents/skills",
            )

    def test_no_adhoc_agent_locations(self):
        self.assertFalse(
            (REPO / "skills").exists(),
            "ad-hoc repo-root skills/ is forbidden — use .agents/skills/<name>/SKILL.md",
        )


if __name__ == "__main__":
    unittest.main()
