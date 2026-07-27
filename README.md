# AISwitch

Switch API providers for **Claude Code** and **Codex** from zsh.

You have keys from several places — official, relays, a work gateway, a spare
account. AISwitch keeps them in one config file and lets you flip between them
per shell, or per invocation.

```console
$ aisw ls

CLAUDE
  ● work           work gateway
  ○ relay          some relay

CODEX
  ● relay-a        relay A
  ○ relay-b        relay B

$ aisw relay
✓ claude → relay  some relay

$ cc                      # Claude Code on the active provider
$ cdx -P relay-b          # Codex on relay-b, just this once
```

## How it works

Everything is environment variables — no state files rewritten, nothing to
undo, and no daemon.

- **Claude** — exports `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`.
- **Codex** — injects the provider through `-c model_providers.aisw.env_key=…`,
  so `~/.codex/auth.json` and the `config.toml` provider block are bypassed
  entirely. Switching never mutates Codex's own state.

Each side is tracked independently: your Claude provider and your Codex
provider are separate selections.

## Install

```sh
git clone https://github.com/Noietch/AISwitch.git
cd AISwitch && ./install.sh
```

Then edit `~/.aisw/config` with your keys and run `exec zsh`.

The installer copies `aisw.zsh` and a starter config into `~/.aisw`, adds the
source line to `~/.zshrc`, and warns about the `settings.json` conflict below.
Re-running it upgrades `aisw.zsh` and never touches your config.

`fzf` is optional — it powers the interactive picker. Without it, use
`aisw <name>` directly.

### One thing to check first

If `~/.claude/settings.json` has an `"env"` block containing `ANTHROPIC_*`
keys, **remove it**. Values there take precedence over the environment, so
switching would appear to work while Claude Code silently keeps using the old
provider. Move anything non-provider-specific into the `[env]` section of
`~/.aisw/config`. The installer flags this if it finds it.

## Config

```ini
[default]
claude_model = claude-opus-4-6
codex_model  = gpt-5.1-codex
codex_effort = high

# appended to every launch; empty by default
claude_args = --allow-dangerously-skip-permissions
codex_args  = --dangerously-bypass-approvals-and-sandbox

# proxy per side — most setups need this rather than per provider
claude_proxy = none                    # internal, no proxy
codex_proxy  = http://127.0.0.1:7890   # external

[claude.work]
label = work gateway
base  = https://gateway.example.com/v1/anthropic/
key   = xxxxxxxx

[codex.relay-a]
label = relay A
base  = https://relay-a.example.com
key   = sk-xxxxxxxx
```

Adding a provider is four lines. Model, args and proxy live in `[default]` so
providers only carry the endpoint and key — set any of them on a provider to
override.

`proxy` accepts a URL, `none` to clear the proxy for that provider, or nothing
at all to leave the shell's proxy untouched. Resolution goes: the provider's
own `proxy`, then `claude_proxy` / `codex_proxy`, then a shared `proxy`.

Anything in an `[env]` section is exported verbatim on every switch.

## Commands

| | |
|---|---|
| `aisw` | pick interactively (fzf) |
| `aisw ls` | list providers |
| `aisw <name>` | switch |
| `aisw show [name]` | resolved config, keys masked |
| `aisw test [name]` | probe with a real request |
| `aisw which` | active provider on each side |
| `aisw edit` / `aisw reload` | edit config / re-read it |
| `cc [args]` | Claude Code on the active provider |
| `cdx [args]` | Codex on the active provider |
| `cc -P <name>` | one-shot, doesn't change the active provider |

`aisw test` drives the real CLI rather than a hand-rolled `curl`, so it
exercises the same auth path and endpoint the tool actually uses — a bare
`curl` can report a failure the CLI doesn't hit, and vice versa.

`cc -P` / `cdx -P` run in a subshell, so a one-shot override never leaks into
the calling shell.

### Overriding for one command

`AISW_CLAUDE_ARGS` / `AISW_CODEX_ARGS` take precedence over `claude_args` /
`codex_args` in the config, so you can change flags for a single run:

```sh
AISW_CLAUDE_ARGS='' cc          # drop the configured flags just this once
```

### Shadowing the real commands

Reaching for `cc` instead of `claude` is a habit you have to keep. If you'd
rather the tool's own name did the right thing, turn on shadowing:

```ini
[default]
shadow_claude = 1
shadow_codex  = 1
```

Now `claude` and `codex` route through AISwitch — active provider, configured
flags, configured proxy — while `command claude` / `command codex` still reach
the unwrapped binaries. This is off by default, since shadowing a real command
name is the kind of thing you should opt into knowingly.

## Notes

Keys sit in plaintext in `~/.aisw/config` — `chmod 600` it. This is the same
exposure as the `auth.json` / `settings.json` files it replaces, not more, but
it's worth knowing.

Your selection persists across shells via `~/.aisw/current.{claude,codex}`.

zsh only.

## License

MIT
