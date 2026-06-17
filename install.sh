#!/usr/bin/env bash
# install.sh — Install wp-optimize skill for Claude Code

SKILLS_DIR="$HOME/.claude/skills"
SKILL_FILE="wp-optimize.md"

mkdir -p "$SKILLS_DIR"

if cp "$SKILL_FILE" "$SKILLS_DIR/$SKILL_FILE"; then
  echo "✓ Skill installed at $SKILLS_DIR/$SKILL_FILE"
  echo "  Use it in Claude Code with: /wp-optimize"
else
  echo "✗ Failed to copy skill. Check permissions on $SKILLS_DIR"
  exit 1
fi
