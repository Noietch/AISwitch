# ============================================================================
# AISwitch — switch API providers for Claude Code / Codex, from zsh.
#
#   config:  ~/.aisw/config     — add a provider = add 4 lines
#   usage:   aisw / cc / cdx    — see `aisw help`
#
# How it works:
#   Claude — exports ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_MODEL.
#   Codex  — injects the provider via `-c model_providers.aisw.env_key=...`,
#            bypassing ~/.codex/auth.json and the config.toml provider block
#            entirely, so switching never mutates Codex's own state.
#
# NOTE: ~/.claude/settings.json must NOT contain an "env" block — values there
# take precedence over the environment and would silently override switching.
# ============================================================================

AISW_DIR="${AISW_DIR:-$HOME/.aisw}"
AISW_CONFIG="${AISW_CONFIG:-$AISW_DIR/config}"

# Cleared on every switch so a provider's values never leak into the next one.
# Label/proxy are per-kind: both sides are active at once, so a single shared
# variable would let whichever was applied last win.
typeset -ga _AISW_CLAUDE_VARS=(
  ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL
  ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_REASONING_MODEL ANTHROPIC_CUSTOM_HEADERS
  ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL
  AISW_CLAUDE_LABEL AISW_CLAUDE_PROXY
)
typeset -ga _AISW_CODEX_VARS=(
  AISW_CODEX_KEY CODEX_BASE_URL CODEX_WIRE_API CODEX_MODEL
  CODEX_REVIEW_MODEL CODEX_REASONING_EFFORT CODEX_EXTRA_CONF
  AISW_CODEX_LABEL AISW_CODEX_PROXY
)

_aisw_say() { print -P -- "%F{cyan}›%f $*" }
_aisw_ok()  { print -P -- "%F{green}✓%f $*" }
_aisw_err() { print -P -u2 -- "%F{red}✗%f $*" }

