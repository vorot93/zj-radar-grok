# zj-radar-grok

A Grok **plugin** that broadcasts agent status (working / waiting / done / error)
to the [zj-radar](https://github.com/marktoda/zj-radar) Zellij sidebar.

Adapted from upstream `zj-radar-claude` for Grok Build's camelCase hook envelope
and tool names. Install the Zellij sidebar first
([install guide](https://github.com/marktoda/zj-radar/blob/main/docs/install.md)),
then this producer.

## Install

```sh
grok plugin install vorot93/zj-radar-grok --trust
```

From a local checkout: `grok plugin install . --trust`. Then reload plugins
with `r` in the Plugins tab, or start a new session.

Do not also drop a copy in `~/.grok/plugins/` — that shadows the trusted
install.

## What it does

| Hook | Sidebar status |
|------|----------------|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop` | `running` |
| `Notification` (`permission_prompt` / `elicitation_dialog`) | `pending` |
| `Stop` (only `reason == end_turn`) | `done` (or `pending` if the final line is a question) |
| `StopFailure` | `error` |
| `SessionStart` (`matcher: clear`) | `idle` |
| `SessionEnd` | `idle` |

Each call runs `scripts/notify.sh`, which prefers `zj-radar notify generic
--source grok` when the CLI is on `PATH`, and otherwise falls back to a
`zellij pipe --name zj_radar.status.v1` broadcast (needs `jq` + `git`).
It is a **no-op outside Zellij**.

Wire `source` is `grok`. Upstream Kind has no Grok variant yet, so the rail
shows the neutral ⦿ mark (same as generic). Repo/branch still resolve from the
session cwd.

## Coexistence with zj-radar-claude

Grok’s Claude-compat layer also loads `zj-radar-claude` when it is enabled in
`~/.claude/settings.json`. The Claude `notify.sh` is guarded to no-op when
`GROK_SESSION_ID` / `GROK_HOOK_EVENT` is set, so only this producer broadcasts
during Grok sessions. Claude Code sessions are unchanged.

## Uninstall

```sh
grok plugin uninstall zj-radar-grok --confirm
```
