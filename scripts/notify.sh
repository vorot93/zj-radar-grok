#!/usr/bin/env bash
# zj-radar Grok plugin notifier.
#
# Registered by hooks/hooks.json; called as `notify.sh <status>` where <status>
# is running | pending | done | error | idle. Reads the Grok hook JSON on stdin
# (camelCase envelope), derives activity/task, then broadcasts a
# zj_radar.status.v1 message to the zj-radar Zellij sidebar.
#
# Adapted from plugins/zj-radar-claude/scripts/notify.sh:
#   - Grok stdin is camelCase (hookEventName, toolName, toolInput, …);
#     snake_case is also accepted for Claude/SDK compatibility.
#   - Grok tool names (run_terminal_command, search_replace, …) map to the
#     same activity strings as the Claude producer.
#   - Wire source is `grok` (renders as Kind::Other / ⦿ until upstream adds a
#     first-class Grok kind). Prefers `zj-radar notify generic` when the CLI
#     is on PATH; falls back to bash+jq pipe broadcast.
#
# Design contract (matches the sidebar plugin's pipe schema):
#   - BROADCAST by name (never --plugin).
#   - In-order and non-erroring: edges (done/pending/idle/error) sync;
#     running is fire-and-forget. Every failure path is a silent no-op.
#   - No-op outside Zellij, or on a non-terminal pane id.
set -euo pipefail

status="${1:-running}"
SOURCE="grok"

# Cap stdin at 8 MiB (parity with the Rust CLI's MAX_STDIN_BYTES).
input="$(head -c 8388608 2>/dev/null || true)"

# Field fetch: callers pass a jq expr with camelCase // snake_case // empty.
field() {
    jq -r "$1" <<<"$input" 2>/dev/null || true
}

command -v jq >/dev/null 2>&1 || {
    # Without jq we can still fire a bare generic notify when the CLI exists
    # and status is an edge (no payload parse needed).
    if command -v zj-radar >/dev/null 2>&1; then
        if [[ "$status" == "running" ]]; then
            ( zj-radar notify generic --status "$status" --source "$SOURCE" >/dev/null 2>&1 & )
        else
            zj-radar notify generic --status "$status" --source "$SOURCE" >/dev/null 2>&1 || true
        fi
    fi
    exit 0
}

cwd="$(field '.cwd // empty')"
cwd="${cwd:0:4096}"
[[ -n "$cwd" ]] || cwd="$PWD"

msg="$(field '.message // .lastAssistantMessage // .last_assistant_message // empty')"
task=""

contains_word() {
    local re="(^|[^a-z0-9])$2([^a-z0-9]|$)"
    [[ "$1" =~ $re ]]
}

# Normalize event name to Claude-style PascalCase for matching.
hook_event_raw="$(field '.hookEventName // .hook_event_name // empty')"
hook_event=""
case "$hook_event_raw" in
    UserPromptSubmit|user_prompt_submit) hook_event="UserPromptSubmit" ;;
    PreToolUse|pre_tool_use)             hook_event="PreToolUse" ;;
    PostToolUse|post_tool_use)           hook_event="PostToolUse" ;;
    SubagentStart|subagent_start)        hook_event="SubagentStart" ;;
    SubagentStop|subagent_stop|SubagentEnd|subagent_end) hook_event="SubagentStop" ;;
    Notification|notification)           hook_event="Notification" ;;
    Stop|stop)                           hook_event="Stop" ;;
    StopFailure|stop_failure)            hook_event="StopFailure" ;;
    SessionStart|session_start)          hook_event="SessionStart" ;;
    SessionEnd|session_end)              hook_event="SessionEnd" ;;
    *)                                   hook_event="$hook_event_raw" ;;
esac

# Session-end Stop is observe-only for gates; don't paint the rail green then
# immediately idle from SessionEnd. Only genuine turn completions → done.
if [[ "$status" == "done" ]]; then
    reason="$(field '.reason // empty')"
    if [[ -n "$reason" && "$reason" != "end_turn" ]]; then
        exit 0
    fi
fi