_aisw_mask() {
  local s="$1"
  (( ${#s} <= 12 )) && { print -r -- "${s:0:2}****"; return }
  print -r -- "${s:0:8}…${s: -4}"
}

# ---------------------------------------------------------------------------
# config parsing (INI-ish)
# ---------------------------------------------------------------------------
_aisw_get() {
  local want_sec="$1" want_key="$2"
  [[ -f $AISW_CONFIG ]] || return 1
  awk -v s="$want_sec" -v k="$want_key" '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ { sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec); next }
    sec == s {
      eq = index($0, "="); if (eq == 0) next
      key = substr($0, 1, eq-1); val = substr($0, eq+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (key == k) { print val; exit }
    }
  ' "$AISW_CONFIG"
}

_aisw_sections() {
  local want="$1"
  [[ -f $AISW_CONFIG ]] || return 1
  awk '/^[[:space:]]*\[(claude|codex)\./ {
        s = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s); print s
      }' "$AISW_CONFIG" | { [[ -n $want ]] && grep "^$want\." || cat; }
}

_aisw_env_pairs() {
  [[ -f $AISW_CONFIG ]] || return 1
  awk '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ { sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec); next }
    sec == "env" {
      eq = index($0, "="); if (eq == 0) next
      key = substr($0, 1, eq-1); val = substr($0, eq+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (key != "") print key "=" val
    }
  ' "$AISW_CONFIG"
}

# "mt" -> "claude.mt". A bare name must be unambiguous across kinds;
# if it isn't, say so instead of silently picking one.
_aisw_resolve() {
  local n="$1" s
  [[ $n == *.* ]] && { _aisw_sections | grep -qx "$n" && print -r -- "$n"; return }
  local -a hits=()
  for s in ${(f)"$(_aisw_sections)"}; do
    [[ ${s#*.} == $n ]] && hits+=($s)
  done
  case ${#hits} in
    1) print -r -- "$hits[1]"; return 0 ;;
    0) return 1 ;;
    *) _aisw_err "ambiguous name '$n' — use one of: ${(j:, :)hits}"; return 2 ;;
  esac
}

_aisw_kind_of()  { print -r -- "${1%%.*}" }
_aisw_short_of() { print -r -- "${1#*.}" }
_aisw_label_of() { _aisw_get "$1" label }
_aisw_current()  { local f="$AISW_DIR/current.$1"; [[ -f $f ]] && cat "$f" }

# ---------------------------------------------------------------------------
# apply to the current shell
# ---------------------------------------------------------------------------
_aisw_apply() {
  local sec kind v pair rc
  sec=$(_aisw_resolve "$1"); rc=$?
  if (( rc != 0 )); then
    (( rc == 1 )) && _aisw_err "no such provider: $1 (see: aisw ls)"
    return 1   # rc==2: _aisw_resolve already printed the ambiguity hint
  fi
  kind=$(_aisw_kind_of "$sec")

  local base key
  base=$(_aisw_get "$sec" base)
  key=$(_aisw_get "$sec" key)
  [[ -n $base && -n $key ]] || { _aisw_err "$sec is missing base or key"; return 1 }

  case $kind in
    claude) for v in $_AISW_CLAUDE_VARS; do unset $v; done ;;
    codex)  for v in $_AISW_CODEX_VARS;  do unset $v; done ;;
  esac

  for pair in ${(f)"$(_aisw_env_pairs)"}; do
    export "${pair%%=*}"="${pair#*=}"
  done

  if [[ $kind == claude ]]; then
    local m p
    m="$(_aisw_get "$sec" model)"; [[ -z $m ]] && m="$(_aisw_get default claude_model)"
    p="$(_aisw_get "$sec" proxy)"; [[ -z $p ]] && p="$(_aisw_get default proxy)"
    export ANTHROPIC_BASE_URL="$base" ANTHROPIC_AUTH_TOKEN="$key"
    if [[ -n $m ]]; then
      export ANTHROPIC_MODEL="$m" ANTHROPIC_SMALL_FAST_MODEL="$m" \
             ANTHROPIC_DEFAULT_OPUS_MODEL="$m" ANTHROPIC_DEFAULT_SONNET_MODEL="$m" \
             ANTHROPIC_DEFAULT_HAIKU_MODEL="$m"
    fi
    export AISW_CLAUDE_LABEL="$(_aisw_get "$sec" label)"
    [[ -n $p ]] && export AISW_CLAUDE_PROXY="$p"
  else
    local m e w p
    m="$(_aisw_get "$sec" model)";  [[ -z $m ]] && m="$(_aisw_get default codex_model)"
    e="$(_aisw_get "$sec" effort)"; [[ -z $e ]] && e="$(_aisw_get default codex_effort)"
    w="$(_aisw_get "$sec" wire)";   [[ -z $w ]] && w="$(_aisw_get default codex_wire)"
    p="$(_aisw_get "$sec" proxy)";  [[ -z $p ]] && p="$(_aisw_get default proxy)"
    export CODEX_BASE_URL="$base" AISW_CODEX_KEY="$key" \
           CODEX_MODEL="$m" CODEX_REASONING_EFFORT="$e" CODEX_WIRE_API="${w:-responses}"
    export AISW_CODEX_LABEL="$(_aisw_get "$sec" label)"
    [[ -n $p ]] && export AISW_CODEX_PROXY="$p"
  fi

  print -r -- "$sec" > "$AISW_DIR/current.$kind"
}

_aisw_restore() {
  local kind sec applied=0 pair
  for kind in claude codex; do
    sec=$(_aisw_current $kind)
    [[ -n $sec ]] && { _aisw_apply "$sec" >/dev/null 2>&1 && applied=1 }
  done
  # Still apply [env] when no provider is selected yet.
  if (( ! applied )); then
    for pair in ${(f)"$(_aisw_env_pairs)"}; do export "${pair%%=*}"="${pair#*=}"; done
  fi
  return 0
}

# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------
_aisw_ls() {
  local want="$1" kind sec cur short
  for kind in claude codex; do
    [[ -n $want && $want != $kind ]] && continue
    cur=$(_aisw_current $kind)
    print -P -- "\n%B${kind:u}%b"
    local -a secs=(${(f)"$(_aisw_sections $kind)"})
    (( ${#secs} )) || { print -P -- "  %F{242}(none — add one to $AISW_CONFIG)%f"; continue }
    for sec in $secs; do
      short=$(_aisw_short_of $sec)
      if [[ $sec == $cur ]]; then
        print -P -- "  %F{green}●%f %B${(r:14:)short}%b %F{242}$(_aisw_label_of $sec)%f"
      else
        print -P -- "  %F{242}○%f ${(r:14:)short} %F{242}$(_aisw_label_of $sec)%f"
      fi
    done
  done
  print
}

_aisw_show() {
  local sec kind
  if [[ -z $1 ]]; then
    for kind in claude codex; do
      local c=$(_aisw_current $kind); [[ -n $c ]] && _aisw_show "$c"
    done
    return
  fi
  sec=$(_aisw_resolve "$1") || { _aisw_err "no such provider: $1"; return 1 }
  kind=$(_aisw_kind_of "$sec")
  print -P -- "\n%B$sec%b %F{242}$(_aisw_label_of $sec)%f"
  local -a vars
  case $kind in
    claude) vars=(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL) ;;
    codex)  vars=(CODEX_BASE_URL AISW_CODEX_KEY CODEX_MODEL CODEX_WIRE_API CODEX_REASONING_EFFORT) ;;
  esac
  # Resolve in a subshell so [default] fallbacks are reflected.
  local k v
  for k in $vars; do
    v=$(_aisw_apply "$sec" >/dev/null 2>&1; print -r -- "${(P)k}")
    [[ -z $v ]] && continue
    if [[ $k == *KEY* || $k == *TOKEN* ]]; then
      printf "  %-26s %s\n" "$k" "$(_aisw_mask $v)"
    else
      printf "  %-26s %s\n" "$k" "$v"
    fi
  done
  print
}

_aisw_use() {
  local name="$1" sec
  [[ -z $name ]] && { name=$(_aisw_pick) || return 1; [[ -z $name ]] && return 1 }
  _aisw_apply "$name" || return 1
  sec=$(_aisw_resolve "$name")
  _aisw_ok "%B$(_aisw_kind_of $sec)%b → %B$(_aisw_short_of $sec)%b %F{242}$(_aisw_label_of $sec)%f"
}

_aisw_pick() {
  if ! command -v fzf >/dev/null; then
    _aisw_err "fzf not installed — use: aisw use <name>"; _aisw_ls; return 1
  fi
  local sec kind cur mark
  local -a rows
  for kind in claude codex; do
    cur=$(_aisw_current $kind)
    for sec in ${(f)"$(_aisw_sections $kind)"}; do
      [[ $sec == $cur ]] && mark="●" || mark=" "
      # Full section name after a TAB: hidden from display, recovered via cut.
      rows+=("${mark}  ${(r:8:)kind}  ${(r:14:)$(_aisw_short_of $sec)}  $(_aisw_label_of $sec)	$sec")
    done
  done
  (( ${#rows} )) || { _aisw_err "no providers in $AISW_CONFIG"; return 1 }
  print -rl -- $rows | fzf --height=40% --reverse --with-nth=1 --delimiter=$'\t' \
      --header='switch provider  (● = active)' --prompt='aisw ❯ ' | cut -f2
}

_aisw_test() {
  local name="${1:-}" sec kind out
  [[ -z $name ]] && name=$(_aisw_current claude)
  sec=$(_aisw_resolve "$name") || { _aisw_err "no such provider: $name"; return 1 }
  kind=$(_aisw_kind_of "$sec")
  _aisw_say "probing %B$sec%b → $(_aisw_get $sec base)"

  # Drive the real CLI: matches the exact auth path and endpoint it uses.
  if [[ $kind == claude ]]; then
    out=$(cc -P "$sec" -p 'say ok' 2>&1)
  else
    out=$(cdx -P "$sec" exec --skip-git-repo-check 'say ok' 2>&1)
  fi

  if print -r -- "$out" | grep -qiE '401|invalid.?api.?key|unauthorized'; then
    _aisw_err "key rejected"
    print -r -- "$out" | grep -iE '401|invalid.?api.?key' | head -1 | sed 's/^/    /'
  elif print -r -- "$out" | grep -qiE 'invalid model|model.*not.*(found|allowed)'; then
    _aisw_err "model not accepted by this provider"
    print -r -- "$out" | grep -iE 'invalid model' | head -1 | sed 's/^/    /'
  elif print -r -- "$out" | grep -qiE '^ERROR|error sending request|reconnect|timed out'; then
    _aisw_err "request failed (check network/proxy)"
    print -r -- "$out" | grep -iE 'ERROR' | head -1 | sed 's/^/    /'
  else
    _aisw_ok "ok"
  fi
}

_aisw_which() {
  local kind cur
  for kind in claude codex; do
    cur=$(_aisw_current $kind)
    if [[ -n $cur ]]; then
      print -P -- "  %B${(r:8:)kind}%b %F{green}$(_aisw_short_of $cur)%f %F{242}$(_aisw_label_of $cur)%f"
    else
      print -P -- "  %B${(r:8:)kind}%b %F{242}(unset)%f"
    fi
  done
}

_aisw_help() {
  print -P -- "
%BAISwitch%b — switch API providers for Claude Code / Codex

  %Baisw%b                 pick interactively (fzf)
  %Baisw ls%b              list providers
  %Baisw <name>%b          switch to a provider
  %Baisw show%b [name]     show resolved config (keys masked)
  %Baisw test%b [name]     probe connectivity with a real request
  %Baisw which%b           active provider on each side
  %Baisw edit%b            edit the config file
  %Baisw reload%b          re-read config after editing

%BLaunchers%b
  %Bcc%b  [args]           run Claude Code on the active claude provider
  %Bcdx%b [args]           run Codex on the active codex provider
  one-shot:  %Bcc -P other%b / %Bcdx -P other%b   (does not change the active one)

%BAdding a provider%b — edit %F{cyan}$AISW_CONFIG%f:
    %F{242}[claude.foo]
    label = My provider
    base  = https://api.example.com/
    key   = sk-xxx%f
  Model is optional — it falls back to [default].
"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
aisw() {
  local cmd="${1:-pick}"; [[ $# -gt 0 ]] && shift
  case $cmd in
    pick)              _aisw_use "" ;;
    ls|list)           _aisw_ls "$@" ;;
    use|switch|sw)     _aisw_use "$@" ;;
    show|cat)          _aisw_show "$@" ;;
    test|ping)         _aisw_test "$@" ;;
    which|cur|current) _aisw_which ;;
    edit)              ${EDITOR:-vi} "$AISW_CONFIG"; _aisw_restore; _aisw_ok "reloaded" ;;
    reload)            _aisw_restore; _aisw_ok "reloaded $AISW_CONFIG" ;;
    config|path)       print -r -- "$AISW_CONFIG" ;;
    help|-h|--help)    _aisw_help ;;
    *)
      # Not a subcommand: treat as a provider name.
      _aisw_resolve "$cmd" >/dev/null 2>&1
      case $? in
        0) _aisw_use "$cmd" ;;
        2) _aisw_resolve "$cmd" >/dev/null; return 1 ;;  # re-run to print the hint
        *) _aisw_err "unknown command or provider: $cmd"; _aisw_help; return 1 ;;
      esac ;;
  esac
}

