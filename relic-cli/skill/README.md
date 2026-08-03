# Relic agent skill

`SKILL.md` is an [Anthropic Agent Skill](https://www.anthropic.com/news/skills)
that teaches an AI agent how and when to use the `relic` CLI: searching and
recalling vault content, adding new relics, and the hard rule that deletion
stays off unless the user explicitly grants it.

It is portable: the same `SKILL.md` works in any compatible agent (Claude Code,
Cursor, Codex, and others) via progressive disclosure. The frontmatter
`description` is what triggers it, so the agent only loads the body when the user
talks about copied snippets, commands, links, notes, screenshots, "what did I
copy", "save this to Relic", and similar.

## Prerequisite

The `relic` binary must be installed and on PATH (see the crate `README.md`), and
the Relic desktop app must be installed/set up (the CLI is a shim over the app's
local data). `relic status` reports both; exit code 3 means the app isn't set up.
The CLI can also install this skill itself: `relic skill --install`.

## Distribution (production)

This file is the source of truth. For production it is intended to be:

- published as a **public GitHub repo** that users can pull down into their
  agent's skills directory (for Claude Code: `~/.claude/skills/relic/SKILL.md`),
  and
- surfaced as **copyable text on the website**.

To try it locally before then, copy `SKILL.md` into your agent's skills
directory, e.g. `~/.claude/skills/relic/SKILL.md`, and start a new session
(skills are scanned at startup).

## Keep it in sync

When CLI commands, flags, output schema, or exit codes change, update `SKILL.md`
alongside the code so the agent's playbook stays accurate.
