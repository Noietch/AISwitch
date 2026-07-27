#!/usr/bin/env bash
# AISwitch installer — copies aisw.zsh + a starter config into ~/.aisw
# and wires it into ~/.zshrc. Safe to re-run: never overwrites your config.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${AISW_DIR:-$HOME/.aisw}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
LINE='source ~/.aisw/aisw.zsh'

c()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
ok() { c '32' "✓ $1"; }
inf(){ c '36' "› $1"; }
warn(){ c '33' "! $1"; }

[ -f "$SRC/aisw.zsh" ] || { c '31' "✗ aisw.zsh not found next to this script"; exit 1; }

mkdir -p "$DEST"

# --- aisw.zsh (always refreshed) -------------------------------------------
cp "$SRC/aisw.zsh" "$DEST/aisw.zsh"
ok "installed $DEST/aisw.zsh"

# --- config (never clobbered — it holds your keys) --------------------------
if [ -e "$DEST/config" ]; then
  inf "kept your existing $DEST/config"
  # Surface new keys added by later versions without touching the live file.
  if ! diff -q "$SRC/config.example" "$DEST/config.example" >/dev/null 2>&1; then
    cp "$SRC/config.example" "$DEST/config.example"
    inf "refreshed config.example — diff it for newly added options"
  fi
else
  cp "$SRC/config.example" "$DEST/config"
  chmod 600 "$DEST/config"
  ok "created $DEST/config from the example — edit it with your keys"
fi
chmod 700 "$DEST" 2>/dev/null || true

# --- ~/.zshrc hook ----------------------------------------------------------
if [ -f "$ZSHRC" ] && grep -qF 'aisw.zsh' "$ZSHRC"; then
  inf "$ZSHRC already sources aisw.zsh"
else
  printf '\n# AISwitch\n%s\n' "$LINE" >> "$ZSHRC"
  ok "added the source line to $ZSHRC"
fi

# --- conflict check: settings.json env block wins over the environment -------
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q '"env"' "$SETTINGS" && grep -q 'ANTHROPIC_' "$SETTINGS"; then
  echo
  warn "$SETTINGS has an \"env\" block containing ANTHROPIC_* keys."
  echo "  Values there take precedence over environment variables, so switching"
  echo "  providers would appear to work while Claude Code keeps using the old one."
  echo "  Remove those keys (keep a backup); move any non-provider settings into"
  echo "  the [env] section of $DEST/config."
fi

command -v fzf >/dev/null 2>&1 || { echo; inf "fzf not found — the interactive picker needs it; 'aisw <name>' works without it"; }

echo
ok "done"
echo "  1. edit   $DEST/config"
echo "  2. reload exec zsh"
echo "  3. run    aisw ls"