# ---------------------------------------------------------------------------
# launchers
# ---------------------------------------------------------------------------
_aisw_oneshot() {  # handle `-P <name>`; called inside a subshell
  local kind="$1"; shift
  _AISW_SHIFT=0
  if [[ "$1" == "-P" || "$1" == "--profile" ]]; then
    local sec=$(_aisw_resolve "$2") || { _aisw_err "no such provider: $2"; return 1 }
    [[ "$(_aisw_kind_of $sec)" == "$kind" ]] || { _aisw_err "$2 is not a $kind provider"; return 1 }
    _aisw_apply "$sec" >/dev/null || return 1
    _AISW_SHIFT=2
  fi
}

_aisw_set_proxy() {  # $1 = resolved proxy value; called in the launcher subshell
  case "$1" in
    ""|inherit) ;;                                    # leave the shell as-is
    none|off)   unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ;;
    *)          export http_proxy="$1" https_proxy="$1" \
                       HTTP_PROXY="$1" HTTPS_PROXY="$1" ;;
  esac
}

cc() {
  # Subshell: a one-shot -P never leaks into the calling shell.
  (
    _aisw_oneshot claude "$@" || exit 1
    shift $_AISW_SHIFT
    [[ -n $ANTHROPIC_BASE_URL ]] || { _aisw_err "no active claude provider — run: aisw use <name>"; exit 1 }
    _aisw_set_proxy "$AISW_CLAUDE_PROXY"
    # Env var wins, so you can override for one command without editing config.
    local args="${AISW_CLAUDE_ARGS-$(_aisw_get default claude_args)}"
    print -P -- "%F{242}[claude] ${AISW_CLAUDE_LABEL} · ${ANTHROPIC_MODEL}%f"
    command claude ${=args} "$@"
  )
}