if [[ "$status" == "running" ]]; then
    if [[ "$hook_event" == "UserPromptSubmit" ]]; then
        prompt="$(field '.prompt // empty')"
        task="$(printf '%s\n' "$prompt" \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            | grep -m1 . || true)"
        case "$task" in "/"*|"<"*) task="" ;; esac
        t_norm="$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]' | sed -e 's/[.!?,]*$//' -e 's/[[:space:]]*$//')"
        case "$t_norm" in
            y|yes|yep|yeah|n|no|ok|okay|k|sure|go|"go ahead"|proceed|continue|"do it"|lgtm|"sounds good"|approved|thanks|ty|"thank you")
                task="" ;;
        esac
        task="${task:0:512}"
    fi

    if [[ "$hook_event" == "SubagentStart" ]]; then
        msg="delegating"
    fi

    if [[ "$hook_event" == "PreToolUse" || "$hook_event" == "PostToolUse" ]]; then
        tool_name="$(field '.toolName // .tool_name // empty')"
        tool_activity=""
        # Path fields: Grok uses target_file; Claude uses file_path.
        fp="$(field '.toolInput.target_file // .toolInput.file_path // .tool_input.file_path // .tool_input.target_file // empty')"
        case "$tool_name" in
            Edit|Write|MultiEdit|search_replace|write)
                [[ -n "$fp" ]] && tool_activity="editing ${fp##*/}"
                ;;
            NotebookEdit)
                nfp="$(field '.toolInput.notebook_path // .tool_input.notebook_path // empty')"
                [[ -n "$nfp" ]] && tool_activity="editing ${nfp##*/}"
                ;;
            Read|read_file)
                [[ -n "$fp" ]] && tool_activity="reading ${fp##*/}"
                ;;
            Grep|Glob|grep|list_dir)
                tool_activity="searching"
                ;;
            WebFetch|WebSearch|web_search|web_fetch|open_page|open_page_with_find)
                tool_activity="searching web"
                ;;
            Task|spawn_subagent)
                tool_activity="delegating"
                ;;
            TodoWrite|todo_write)
                tool_activity="planning"
                ;;
            Bash|run_terminal_command)
                cmd="$(field '.toolInput.command // .tool_input.command // empty')"
                cmd_lower="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
                if [[ -n "$(printf '%s' "$cmd" | tr -d '[:space:]')" ]]; then
                    if contains_word "$cmd_lower" "git push"; then
                        tool_activity="pushing"
                    elif contains_word "$cmd_lower" "git commit"; then
                        tool_activity="committing"
                    elif contains_word "$cmd_lower" "git pull" || contains_word "$cmd_lower" "git fetch"; then
                        tool_activity="syncing"
                    elif contains_word "$cmd_lower" "test"; then
                        tool_activity="running tests"
                    elif contains_word "$cmd_lower" "build" || contains_word "$cmd_lower" "compile"; then
                        tool_activity="building"
                    elif contains_word "$cmd_lower" "install"; then
                        tool_activity="installing"
                    else
                        read -r first_token _ <<<"$cmd"
                        first_base="${first_token##*/}"
                        [[ -n "$first_base" ]] && tool_activity="running $first_base"
                    fi
                fi
                ;;
            use_tool)
                # MCP via use_tool — try qualified name if present.
                qname="$(field '.toolInput.tool_name // .tool_input.tool_name // empty')"
                if [[ -n "$qname" ]]; then
                    tool_activity="using ${qname##*__}"
                fi
                ;;
            *)
                # MCP qualified names: server__tool
                if [[ "$tool_name" == *__* ]]; then
                    tool_activity="using ${tool_name##*__}"
                fi
                ;;
        esac
        [[ -n "$tool_activity" ]] && msg="$tool_activity"
    fi
    [[ -z "$msg" ]] && msg="working"
fi

if [[ "$status" == "pending" ]]; then
    m_trim="$(printf '%s' "$msg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$m_trim" in
        ""|"Claude needs attention"|"Claude Code needs your attention"|"Grok needs attention")
            # Still broadcast pending when the hook matcher already selected a
            # real permission/elicitation event — only drop empty/generic text
            # that would paint a blank "needs you" without content.
            if [[ -z "$m_trim" ]]; then
                msg="awaiting input"
            fi
            ;;
    esac
fi

# A turn that ends by asking the user something is blocked on input, not done.
if [[ "$status" == "done" && -n "$msg" ]]; then
    last_line="$(printf '%s\n' "$msg" | awk 'NF{l=$0} END{print l}' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$last_line" in
        *"?"|*"？")
            status="pending"
            msg="$last_line"
            ;;
    esac
fi

[[ "$status" == "idle" ]] && msg=""

msg="${msg:0:512}"

# Prefer the native CLI (generic agent: explicit status/msg/task/source).
if command -v zj-radar >/dev/null 2>&1; then
    args=(notify generic --status "$status" --source "$SOURCE")
    [[ -n "$msg" ]] && args+=(--msg "$msg")
    [[ -n "$task" ]] && args+=(--task "$task")
    # generic resolves repo/branch from CWD; match the hook's cwd.
    if [[ "$status" == "running" ]]; then
        ( cd "$cwd" && zj-radar "${args[@]}" >/dev/null 2>&1 & )
    else
        ( cd "$cwd" && zj-radar "${args[@]}" >/dev/null 2>&1 ) || true
    fi
    exit 0
fi

# bash + zellij pipe fallback (no CLI)
[[ -n "${ZELLIJ:-}" && -n "${ZELLIJ_PANE_ID:-}" ]] || exit 0
pane_num="${ZELLIJ_PANE_ID#terminal_}"
[[ "$pane_num" =~ ^[0-9]+$ ]] || exit 0

common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
common="${common%/}"
[[ "$common" == /* && "$common" != *$'\n'* ]] || common=""
case "$common" in
    */.git) repo="$(basename "$(dirname "$common")")" ;;
    *.git)  repo="$(basename "${common%.git}")" ;;
    ?*)     repo="$(basename "$common")" ;;
    *)      repo="$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")")" ;;
esac
branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"

payload="$(jq -nc \
    --argjson id "$pane_num" \
    --arg status "$status" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg msg "$msg" \
    --arg task "$task" \
    --arg source "$SOURCE" \
    '{v: 1, source: $source, pane: {type: "terminal", id: $id},
      status: $status, repo: $repo, branch: $branch, msg: $msg, task: $task}')"

if [[ "${ZJ_RADAR_DEBUG:-}" == "1" ]]; then
    printf 'zj-radar payload: %s\n' "$payload" >&2
    exit 0
fi

pipe_deadline="${ZJ_RADAR_PIPE_TIMEOUT:-5}"
[[ "$pipe_deadline" =~ ^[0-9]+$ ]] || pipe_deadline=5
zellij pipe --name zj_radar.status.v1 -- "$payload" >/dev/null 2>&1 &
pipe_pid=$!
( sleep "$pipe_deadline"; kill "$pipe_pid" ) >/dev/null 2>&1 &
watchdog=$!
wait "$pipe_pid" 2>/dev/null || true
kill "$watchdog" 2>/dev/null || true
