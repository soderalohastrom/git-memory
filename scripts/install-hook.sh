#!/bin/bash
# Install git-memory post-commit hook in current repo
HOOK_PATH=".git/hooks/post-commit"
SCRIPT_PATH="$HOME/clawd/skills/git-memory/scripts/git-memory.sh"

if [ ! -d .git ]; then
  echo "Not a git repo"; exit 1
fi

# Append to existing hook or create new one
if [ -f "$HOOK_PATH" ]; then
  if grep -q "git-memory" "$HOOK_PATH"; then
    echo "Hook already installed"; exit 0
  fi
  echo -e "\n# git-memory: auto-index on commit\nbash \"$SCRIPT_PATH\" index --quiet 2>/dev/null &" >> "$HOOK_PATH"
else
  cat > "$HOOK_PATH" << EOF
#!/bin/bash
# git-memory: auto-index on commit
bash "$SCRIPT_PATH" index --quiet 2>/dev/null &
EOF
  chmod +x "$HOOK_PATH"
fi
echo "✅ post-commit hook installed"

# Also init + refresh if not already done
bash "$SCRIPT_PATH" init
bash "$SCRIPT_PATH" refresh-claude-md
echo "✅ git-memory ready"