cdx() {
  (
    _aisw_oneshot codex "$@" || exit 1
    shift $_AISW_SHIFT
    [[ -n $CODEX_BASE_URL && -n $AISW_CODEX_KEY ]] || {
      _aisw_err "no active codex provider — run: aisw use <name>"; exit 1 }
    _aisw_set_proxy "$AISW_CODEX_PROXY"

    # Everything via -c: never touches ~/.codex/auth.json or its config.toml provider.
    local -a conf=(
      -c "model_provider=aisw"
      -c "model_providers.aisw.name=\"${AISW_CODEX_LABEL:-aisw}\""
      -c "model_providers.aisw.base_url=\"$CODEX_BASE_URL\""
      -c "model_providers.aisw.wire_api=\"${CODEX_WIRE_API:-responses}\""
      -c "model_providers.aisw.env_key=\"AISW_CODEX_KEY\""
    )
    [[ -n $CODEX_MODEL            ]] && conf+=(-c "model=\"$CODEX_MODEL\"")
    [[ -n $CODEX_REVIEW_MODEL     ]] && conf+=(-c "review_model=\"$CODEX_REVIEW_MODEL\"")
    [[ -n $CODEX_REASONING_EFFORT ]] && conf+=(-c "model_reasoning_effort=\"$CODEX_REASONING_EFFORT\"")
    [[ -n $CODEX_EXTRA_CONF       ]] && conf+=(${(z)CODEX_EXTRA_CONF})

    local args="${AISW_CODEX_ARGS-$(_aisw_get default codex_args)}"
    print -P -- "%F{242}[codex] ${AISW_LABEL} · ${CODEX_MODEL} · $CODEX_BASE_URL%f"
    command codex $conf ${=args} "$@"
  )
}

# ---------------------------------------------------------------------------
# completion
# ---------------------------------------------------------------------------
_aisw_complete() {
  local -a subs names
  subs=(ls use show test which edit reload help)
  names=(${${(f)"$(_aisw_sections)"}#*.})
  if (( CURRENT == 2 )); then compadd -a subs; compadd -a names
  elif (( CURRENT == 3 )); then compadd -a names; fi
}
compdef _aisw_complete aisw 2>/dev/null

_aisw_restore
