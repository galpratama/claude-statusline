#!/bin/bash

# Claude Code Statusline Script
# Performance optimizations:
# - Configuration-based segment toggling
# - Caching system for expensive operations (git, servers, language detection)
# - Centralized color management
# - Git operations use --no-optional-locks for speed
# - Minimal file system operations

# Note: Removed set -o pipefail as it causes non-zero exit codes from grep/git

# ============================================================================
# CONSTANTS
# ============================================================================

# Every fork costs ~25ms on Windows (Git Bash) vs ~1ms on macOS, so the render path avoids
# $(...), pipes and external tools: helpers return through globals (REPLY, GRAD, CAP).
readonly CONFIG_FILE="${HOME}/.claude/statusline-config.json"
_script_dir=${BASH_SOURCE[0]%/*}
[ "$_script_dir" = "${BASH_SOURCE[0]}" ] && _script_dir=.
[[ "$_script_dir" == /* ]] || _script_dir="$PWD/$_script_dir"
readonly STATUSLINE_CONFIG_FILE="$_script_dir/statusline-config.json"
# Per-session state and caches live in a private per-user dir, not shared /tmp
# (predictable /tmp names could be pre-created as symlinks by another local user)
readonly STATE_DIR="${HOME}/.cache/claude-statusline/state"
# One clock read per render; STATUSLINE_NOW freezes time for the snapshot tests
NOW=${STATUSLINE_NOW:-${EPOCHSECONDS:-$(date +%s)}}

# shellcheck disable=SC2174  # only STATE_DIR itself needs to be private
[ -d "$STATE_DIR" ] || mkdir -p -m 700 "$STATE_DIR" 2>/dev/null

# Whole file into REPLY (trailing newline stripped, like $(cat)); fails when unreadable
slurp() {
    REPLY=""
    [ -r "$1" ] || return 1
    IFS= read -r -d '' REPLY < "$1"
    REPLY=${REPLY%$'\n'}
    return 0
}

# Succeeds with the cached value in REPLY when file $1 ("epoch\nvalue", see stamp_cache)
# is younger than $2 seconds
fresh_cache() {
    local at=""
    REPLY=""
    [ -f "$1" ] && { read -r at; IFS= read -r REPLY; } < "$1" &&
        [[ "$at" =~ ^[0-9]+$ ]] && [ $((NOW - at)) -lt "$2" ]
}

stamp_cache() {
    printf '%s\n%s\n' "$NOW" "$2" > "$1"
}

# Strings to a short stable cache key (replaces `cksum` in file names)
cache_key() {
    REPLY=${1//[^A-Za-z0-9._-]/_}
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Sets REPLY to the number in k/M notation with up to two decimals
format_k() {
    local num=$1

    # Handle empty or non-numeric values
    if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
        REPLY=0
        return
    fi

    local div suffix h frac
    if [ "$num" -ge 1000000 ]; then div=1000000 suffix=M
    elif [ "$num" -ge 1000 ]; then div=1000 suffix=k
    else REPLY=$num; return; fi
    h=$(( (num * 100 + div / 2) / div ))
    printf -v frac '%02d' $((h % 100))
    frac=${frac%0}; frac=${frac%0}
    REPLY="$((h / 100))${frac:+.$frac}${suffix}"
}

# --- Cross-platform date/stat helpers (BSD/macOS vs GNU/Linux) ---
case "$OSTYPE" in
    darwin*) _OS_FLAVOR="bsd" ;;
    *)       _OS_FLAVOR="gnu" ;;
esac

# Native Windows jq.exe (Git Bash) writes CRLF; --binary keeps "\r" out of parsed values.
case "$OSTYPE" in
    msys*|cygwin*) jq() { command jq --binary "$@"; } ;;
esac

# bash 4.2+ formats dates without forking `date`
_HAS_PRINTF_T=""
printf -v _probe '%(%Y)T' 0 2>/dev/null && [ "$_probe" != "%(%Y)T" ] && _HAS_PRINTF_T=1

# Parse a date/datetime string to epoch seconds
# usage: _date_to_epoch "<bsd_input_format>" "<value>"
_date_to_epoch() {
    if [ "$_OS_FLAVOR" = "bsd" ]; then
        date -j -f "$1" "$2" +%s 2>/dev/null
    else
        date -d "$2" +%s 2>/dev/null
    fi
}

# Format an epoch to a given strftime spec
# usage: _epoch_to_fmt "<epoch>" "+%m"
_epoch_to_fmt() {
    if [ "$_OS_FLAVOR" = "bsd" ]; then
        date -j -f "%s" "$1" "$2" 2>/dev/null
    else
        date -d "@$1" "$2" 2>/dev/null
    fi
}

# Same as _epoch_to_fmt into REPLY; forks only on bash < 4.2 (macOS /bin/bash)
epoch_fmt() {
    if [ -n "$_HAS_PRINTF_T" ]; then
        printf -v REPLY "%(${2#+})T" "$1"
    else
        REPLY=$(_epoch_to_fmt "$1" "$2")
    fi
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

load_config() {
    local config_values
    # One jq call for all settings; order must match the read list below
    if [ -f "$CONFIG_FILE" ] && config_values=$(jq -r '
        def v(p; d): (p | if . == null then d else tostring end);
        v(.segments.ai.show_provider; "true"), v(.segments.ai.show_model; "true"),
        v(.segments.ai.show_cost; "true"), v(.segments.ai.show_cache_efficiency; "true"),
        v(.segments.ai.show_rate_limit; "true"), v(.segments.ai.show_message_count; "true"),
        v(.segments.ai.show_mcp_servers; "true"), v(.segments.ai.show_tools_count; "true"),
        v(.segments.git.enabled; "true"), v(.segments.git.show_last_commit; "true"),
        v(.segments.git.show_commits_today; "true"),
        v(.segments.dev.enabled; "true"), v(.segments.dev.show_language; "true"),
        v(.segments.dev.show_package_manager; "true"), v(.segments.dev.show_running_servers; "true"),
        v(.features.lint_checking; "false"), v(.features.server_detection; "true"),
        v(.segments.ai.show_rules; "true"), v(.segments.ai.show_hooks; "true"),
        v(.segments.ai.show_claude_md; "true"), v(.segments.tools.enabled; "true"),
        v(.segments.agents.enabled; "true"), v(.segments.todos.enabled; "true"),
        v(.features.notifications; "true"), v(.segments.dev.show_docker; "true"), v(.segments.git.show_stash; "true"),
        v(.display.theme; "default"), v(.features.memory_pressure; "true"), v(.display.currency; "usd")
    ' "$CONFIG_FILE" 2>/dev/null); then
        {
            read -r SHOW_PROVIDER; read -r SHOW_MODEL
            read -r SHOW_COST; read -r SHOW_CACHE_EFFICIENCY
            read -r SHOW_RATE_LIMIT; read -r SHOW_MESSAGE_COUNT
            read -r SHOW_MCP_SERVERS; read -r SHOW_TOOLS
            read -r SHOW_GIT; read -r SHOW_LAST_COMMIT
            read -r SHOW_COMMITS_TODAY
            read -r SHOW_DEV; read -r SHOW_LANGUAGE
            read -r SHOW_PACKAGE_MANAGER; read -r SHOW_SERVERS
            read -r CLAUDE_STATUSLINE_LINT; read -r CLAUDE_STATUSLINE_SERVERS
            read -r SHOW_RULES; read -r SHOW_HOOKS
            read -r SHOW_CLAUDE_MD; read -r SHOW_RUNNING_TOOLS
            read -r SHOW_AGENTS; read -r SHOW_TODOS
            read -r NOTIFICATIONS; read -r SHOW_DOCKER; read -r SHOW_STASH
            read -r DISPLAY_THEME; read -r SHOW_MEM_PRESSURE; read -r CURRENCY
        } <<< "$config_values"
    else
        # Defaults when no config file
        SHOW_PROVIDER="true"
        SHOW_MODEL="true"
        SHOW_COST="true"
        SHOW_CACHE_EFFICIENCY="true"
        SHOW_RATE_LIMIT="true"
        SHOW_MESSAGE_COUNT="true"
        SHOW_MCP_SERVERS="true"
        SHOW_TOOLS="true"
        SHOW_GIT="true"
        SHOW_LAST_COMMIT="true"
        SHOW_COMMITS_TODAY="true"
        SHOW_DEV="true"
        SHOW_LANGUAGE="true"
        SHOW_PACKAGE_MANAGER="true"
        SHOW_SERVERS="true"
        CLAUDE_STATUSLINE_LINT="${CLAUDE_STATUSLINE_LINT:-false}"
        CLAUDE_STATUSLINE_SERVERS="${CLAUDE_STATUSLINE_SERVERS:-true}"

        # New feature toggles defaults
        SHOW_RULES="true"
        SHOW_HOOKS="true"
        SHOW_CLAUDE_MD="true"
        SHOW_RUNNING_TOOLS="true"
        SHOW_AGENTS="true"
        SHOW_TODOS="true"
        NOTIFICATIONS="true"
        SHOW_DOCKER="true"
        SHOW_STASH="true"
        SHOW_MEM_PRESSURE="true"
        CURRENCY="usd"
    fi

    # String booleans to 0/1
    [ "$CLAUDE_STATUSLINE_LINT" = "true" ] && CLAUDE_STATUSLINE_LINT=1 || CLAUDE_STATUSLINE_LINT=0
    [ "$CLAUDE_STATUSLINE_SERVERS" = "true" ] && CLAUDE_STATUSLINE_SERVERS=1 || CLAUDE_STATUSLINE_SERVERS=0
}

load_config

# ============================================================================
# COLOR DEFINITIONS
# ============================================================================

# 24-bit gradients when the terminal advertises them; STATUSLINE_TRUECOLOR=0 forces 16 colors
TRUECOLOR=0
[[ "$COLORTERM" =~ ^(truecolor|24bit)$ ]] && [ "${STATUSLINE_TRUECOLOR:-1}" != 0 ] && TRUECOLOR=1

# Theme palettes (truecolor only), R;G;B in order: cyan blue purple green yellow red gray.
# "default" keeps the terminal's own 16-color palette.
THEME_PALETTE=""
if [ "$TRUECOLOR" = 1 ]; then
    case "$DISPLAY_THEME" in
        catppuccin) THEME_PALETTE="137;220;235 137;180;250 203;166;247 166;227;161 249;226;175 243;139;168 127;132;156" ;;
        tokyonight) THEME_PALETTE="125;207;255 122;162;247 187;154;247 158;206;106 224;175;104 247;118;142 86;95;137" ;;
        dracula)    THEME_PALETTE="139;233;253 130;170;255 189;147;249 80;250;123 241;250;140 255;85;85 98;114;164" ;;
        nord)       THEME_PALETTE="136;192;208 129;161;193 180;142;173 163;190;140 235;203;139 191;97;106 110;120;140" ;;
        rosepine)   THEME_PALETTE="156;207;216 49;116;143 196;167;231 156;207;216 246;193;119 235;111;146 110;106;134" ;;
    esac
fi
if [ -n "$THEME_PALETTE" ]; then
    read -r _cy _bl _pu _gr _ye _re _gy <<< "$THEME_PALETTE"
    readonly C_CYAN="\033[38;2;${_cy}m" C_BLUE="\033[38;2;${_bl}m" C_PURPLE="\033[38;2;${_pu}m"
    readonly C_GREEN="\033[38;2;${_gr}m" C_YELLOW="\033[38;2;${_ye}m" C_RED="\033[38;2;${_re}m"
    readonly C_GRAY="\033[38;2;${_gy}m"
    # Gradient stops follow the theme's green/yellow/red
    GRAD_LO=${_gr//;/ } GRAD_MID=${_ye//;/ } GRAD_HI=${_re//;/ }
else
    readonly C_CYAN="\033[36m" C_BLUE="\033[34m" C_PURPLE="\033[35m"
    readonly C_GREEN="\033[32m" C_YELLOW="\033[33m" C_RED="\033[31m" C_GRAY="\033[90m"
    GRAD_LO="80 200 120" GRAD_MID="235 195 70" GRAD_HI="240 80 80"
fi
read -r LO_R LO_G LO_B <<< "$GRAD_LO"
read -r MID_R MID_G MID_B <<< "$GRAD_MID"
read -r HI_R HI_G HI_B <<< "$GRAD_HI"
readonly C_RESET="\033[0m"
readonly C_ALERT="\033[1m${C_RED}"
readonly C_WARN="\033[1m${C_YELLOW}"

# ============================================================================
# MODEL FORMATTING
# ============================================================================

# Sets CAP to $1 with its first letter uppercased (bash 3.2 has no ${var^})
cap() {
    local first=${1:0:1} lower=abcdefghijklmnopqrstuvwxyz upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ before
    if [ -n "$first" ]; then
        before=${lower%%"$first"*}
        [ ${#before} -lt 26 ] && first=${upper:${#before}:1}
    fi
    CAP="${first}${1:1}"
}

format_model_name() {
    local name="$1"

    # Check for :free suffix before stripping
    local is_free=false
    if [[ "$name" == *":free" ]]; then
        is_free=true
    fi

    # Strip provider prefix and :free/:exacto suffixes first
    local clean_name="$name"
    if [[ "$clean_name" =~ ^[^/]+/(.+)$ ]]; then
        clean_name="${BASH_REMATCH[1]}"
    fi
    clean_name="${clean_name%:free}"
    clean_name="${clean_name%:exacto}"
    # "Opus 5.5 (1M context)" -> "Opus 5.5 1M"
    if [[ "$clean_name" =~ ^(.*)\ \(([0-9]+[KkMm])\ context\)$ ]]; then
        clean_name="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    fi

    # Handle Kiro AWS proxy models
    if [[ "$clean_name" =~ kiro-claude-(opus|sonnet|haiku)-([0-9])-([0-9])(-agentic)? ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        local mode="${BASH_REMATCH[4]}"
        cap "$tier"; tier=$CAP
        if [ -n "$mode" ]; then
            echo "${tier} ${major}.${minor} Agentic"
        else
            echo "${tier} ${major}.${minor}"
        fi

    # Handle Antigravity/Gemini proxy models for Claude
    elif [[ "$clean_name" =~ gemini-claude-(opus|sonnet|haiku)-([0-9])-([0-9])-(thinking|extended) ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        local mode="${BASH_REMATCH[4]}"
        cap "$tier"; tier=$CAP
        if [ "$mode" = "thinking" ]; then
            mode="◉"
        else
            cap "$mode"; mode=$CAP
        fi
        echo "${tier} ${major}.${minor} ${mode}"

    # Handle Claude 3.x models with version dates (e.g., claude-3-5-sonnet-20241022)
    elif [[ "$clean_name" =~ claude-([0-9])-([0-9])-(opus|sonnet|haiku)-[0-9]{8} ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local tier="${BASH_REMATCH[3]}"
        cap "$tier"; tier=$CAP
        echo "${tier} ${major}.${minor}"

    # Handle Claude model names with suffixes (e.g., claude-opus-4-6-thinking)
    elif [[ "$clean_name" =~ claude-(opus|sonnet|haiku)-([0-9])-([0-9])-(thinking|extended) ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        cap "$tier"; tier=$CAP
        echo "${tier} ${major}.${minor}"

    # Handle standard Claude model names with version dates
    elif [[ "$clean_name" =~ claude-(opus|sonnet|haiku)-([0-9])-([0-9])-[0-9]{8} ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        cap "$tier"; tier=$CAP
        echo "${tier} ${major}.${minor}"

    # Handle standard Claude model names
    elif [[ "$clean_name" =~ claude-(opus|sonnet|haiku)-([0-9])\.?([0-9])?-?[0-9]* ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        cap "$tier"; tier=$CAP
        if [ "$major" = "4" ] && [ -z "$minor" ]; then
            echo "${tier} 4.5"
        elif [ -n "$minor" ]; then
            echo "${tier} ${major}.${minor}"
        else
            echo "${tier} ${major}"
        fi

    # Handle Claude display names
    elif [[ "$clean_name" =~ ^Claude\ (Opus|Sonnet|Haiku)\ ([0-9]\.?[0-9]?) ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"

    # Handle simple format like "Sonnet 4"
    elif [[ "$clean_name" =~ ^(Opus|Sonnet|Haiku)\ 4$ ]]; then
        echo "${BASH_REMATCH[1]} 4.5"

    # Handle OpenAI o4 family (must come before GPT-5)
    elif [[ "$clean_name" =~ ^o4(-mini|-preview)?$ ]]; then
        local variant="${BASH_REMATCH[1]}"
        local display="o4"
        if [ "$variant" = "-mini" ]; then
            display+=" Mini"
        elif [ "$variant" = "-preview" ]; then
            display+=" Preview"
        fi
        echo "$display"

    # Handle OpenAI o3 family
    elif [[ "$clean_name" =~ ^o3(-mini)?$ ]]; then
        local variant="${BASH_REMATCH[1]}"
        [ "$variant" = "-mini" ] && echo "o3 Mini" || echo "o3"

    # Handle OpenAI GPT-5 family
    elif [[ "$clean_name" =~ gpt-5\.([0-9])(-codex)?(-mini|-max|-nano)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        local codex="${BASH_REMATCH[2]}"
        local variant="${BASH_REMATCH[3]}"
        local display="GPT-5.${minor}"
        [ -n "$codex" ] && display+=" Codex"
        if [ "$variant" = "-mini" ]; then
            display+=" Mini"
        elif [ "$variant" = "-max" ]; then
            display+=" Max"
        elif [ "$variant" = "-nano" ]; then
            display+=" Nano"
        fi
        echo "$display"
    elif [[ "$clean_name" =~ gpt-5(-codex)?(-mini|-nano)? ]]; then
        local codex="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        local display="GPT-5"
        [ -n "$codex" ] && display+=" Codex"
        [ "$variant" = "-mini" ] && display+=" Mini"
        [ "$variant" = "-nano" ] && display+=" Nano"
        echo "$display"

    # Handle OpenAI GPT-4 family with various suffixes
    elif [[ "$clean_name" =~ ^gpt-4o(-mini|-2024-[0-9]{2}-[0-9]{2})?$ ]]; then
        local suffix="${BASH_REMATCH[1]}"
        [ "$suffix" = "-mini" ] && echo "GPT-4o Mini" || echo "GPT-4o"
    elif [[ "$clean_name" =~ ^gpt-4(-turbo|-vision|-32k)?$ ]]; then
        local variant="${BASH_REMATCH[1]}"
        local display="GPT-4"
        if [ "$variant" = "-turbo" ]; then
            display+=" Turbo"
        elif [ "$variant" = "-vision" ]; then
            display+=" Vision"
        elif [ "$variant" = "-32k" ]; then
            display+=" 32K"
        fi
        echo "$display"

    # Handle xAI Grok family
    elif [[ "$clean_name" =~ ^grok-([0-9])(-mini|-vision)?(-thinking)?$ ]]; then
        local version="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        local thinking="${BASH_REMATCH[3]}"
        local display="Grok ${version}"
        if [ "$variant" = "-mini" ]; then
            display+=" Mini"
        elif [ "$variant" = "-vision" ]; then
            display+=" Vision"
        fi
        [ -n "$thinking" ] && display+=" 💡"
        echo "$display"

    # Handle Gemini 3.x models
    elif [[ "$clean_name" =~ gemini-3-(pro|flash)(-image)?-preview ]]; then
        local tier="${BASH_REMATCH[1]}"
        local image="${BASH_REMATCH[2]}"
        cap "$tier"; tier=$CAP
        if [ -n "$image" ]; then
            echo "Gemini 3 ${tier} Image"
        else
            echo "Gemini 3 ${tier}"
        fi

    # Handle Gemini 2.x computer-use without tier (e.g., gemini-2.5-computer-use-preview-10-2025)
    elif [[ "$clean_name" =~ gemini-2\.([0-9])-computer-use-preview(-[0-9]+-[0-9]+)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        echo "Gemini 2.${minor} Computer"

    # Handle Gemini 2.x models with computer-use mode and tier (with or without date suffix)
    elif [[ "$clean_name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)?-computer-use-preview(-[0-9]+-[0-9]+)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        cap "$tier"; tier=$CAP
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        display+=" Computer"
        echo "$display"
    elif [[ "$clean_name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)?-preview ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        cap "$tier"; tier=$CAP
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        echo "$display"

    # Handle standard Gemini 2.x models
    elif [[ "$clean_name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        cap "$tier"; tier=$CAP
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        echo "$display"

    # Handle Qwen QwQ models (thinking models)
    elif [[ "$clean_name" =~ ^qwq-([0-9]+)b(-preview)?$ ]]; then
        local size="${BASH_REMATCH[1]}"
        local preview="${BASH_REMATCH[2]}"
        local display="QwQ ${size}B"
        [ -n "$preview" ] && display+=" Preview"
        echo "$display"

    # Handle Qwen3 models with thinking/instruct modes
    elif [[ "$clean_name" =~ qwen3-([0-9]+)b-a22b-(thinking|instruct)(-[0-9]+)? ]]; then
        local size="${BASH_REMATCH[1]}"
        local mode="${BASH_REMATCH[2]}"
        cap "$mode"; mode=$CAP
        echo "Qwen3 ${size}B ${mode}"

    # Handle Qwen3 VL Plus specifically (must come before generic pattern)
    elif [[ "$clean_name" =~ qwen3-vl-plus ]]; then
        echo "Qwen3 VL Plus"

    # Handle Qwen3 specialized variants
    elif [[ "$clean_name" =~ qwen3-(coder|max)-(flash|plus|preview) ]]; then
        local type="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        cap "$type"; type=$CAP
        cap "$variant"; variant=$CAP
        echo "Qwen3 ${type} ${variant}"

    # Handle Qwen3 simple variants (max only, since vl-plus handled above)
    elif [[ "$clean_name" =~ qwen3-max ]]; then
        echo "Qwen3 Max"

    # Handle Qwen3 Coder variants (new patterns for Alibaba Cloud)
    elif [[ "$clean_name" =~ qwen3-coder-next ]]; then
        echo "Qwen3 Coder Next"
    elif [[ "$clean_name" =~ qwen3-coder-plus ]]; then
        echo "Qwen3 Coder Plus"
    elif [[ "$clean_name" =~ qwen3-coder ]]; then
        echo "Qwen3 Coder"

    # Handle Qwen3 Max with date suffix (e.g., qwen3-max-2026-01-23)
    elif [[ "$clean_name" =~ qwen3-max-[0-9]{8} ]]; then
        echo "Qwen3 Max"

    # Handle Qwen3.5 variants (e.g., qwen3.5-plus)
    elif [[ "$clean_name" =~ qwen([0-9]+\.[0-9]+)-plus ]]; then
        echo "Qwen ${BASH_REMATCH[1]} Plus"
    elif [[ "$clean_name" =~ qwen([0-9]+)-plus ]]; then
        echo "Qwen${BASH_REMATCH[1]} Plus"

    # Handle Qwen3 size-based models
    elif [[ "$clean_name" =~ qwen3-([0-9]+)b ]]; then
        echo "Qwen3 ${BASH_REMATCH[1]}B"

    # Handle older Qwen models
    elif [[ "$clean_name" =~ qwen([0-9])-(next-)?([0-9]+)b ]]; then
        local version="${BASH_REMATCH[1]}"
        local next="${BASH_REMATCH[2]}"
        local size="${BASH_REMATCH[3]}"
        if [ -n "$next" ]; then
            echo "Qwen${version} Next ${size}B"
        else
            echo "Qwen${version} ${size}B"
        fi
    elif [[ "$clean_name" =~ alibaba-qwen([0-9])-(coder-)?([0-9]+)b ]]; then
        local version="${BASH_REMATCH[1]}"
        local coder="${BASH_REMATCH[2]}"
        local size="${BASH_REMATCH[3]}"
        if [ -n "$coder" ]; then
            echo "Qwen${version} Coder ${size}B"
        else
            echo "Qwen${version} ${size}B"
        fi

    # Handle Kimi/Moonshot K2 models
    elif [[ "$clean_name" =~ kimi-k([0-9])\.([0-9])-(thinking|instruct)(-[0-9]+)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local mode="${BASH_REMATCH[3]}"
        cap "$mode"; mode=$CAP
        echo "Kimi K${version}.${minor} ${mode}"
    elif [[ "$clean_name" =~ kimi-k([0-9])\.([0-9]) ]]; then
        echo "Kimi K${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$clean_name" =~ kimi-k2-(thinking|instruct)(-[0-9]+)? ]]; then
        local mode="${BASH_REMATCH[1]}"
        cap "$mode"; mode=$CAP
        echo "Kimi K2 ${mode}"
    elif [[ "$clean_name" =~ kimi-k2 ]]; then
        echo "Kimi K2"
    elif [[ "$clean_name" =~ kimi-k([0-9])-(thinking|instruct)(-[0-9]+)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local mode="${BASH_REMATCH[2]}"
        cap "$mode"; mode=$CAP
        echo "Kimi K${version} ${mode}"

    # Handle DeepSeek V3.x models
    elif [[ "$clean_name" =~ deepseek-v([0-9])\.([0-9])-(chat|reasoner) ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local mode="${BASH_REMATCH[3]}"
        cap "$mode"; mode=$CAP
        echo "DeepSeek V${major}.${minor} ${mode}"

    # Handle DeepSeek R1 and distill models
    elif [[ "$clean_name" =~ deepseek-r([0-9])(-distill-llama-([0-9]+)b)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local distill="${BASH_REMATCH[2]}"
        local size="${BASH_REMATCH[3]}"
        if [ -n "$distill" ]; then
            echo "DeepSeek R${version} Distill ${size}B"
        else
            echo "DeepSeek R${version}"
        fi

    # Handle DeepSeek versioned models
    elif [[ "$clean_name" =~ deepseek-v([0-9])\.([0-9])-(terminus)? ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local variant="${BASH_REMATCH[3]}"
        if [ -n "$variant" ]; then
            echo "DeepSeek V${major}.${minor} Terminus"
        else
            echo "DeepSeek V${major}.${minor}"
        fi
    elif [[ "$clean_name" =~ deepseek-v([0-9])\.([0-9]) ]]; then
        echo "DeepSeek V${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$clean_name" =~ deepseek-v([0-9])$ ]]; then
        echo "DeepSeek V${BASH_REMATCH[1]}"

    # Handle GLM models
    elif [[ "$clean_name" =~ glm-([0-9])\.([0-9]) ]]; then
        echo "GLM ${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$clean_name" =~ glm-([0-9])\.([0-9])-air ]]; then
        echo "GLM ${BASH_REMATCH[1]}.${BASH_REMATCH[2]} Air"
    elif [[ "$clean_name" =~ glm-5 ]]; then
        echo "GLM 5"
    elif [[ "$clean_name" =~ glm-4\.7 ]]; then
        echo "GLM 4.7"

    # Handle MiniMax models
    elif [[ "$clean_name" =~ minimax-m([0-9])\.([0-9]) ]]; then
        echo "MiniMax M${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$clean_name" =~ minimax-m([0-9]) ]]; then
        echo "MiniMax M${BASH_REMATCH[1]}"

    # Handle Mistral models
    elif [[ "$clean_name" =~ ^mistral-nemotron$ ]]; then
        echo "Mistral Nemotron"
    elif [[ "$clean_name" =~ ^(devstral|codestral)-([0-9]+)$ ]]; then
        local type="${BASH_REMATCH[1]}"
        local version="${BASH_REMATCH[2]}"
        cap "$type"; type=$CAP
        echo "${type} ${version}"
    elif [[ "$clean_name" =~ ^mistral-(small|medium|large)(-latest|-[0-9]{4}-[0-9]{2})?$ ]]; then
        local size="${BASH_REMATCH[1]}"
        cap "$size"; size=$CAP
        echo "Mistral ${size}"
    elif [[ "$clean_name" =~ ^mistral-large-([0-9])-.* ]]; then
        echo "Mistral Large ${BASH_REMATCH[1]}"

    # Handle Llama 4.x models
    elif [[ "$clean_name" =~ ^llama-?4\.?([0-9])?-([0-9]+)b-(instruct|base)(-preview)?$ ]]; then
        local minor="${BASH_REMATCH[1]}"
        local size="${BASH_REMATCH[2]}"
        local type="${BASH_REMATCH[3]}"
        local preview="${BASH_REMATCH[4]}"
        cap "$type"; type=$CAP
        local display="Llama 4"
        [ -n "$minor" ] && display+=".${minor}"
        display+=" ${size}B ${type}"
        [ -n "$preview" ] && display+=" Preview"
        echo "$display"

    # Handle Llama models (3.x and older)
    elif [[ "$clean_name" =~ llama([0-9])\.?([0-9])?-([0-9]+)b-(instruct|base) ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local size="${BASH_REMATCH[3]}"
        local type="${BASH_REMATCH[4]}"
        cap "$type"; type=$CAP
        if [ -n "$minor" ]; then
            echo "Llama ${major}.${minor} ${size}B ${type}"
        else
            echo "Llama ${major} ${size}B ${type}"
        fi

    # Handle OpenAI OSS variants
    elif [[ "$clean_name" =~ gpt-oss-([0-9]+)b-(medium|large)? ]]; then
        local size="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        if [ -n "$variant" ]; then
            cap "$variant"; variant=$CAP
            echo "GPT OSS ${size}B ${variant}"
        else
            echo "GPT OSS ${size}B"
        fi
    elif [[ "$clean_name" =~ gpt-oss-([0-9]+)b ]]; then
        echo "GPT OSS ${BASH_REMATCH[1]}B"

    # Handle T-Stars models
    elif [[ "$clean_name" =~ tstars([0-9])\.([0-9]) ]]; then
        echo "T-Stars ${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"

    # Handle Kwai/Kwaipilot KAT models
    elif [[ "$clean_name" =~ kat-coder-pro ]]; then
        echo "KAT Coder Pro"
    elif [[ "$clean_name" =~ kat-coder ]]; then
        echo "KAT Coder"

    # Handle ByteDance Seed models
    elif [[ "$clean_name" =~ seed-([0-9]+\.[0-9]+) ]]; then
        echo "Seed ${BASH_REMATCH[1]}"
    elif [[ "$clean_name" =~ ui-tars ]]; then
        echo "UI-TARS"

    # Handle AllenAI Olmo models
    elif [[ "$clean_name" =~ olmo-([0-9])-([0-9]+)b ]]; then
        echo "Olmo ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}B"

    # Handle Xiaomi MiMo models
    elif [[ "$clean_name" =~ mimo(-[0-9]+b)? ]]; then
        local size="${BASH_REMATCH[1]}"
        if [ -n "$size" ]; then
            echo "MiMo ${size#-}"
        else
            echo "MiMo"
        fi

    # Handle NVIDIA Nemotron models
    elif [[ "$clean_name" =~ nemotron-([0-9]+)-([0-9]+)b ]]; then
        echo "Nemotron ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}B"
    elif [[ "$clean_name" =~ nemotron-nano ]]; then
        echo "Nemotron Nano"

    # Handle Relace models
    elif [[ "$clean_name" =~ relace-search ]]; then
        echo "Relace Search"
    elif [[ "$clean_name" =~ relace-apply ]]; then
        echo "Relace Apply"

    # Handle EssentialAI Rnj models
    elif [[ "$clean_name" =~ rnj-([0-9]+)b ]]; then
        echo "Rnj ${BASH_REMATCH[1]}B"

    # Handle Prime Intellect INTELLECT models
    elif [[ "$clean_name" =~ intellect-([0-9]+) ]]; then
        echo "INTELLECT-${BASH_REMATCH[1]}"

    # Handle TNG Tech R1T Chimera models
    elif [[ "$clean_name" =~ r1t2-chimera ]]; then
        echo "R1T2 Chimera"
    elif [[ "$clean_name" =~ r1t-chimera ]]; then
        echo "R1T Chimera"

    # Handle Deep Cogito models
    elif [[ "$clean_name" =~ cogito-v([0-9]+\.[0-9]+) ]]; then
        echo "Cogito V${BASH_REMATCH[1]}"

    # Handle StepFun Step models
    elif [[ "$clean_name" =~ step-?([0-9]+) ]]; then
        echo "Step ${BASH_REMATCH[1]}"

    # Handle Meituan LongCat models
    elif [[ "$clean_name" =~ longcat ]]; then
        echo "LongCat"

    # Handle OpenGVLab InternVL models
    elif [[ "$clean_name" =~ internvl-?([0-9]+) ]]; then
        echo "InternVL ${BASH_REMATCH[1]}"
    elif [[ "$clean_name" =~ internvl ]]; then
        echo "InternVL"

    # Handle THUDM GLM Vision models
    elif [[ "$clean_name" =~ glm-([0-9])\\.([0-9])v ]]; then
        echo "GLM ${BASH_REMATCH[1]}.${BASH_REMATCH[2]}V"

    # Handle Tencent Hunyuan models
    elif [[ "$clean_name" =~ hunyuan(-[0-9]+b)? ]]; then
        local size="${BASH_REMATCH[1]}"
        if [ -n "$size" ]; then
            echo "Hunyuan ${size#-}"
        else
            echo "Hunyuan"
        fi

    # Handle Morph models
    elif [[ "$clean_name" =~ morph-v([0-9]+) ]]; then
        echo "Morph V${BASH_REMATCH[1]}"

    # Handle Baidu ERNIE models
    elif [[ "$clean_name" =~ ernie-([0-9]+\.[0-9]+)(-turbo)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local turbo="${BASH_REMATCH[2]}"
        local display="ERNIE ${version}"
        [ -n "$turbo" ] && display+=" Turbo"
        echo "$display"

    # Handle Inception Mercury models
    elif [[ "$clean_name" =~ mercury-coder ]]; then
        echo "Mercury Coder"
    elif [[ "$clean_name" =~ mercury ]]; then
        echo "Mercury"

    # Handle Cohere Command models
    elif [[ "$clean_name" =~ command-a ]]; then
        echo "Command A"
    elif [[ "$clean_name" =~ command-r\+ ]]; then
        echo "Command R+"
    elif [[ "$clean_name" =~ command-r ]]; then
        echo "Command R"

    # Handle AionLabs models
    elif [[ "$clean_name" =~ aion-([0-9]+\.[0-9]+) ]]; then
        echo "Aion ${BASH_REMATCH[1]}"

    # Handle Inflection models
    elif [[ "$clean_name" =~ inflection-([0-9]+) ]]; then
        echo "Inflection ${BASH_REMATCH[1]}"

    # Handle TheDrummer models
    elif [[ "$clean_name" =~ cydonia ]]; then
        echo "Cydonia"
    elif [[ "$clean_name" =~ skyfall ]]; then
        echo "Skyfall"
    elif [[ "$clean_name" =~ unslopnemo ]]; then
        echo "UnslopNemo"
    elif [[ "$clean_name" =~ rocinante ]]; then
        echo "Rocinante"

    # Handle NeverSleep models
    elif [[ "$clean_name" =~ lumimaid ]]; then
        echo "Lumimaid"
    elif [[ "$clean_name" =~ noromaid ]]; then
        echo "Noromaid"

    # Handle Sao10K models
    elif [[ "$clean_name" =~ euryale ]]; then
        echo "Euryale"
    elif [[ "$clean_name" =~ hanami ]]; then
        echo "Hanami"
    elif [[ "$clean_name" =~ lunaris ]]; then
        echo "Lunaris"

    # Handle Anthracite Magnum models
    elif [[ "$clean_name" =~ magnum(-[0-9]+b)? ]]; then
        local size="${BASH_REMATCH[1]}"
        if [ -n "$size" ]; then
            echo "Magnum ${size#-}"
        else
            echo "Magnum"
        fi

    # Handle Liquid LFM models
    elif [[ "$clean_name" =~ lfm-?([0-9]+)b? ]]; then
        echo "LFM ${BASH_REMATCH[1]}"
    elif [[ "$clean_name" =~ lfm ]]; then
        echo "LFM"

    # Handle IBM Granite models
    elif [[ "$clean_name" =~ granite-([0-9]+\.[0-9]+) ]]; then
        echo "Granite ${BASH_REMATCH[1]}"

    # Handle AI21 Jamba models
    elif [[ "$clean_name" =~ jamba-([0-9]+\.[0-9]+)(-instruct|-turbo)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        local display="Jamba ${version}"
        if [ "$variant" = "-instruct" ]; then
            display+=" Instruct"
        elif [ "$variant" = "-turbo" ]; then
            display+=" Turbo"
        fi
        echo "$display"

    # Handle Arcee AI models
    elif [[ "$clean_name" =~ arcee-trinity ]]; then
        echo "Trinity"
    elif [[ "$clean_name" =~ arcee-spotlight ]]; then
        echo "Spotlight"
    elif [[ "$clean_name" =~ arcee-maestro ]]; then
        echo "Maestro"
    elif [[ "$clean_name" =~ arcee-virtuoso ]]; then
        echo "Virtuoso"
    elif [[ "$clean_name" =~ arcee-coder ]]; then
        echo "Coder"

    # Handle Switchpoint Router
    elif [[ "$clean_name" =~ switchpoint-router ]]; then
        echo "Switchpoint Router"

    # Handle Perplexity Sonar models
    elif [[ "$clean_name" =~ sonar-deep-research ]]; then
        echo "Sonar Deep Research"
    elif [[ "$clean_name" =~ sonar-reasoning ]]; then
        echo "Sonar Reasoning"
    elif [[ "$clean_name" =~ sonar-pro ]]; then
        echo "Sonar Pro"
    elif [[ "$clean_name" =~ sonar ]]; then
        echo "Sonar"

    # Handle Mancer Weaver models
    elif [[ "$clean_name" =~ weaver ]]; then
        echo "Weaver"

    # Handle Gryphe MythoMax models
    elif [[ "$clean_name" =~ mythomax ]]; then
        echo "MythoMax"

    # Handle Alpindale Goliath models
    elif [[ "$clean_name" =~ goliath ]]; then
        echo "Goliath"

    # Handle OpenRouter special routers
    elif [[ "$clean_name" =~ auto-router ]]; then
        echo "Auto Router"
    elif [[ "$clean_name" =~ body-builder ]]; then
        echo "Body Builder"

    # Strip common suffixes (beta, alpha, version numbers, dates)
    # This should come near the end before fallback
    elif [[ "$clean_name" =~ ^(.+)-(beta|alpha|preview)$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local suffix="${BASH_REMATCH[2]}"
        # Capitalize first letter
        cap "$suffix"; suffix=$CAP
        # Try to format the base name nicely
        base=$(echo "$base" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
        echo "$base $suffix"
    elif [[ "$clean_name" =~ ^(.+)-v([0-9]+\.[0-9]+)$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local version="${BASH_REMATCH[2]}"
        base=$(echo "$base" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
        echo "$base v${version}"
    elif [[ "$clean_name" =~ ^(.+)-([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
        # Strip date suffix like 2024-11-20
        echo "${BASH_REMATCH[1]}" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
    elif [[ "$clean_name" =~ ^(.+)-([0-9]{2}-[0-9]{4})$ ]]; then
        # Strip date suffix like 08-2024
        echo "${BASH_REMATCH[1]}" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'

    # Handle generic vision models
    elif [[ "$clean_name" =~ vision-model ]]; then
        echo "Vision Model"

    # Fallback: return original name (strip provider prefix already done)
    else
        echo "$clean_name"
    fi | {
        # Post-process to add free emoji if needed
        read -r result
        [ "$is_free" = true ] && result+=" 🆓"
        echo "$result"
    }
}

# ============================================================================
# COST CALCULATION
# ============================================================================

calculate_cost() {
    local provider="$1"
    local model_id="$2"
    local input_tokens=$3
    local output_tokens=$4
    local cache_creation=$5
    local cache_read=$6

    local input_price=0
    local output_price=0
    local cache_creation_price=0
    local cache_read_price=0

    case "$model_id" in
        # OpenAI GPT-5 family
        *"gpt-5.2"*)
            input_price=1.75; output_price=14.00
            cache_read_price=0.175 ;;
        *"gpt-5.1"*)
            input_price=1.25; output_price=10.00
            cache_read_price=0.125 ;;
        *"gpt-5"*)
            if [[ "$model_id" == *"mini"* ]]; then
                input_price=0.25; output_price=2.00
                cache_read_price=0.025
            elif [[ "$model_id" == *"nano"* ]]; then
                input_price=0.05; output_price=0.40
                cache_read_price=0.005
            else
                input_price=1.25; output_price=10.00
                cache_read_price=0.125
            fi ;;

        # OpenAI GPT-4.1 family
        *"gpt-4.1"*)
            if [[ "$model_id" == *"nano"* ]]; then
                input_price=0.10; output_price=0.40
                cache_read_price=0.025
            elif [[ "$model_id" == *"mini"* ]]; then
                input_price=0.40; output_price=1.60
                cache_read_price=0.10
            else
                input_price=2.00; output_price=8.00
                cache_read_price=0.50
            fi ;;

        # OpenAI GPT-4o family
        *"gpt-4o"*"mini"*|*"gpt-4-o"*"mini"*)
            input_price=0.15; output_price=0.60
            cache_read_price=0.075 ;;
        *"gpt-4o"*|*"gpt-4-o"*)
            input_price=2.50; output_price=10.00
            cache_read_price=1.25 ;;
        *"gpt-4"*)
            input_price=30.00; output_price=60.00 ;;
        *"gpt-3.5"*)
            input_price=0.50; output_price=1.50 ;;

        # OpenAI o-series
        *"o4"*"mini"*)
            input_price=1.10; output_price=4.40
            cache_read_price=0.275 ;;
        *"o3"*"mini"*)
            input_price=1.10; output_price=4.40
            cache_read_price=0.55 ;;
        *"o3"*)
            input_price=2.00; output_price=8.00
            cache_read_price=0.50 ;;

        # Claude family - Opus 4.5+ ($5/$25)
        *"opus-4-5"*|*"opus-4-6"*|*"opus-4.5"*|*"opus-4.6"*)
            input_price=5.00; output_price=25.00
            cache_creation_price=6.25; cache_read_price=0.50 ;;
        # Claude family - Opus 4/4.1 and older ($15/$75)
        *"opus"*)
            input_price=15.00; output_price=75.00
            cache_creation_price=18.75; cache_read_price=1.50 ;;
        # Claude family - Sonnet (all versions $3/$15)
        *"sonnet"*)
            input_price=3.00; output_price=15.00
            cache_creation_price=3.75; cache_read_price=0.30 ;;
        # Claude family - Haiku 4.5 ($1/$5)
        *"haiku-4"*)
            input_price=1.00; output_price=5.00
            cache_creation_price=1.25; cache_read_price=0.10 ;;
        # Claude family - Haiku 3.5 ($0.80/$4)
        *"3-5-haiku"*|*"3.5-haiku"*|*"haiku-3-5"*|*"haiku-3.5"*)
            input_price=0.80; output_price=4.00
            cache_creation_price=1.00; cache_read_price=0.08 ;;
        # Claude family - Haiku 3 ($0.25/$1.25)
        *"haiku"*)
            input_price=0.25; output_price=1.25
            cache_creation_price=0.30; cache_read_price=0.03 ;;

        # Gemini family
        *"gemini-3"*"pro"*)
            input_price=2.00; output_price=12.00
            cache_read_price=0.20 ;;
        *"gemini-3"*"flash"*)
            input_price=0.50; output_price=3.00
            cache_read_price=0.05 ;;
        *"gemini-2.5"*"pro"*|*"2.5-pro"*)
            input_price=1.25; output_price=10.00
            cache_read_price=0.125 ;;
        *"gemini-2.5"*"flash"*"lite"*)
            input_price=0.10; output_price=0.40
            cache_read_price=0.01 ;;
        *"gemini-2.5"*"flash"*|*"2.5-flash"*)
            input_price=0.30; output_price=2.50
            cache_read_price=0.03 ;;
        *"gemini-2.0"*"flash"*"lite"*)
            input_price=0.075; output_price=0.30 ;;
        *"gemini-2.0"*|*"2.0-flash"*)
            input_price=0.10; output_price=0.40
            cache_read_price=0.025 ;;
        *"gemini-1.5-pro"*|*"1.5-pro"*)
            input_price=1.25; output_price=5.00 ;;
        *"gemini-1.5-flash"*|*"1.5-flash"*)
            input_price=0.075; output_price=0.30 ;;

        # DeepSeek family (V3.2 unified pricing)
        *"deepseek"*)
            input_price=0.28; output_price=0.42
            cache_creation_price=0.28; cache_read_price=0.028 ;;

        # Qwen / Alibaba Cloud family
        *"qwen3.5-plus"*|*"qwen3-5-plus"*)
            input_price=0.35; output_price=1.20
            cache_creation_price=0.35; cache_read_price=0.035 ;;
        *"qwen3-max"*)
            input_price=0.50; output_price=2.00
            cache_creation_price=0.50; cache_read_price=0.05 ;;
        *"qwen3-coder"*)
            input_price=0.25; output_price=0.75
            cache_creation_price=0.25; cache_read_price=0.025 ;;
        *"qwen3"*)
            input_price=0.20; output_price=0.60
            cache_creation_price=0.20; cache_read_price=0.02 ;;
        *"qwq"*)
            input_price=0.15; output_price=0.45
            cache_creation_price=0.15; cache_read_price=0.015 ;;
        *"qwen"*)
            input_price=0.14; output_price=0.14 ;;

        # Kimi / Moonshot AI family (Alibaba Cloud)
        *"kimi"*"k2.5"*)
            input_price=0.20; output_price=3.00
            cache_creation_price=0.20; cache_read_price=0.02 ;;
        *"kimi"*"k2"*|*"moonshot"*"k2"*)
            input_price=0.15; output_price=2.50 ;;
        *"moonshot"*"128k"*)
            input_price=0.84; output_price=0.84 ;;
        *"moonshot"*"32k"*)
            input_price=0.34; output_price=0.34 ;;
        *"moonshot"*"8k"*)
            input_price=0.17; output_price=0.17 ;;

        # GLM (Zhipu AI) family (Alibaba Cloud)
        *"glm-5"*)
            input_price=0.28; output_price=1.12
            cache_creation_price=0.28; cache_read_price=0.028 ;;
        *"glm-4.7"*)
            input_price=0.14; output_price=0.28
            cache_creation_price=0.14; cache_read_price=0.014 ;;
        *"glm-4.6"*|*"glm-4-plus"*)
            input_price=0.84; output_price=0.84 ;;
        *"glm-4.5"*)
            input_price=0.14; output_price=0.14 ;;
        *"glm"*)
            input_price=0.14; output_price=0.14 ;;

        # MiniMax AI family (Alibaba Cloud)
        *"minimax-m2.5"*|*"m2.5"*)
            input_price=0.35; output_price=1.40
            cache_creation_price=0.40; cache_read_price=0.035 ;;
        *"minimax"*"m2"*|*"m2"*)
            input_price=0.30; output_price=1.20
            cache_creation_price=0.375; cache_read_price=0.03 ;;
        *"abab6.5s"*|*"6.5s"*)
            input_price=0.14; output_price=0.14 ;;
        *"abab6.5"*|*"6.5"*)
            input_price=0.42; output_price=0.42 ;;
        *"abab5.5"*|*"5.5"*)
            input_price=0.07; output_price=0.07 ;;

        # Default (Claude Sonnet 4.5 pricing)
        *)
            input_price=3.00; output_price=15.00
            cache_creation_price=3.75; cache_read_price=0.30 ;;
    esac

    # Calculate costs
    local regular_input=$((input_tokens - cache_read - cache_creation))
    [ $regular_input -lt 0 ] && regular_input=0

    local cost_input cost_output cost_cache_creation cost_cache_read total
    cost_input=$(echo "scale=6; $regular_input * $input_price / 1000000" | bc 2>/dev/null || echo "0")
    cost_output=$(echo "scale=6; $output_tokens * $output_price / 1000000" | bc 2>/dev/null || echo "0")
    cost_cache_creation=$(echo "scale=6; $cache_creation * $cache_creation_price / 1000000" | bc 2>/dev/null || echo "0")
    cost_cache_read=$(echo "scale=6; $cache_read * $cache_read_price / 1000000" | bc 2>/dev/null || echo "0")
    total=$(echo "scale=2; $cost_input + $cost_output + $cost_cache_creation + $cost_cache_read" | bc 2>/dev/null || echo "0")
    echo "$total"
}

# ============================================================================
# SUBSCRIPTION INFO
# ============================================================================

# Sets REPLY; the renewal countdown (a jq plus date forks) is cached for an hour
get_subscription_info() {
    local cache
    REPLY=""
    [ -f "$STATUSLINE_CONFIG_FILE" ] || return
    cache_key "$1"; cache="${STATE_DIR}/sub-${REPLY}"
    [ ! "$STATUSLINE_CONFIG_FILE" -nt "$cache" ] && fresh_cache "$cache" 3600 && return
    REPLY=$(_subscription_info "$1")
    stamp_cache "$cache" "$REPLY"
}

_subscription_info() {
    local provider="$1"
    local current_timestamp
    current_timestamp=$NOW

    [ ! -f "$STATUSLINE_CONFIG_FILE" ] && return

    local subscription_type renewal_date renewal_day
    { IFS= read -r subscription_type; IFS= read -r renewal_date; IFS= read -r renewal_day; } < <(
        jq -r --arg p "$provider" '.subscriptions[$p] // {} | (.type // ""), (.renewal_date // ""), (.renewal_day // "" | tostring)' \
            "$STATUSLINE_CONFIG_FILE" 2>/dev/null)

    [ -z "$subscription_type" ] || [ -z "$renewal_date" ] && return

    local renewal_timestamp expiry_timestamp label="↻"
    renewal_timestamp=$(_date_to_epoch "%Y-%m-%d" "$renewal_date")

    case "$subscription_type" in
        "monthly")
            while [ "$renewal_timestamp" -lt "$current_timestamp" ]; do
                local current_month current_year next_month next_year day_of_month
                current_month=$(_epoch_to_fmt "$renewal_timestamp" +%m)
                current_year=$(_epoch_to_fmt "$renewal_timestamp" +%Y)
                next_month=$((10#$current_month + 1))
                next_year=$current_year
                [ $next_month -gt 12 ] && { next_month=1; next_year=$((next_year + 1)); }
                next_month=$(printf "%02d" $next_month)
                day_of_month=${renewal_day:-$(echo "$renewal_date" | cut -d'-' -f3)}
                renewal_timestamp=$(_date_to_epoch "%Y-%m-%d" "${next_year}-${next_month}-${day_of_month}")
            done
            expiry_timestamp=$renewal_timestamp ;;
        "yearly")
            while [ "$renewal_timestamp" -lt "$current_timestamp" ]; do
                local current_year next_year month_day
                current_year=$(_epoch_to_fmt "$renewal_timestamp" +%Y)
                next_year=$((current_year + 1))
                month_day=$(echo "$renewal_date" | cut -d'-' -f2-)
                renewal_timestamp=$(_date_to_epoch "%Y-%m-%d" "${next_year}-${month_day}")
            done
            expiry_timestamp=$renewal_timestamp ;;
        *) return ;;
    esac

    if [ -n "$expiry_timestamp" ]; then
        local seconds_remaining=$((expiry_timestamp - current_timestamp))
        local days_remaining=$((seconds_remaining / 86400))

        if [ "$days_remaining" -lt 0 ]; then
            printf "${C_RED}${label} OVERDUE %dd${C_RESET}" "$((days_remaining * -1))"
        elif [ "$days_remaining" -eq 0 ]; then
            printf '%s' "${C_RED}${label} TODAY${C_RESET}"
        elif [ "$days_remaining" -le 7 ]; then
            printf "${C_RED}${label} %dd${C_RESET}" "$days_remaining"
        elif [ "$days_remaining" -le 30 ]; then
            printf "${C_YELLOW}${label} %dd${C_RESET}" "$days_remaining"
        else
            printf "${C_GRAY}${label} %dd${C_RESET}" "$days_remaining"
        fi
    fi
}

# ============================================================================
# LANGUAGE & PACKAGE MANAGER DETECTION
# ============================================================================

# Sets REPLY to the first word-split field $2 of "$3 ..."'s first output line, cached for an hour
# per tool ($1) so versions don't cost a fork per render.
# shortcut: one cache per tool name, so a PATH switch (nvm, herd) shows up within the hour
tool_version() {
    local field=$2 f="${STATE_DIR}/ver-$1" out
    local -a words
    shift 2
    REPLY=""
    command -v "$1" >/dev/null 2>&1 || return
    fresh_cache "$f" 3600 && return
    out=$("$@" 2>/dev/null)
    read -ra words <<< "${out%%$'\n'*}"
    REPLY=${words[field - 1]}
    stamp_cache "$f" "$REPLY"
}

# Appends "+$2" to the global $1 list ("a+b")
_add() {
    [ -z "$2" ] && return
    if [ -n "${!1}" ]; then printf -v "$1" '%s+%s' "${!1}" "$2"; else printf -v "$1" '%s' "$2"; fi
}

# Sets REPLY to "pkg1+pkg2|lang1+lang2"
detect_dev_environment() {
    local dir="$1"
    local pkg_managers="" languages=""

    # JavaScript/Node.js
    if [ -f "$dir/pnpm-lock.yaml" ]; then pkg_managers="pnpm"
    elif [ -f "$dir/bun.lockb" ]; then pkg_managers="bun"
    elif [ -f "$dir/yarn.lock" ]; then pkg_managers="yarn"
    elif [ -f "$dir/package-lock.json" ] || [ -f "$dir/package.json" ]; then pkg_managers="npm"
    fi
    if [ "$pkg_managers" = "bun" ]; then
        tool_version bun 1 bun --version; [ -n "$REPLY" ] && languages="Bun $REPLY"
    elif [ -n "$pkg_managers" ]; then
        tool_version node 1 node --version; [ -n "$REPLY" ] && languages="Node ${REPLY#v}"
    fi

    if [ -f "$dir/composer.json" ]; then
        _add pkg_managers composer
        tool_version php 2 php --version; [ -n "$REPLY" ] && _add languages "PHP $REPLY"
    fi
    if [ -f "$dir/Gemfile" ]; then
        _add pkg_managers gem
        tool_version ruby 2 ruby --version; [ -n "$REPLY" ] && _add languages "Ruby $REPLY"
    fi
    if [ -f "$dir/requirements.txt" ] || [ -f "$dir/Pipfile" ] || [ -f "$dir/pyproject.toml" ]; then
        _add pkg_managers pip
        tool_version python3 2 python3 --version
        [ -z "$REPLY" ] && tool_version python 2 python --version
        [ -n "$REPLY" ] && _add languages "Python $REPLY"
    fi
    if [ -f "$dir/go.mod" ]; then
        _add pkg_managers go
        tool_version go 3 go version; [ -n "$REPLY" ] && _add languages "Go ${REPLY#go}"
    fi
    if [ -f "$dir/Cargo.toml" ]; then
        _add pkg_managers cargo
        tool_version rustc 2 rustc --version; [ -n "$REPLY" ] && _add languages "Rust $REPLY"
    fi

    REPLY="${pkg_managers}|${languages}"
}

# ============================================================================
# SERVER DETECTION
# ============================================================================

# shellcheck disable=SC2329  # invoked through bg_cached
detect_running_servers() {
    local -a listened_ports ignored_ports active_servers
    local server_detection="true" listened="" ignored_list=""

    if [ -f "$STATUSLINE_CONFIG_FILE" ]; then
        { IFS= read -r server_detection; IFS= read -r listened; IFS= read -r ignored_list; } < <(
            jq -r '.features // {} | (.server_detection | if . == null then "true" else tostring end),
                ((.listened_ports // []) | map(tostring) | join(" ")), ((.ignored_ports // []) | map(tostring) | join(" "))' \
                "$STATUSLINE_CONFIG_FILE" 2>/dev/null)
        read -ra listened_ports <<< "$listened"
        read -ra ignored_ports <<< "$ignored_list"
    fi
    [ "$server_detection" != "true" ] && return

    # Default ports
    [ ${#listened_ports[@]} -eq 0 ] && listened_ports=(80 3000 3001 3306 4200 5173 5174 5432 6379 8000 8001 8080 8888 9000)

    local netstat_output port skip_port ignored process_name match

    if command -v netstat >/dev/null 2>&1; then
        netstat_output=$(netstat -an -p tcp 2>/dev/null | grep LISTEN | awk '{print $4}')
        if [ -n "$netstat_output" ]; then
            for port in "${listened_ports[@]}"; do
                skip_port=false
                for ignored in "${ignored_ports[@]}"; do
                    [ "$port" = "$ignored" ] && { skip_port=true; break; }
                done
                [ "$skip_port" = true ] && continue

                if echo "$netstat_output" | grep -q -E "[.:]${port}$"; then
                    process_name=$(lsof -iTCP:"$port" -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR==2 {print $1}')
                    [ -n "$process_name" ] && active_servers+=("${process_name}:${port}")
                fi
            done
        fi
    else
        local lsof_output
        lsof_output=$(lsof -iTCP -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR>1 {print $1":"$9}')
        if [ -n "$lsof_output" ]; then
            for port in "${listened_ports[@]}"; do
                skip_port=false
                for ignored in "${ignored_ports[@]}"; do
                    [ "$port" = "$ignored" ] && { skip_port=true; break; }
                done
                [ "$skip_port" = true ] && continue

                match=$(echo "$lsof_output" | grep ":${port}$" | head -1)
                if [ -n "$match" ]; then
                    process_name=$(echo "$match" | cut -d: -f1)
                    active_servers+=("${process_name}:${port}")
                fi
            done
        fi
    fi

    [ ${#active_servers[@]} -gt 0 ] && echo "$(IFS=', '; echo "${active_servers[*]}")"
}

# ============================================================================
# CONFIG COUNTING (MCP, Rules, Hooks)
# ============================================================================

# Sets REPLY
count_claude_md_files() {
    local cwd="$1" f
    REPLY=0
    for f in "${HOME}/.claude/CLAUDE.md" ${cwd:+"${cwd}/CLAUDE.md" "${cwd}/CLAUDE.local.md" "${cwd}/.claude/CLAUDE.md" "${cwd}/.claude/CLAUDE.local.md"}; do
        [ -f "$f" ] && REPLY=$((REPLY + 1))
    done
}

# Sets REPLY to the *.md count under ~/.claude/rules and {cwd}/.claude/rules (find only when they exist)
count_rules() {
    local cwd="$1" d out
    REPLY=0
    for d in "${HOME}/.claude/rules" ${cwd:+"${cwd}/.claude/rules"}; do
        [ -d "$d" ] || continue
        out=$(find "$d" -type f -name "*.md" 2>/dev/null)
        [ -n "$out" ] || continue
        out=${out//[!$'\n']/}
        REPLY=$((REPLY + ${#out} + 1))
    done
}

# Sets CFG_MCP (servers in user + project config) and CFG_HOOKS (hook events in user + project
# settings) with one jq call, cached until one of the files changes.
count_config() {
    local cwd="$1" f cache stale="" out
    local -a files=()
    for f in "${HOME}/.claude/settings.json" "${HOME}/.claude.json" \
        ${cwd:+"${cwd}/.mcp.json" "${cwd}/.claude/settings.json" "${cwd}/.claude/settings.local.json"}; do
        [ -f "$f" ] && files+=("$f")
    done
    CFG_MCP=0 CFG_HOOKS=0
    [ ${#files[@]} -eq 0 ] && return
    cache_key "$cwd"; cache="${STATE_DIR}/cfgcount-${REPLY}"
    [ -f "$cache" ] || stale=1
    for f in "${files[@]}"; do [ "$f" -nt "$cache" ] && stale=1; done
    if [ -n "$stale" ]; then
        # ~/.claude.json and .mcp.json carry no hooks
        out=$(jq -rn --arg no_hooks1 "${HOME}/.claude.json" --arg no_hooks2 "${cwd}/.mcp.json" '
            reduce inputs as $d ({m: 0, h: 0};
                .m += ($d.mcpServers // {} | length)
                | .h += (if input_filename == $no_hooks1 or input_filename == $no_hooks2 then 0
                         else ($d.hooks // {} | length) end))
            | "\(.m) \(.h)"' "${files[@]}" 2>/dev/null)
        echo "${out:-0 0}" > "$cache"
    fi
    read -r CFG_MCP CFG_HOOKS < "$cache"
    [[ "$CFG_MCP" =~ ^[0-9]+$ ]] || CFG_MCP=0
    [[ "$CFG_HOOKS" =~ ^[0-9]+$ ]] || CFG_HOOKS=0
}

# ============================================================================
# TRANSCRIPT PARSING (Tools, Agents, Todos)
# ============================================================================

# Spinner frames for running tools
readonly SPINNER_FRAMES=("◐" "◓" "◑" "◒")

# ripgrep is ~20x faster than BSD grep on large transcripts. An array (not a function) so
# `<("${TSEARCH[@]}" ...)` execs it straight from the substitution's fork.
if command -v rg >/dev/null 2>&1; then
    TSEARCH=(rg --no-filename --no-line-number)
else
    TSEARCH=(env LC_ALL=C grep -h)
fi

# Writes the render-ready summary lines (see the read list in main) to $2.
# Skipped while $2 is newer than the transcript: idle renders cost no forks.
parse_transcript() {
    local transcript_path="$1"
    local result_file="$2"

    [ ! -f "$transcript_path" ] && return
    [ "$result_file" -nt "$transcript_path" ] && return

    # Tool outputs are most of a transcript's bytes, so tool_result IDs are pulled with a
    # regex instead of parsing JSON; only tool_use lines get parsed. fromjson? skips a
    # partially-written last line. Background agents get an immediate "Async agent launched"
    # tool_result and only finish once a <task-notification> names their tool-use-id.
    # Temp files, not <(...): native Windows jq.exe can't open /dev/fd/N
    local tmp="$result_file.$$"
    "${TSEARCH[@]}" -o '"tool_use_id":"[^"]*"' "$transcript_path" > "$tmp.ids" 2>/dev/null
    # rg found but not runnable (WinGet's symlinked rg gives "Permission denied" in Git Bash): use grep
    if [ $? -gt 1 ] && [ "${TSEARCH[0]}" = rg ]; then
        TSEARCH=(env LC_ALL=C grep -h)
        "${TSEARCH[@]}" -o '"tool_use_id":"[^"]*"' "$transcript_path" > "$tmp.ids" 2>/dev/null
    fi
    "${TSEARCH[@]}" -F 'Async agent launched' "$transcript_path" > "$tmp.async" 2>/dev/null
    "${TSEARCH[@]}" -o '<tool-use-id>[^<]*</tool-use-id>' "$transcript_path" > "$tmp.notified" 2>/dev/null
    "${TSEARCH[@]}" -F '"type":"tool_use"' "$transcript_path" 2>/dev/null | jq -nRr \
        --rawfile result_ids "$tmp.ids" --rawfile async_lines "$tmp.async" --rawfile notified_ids "$tmp.notified" '
        def is_agent: .name == "Agent" or .name == "Task";
        def text: if type == "array" then map(.text? // "") | join("") else tostring end;
        def id_set(s; re): [s | scan(re)[0] | {key: ., value: true}] | from_entries;
        def s: tostring | gsub("[\n\t]"; " ");
        # Transcript timestamps are UTC ISO-8601 with milliseconds
        def epoch: if type == "string" and . != "" then (sub("\\..*$"; "") | sub("Z$"; "") + "Z" | fromdateiso8601? // "") else "" end;
        def target: .name as $n | (.input // {}) as $i |
            if $n == "Read" or $n == "Write" or $n == "Edit" then ($i.file_path // $i.path // "" | split("/") | last // "" | split("\\") | last // "")
            elif $n == "Glob" then ($i.pattern // "")
            elif $n == "Grep" then ($i.pattern // "" | .[:20])
            elif $n == "Bash" then (($i.command // "") | .[:25]) + "..."
            elif $n == "Task" then ($i.description // "")
            else "" end;
        id_set($result_ids; "\"tool_use_id\":\"([^\"]+)\"") as $results
        | id_set($notified_ids; "<tool-use-id>([^<]+)</tool-use-id>") as $notified
        | ([$async_lines | split("\n")[] | fromjson? | .message.content[]?
            | select(.type? == "tool_result" and (.content | text | startswith("Async agent launched")))
            | {key: .tool_use_id, value: true}] | from_entries) as $async
        | [inputs | fromjson? | select(.message.content? | type == "array") |
            .timestamp as $ts | .message.content[] | select(.type == "tool_use") |
            {id, name, input, timestamp: $ts} | (.id // "") as $id
            | .done = (if $async[$id] then $notified[$id] // false else $results[$id] // false end)] as $uses
        | [$uses[] | select((.done | not) and .name != "TodoWrite" and (is_agent | not))] as $t
        | [$uses[] | select(is_agent and (.done | not))] as $a
        | ([$uses[] | select(.name == "TodoWrite")] | last | .input.todos // []) as $d
        | ([$uses[] | select(.done and .name != "TodoWrite" and (is_agent | not))]
            | group_by(.name) | map({name: .[0].name, count: length}) | sort_by(-.count)) as $c
        | ($t | length), ($t[0].name // "" | s), ($t[0] // {} | target | s), ($t[0].timestamp | epoch),
          ($a | length), ($a[0].input.subagent_type // "unknown" | s), ($a[0].input.model // "" | s),
          ($a[0].input.description // "" | s), ($a[0].timestamp | epoch),
          ($d | length), ([$d[] | select(.status == "completed")] | length),
          ([$d[] | select(.status == "in_progress")][0] // {} | .activeForm // .content // "" | s),
          ($c[:3][] | "\(.name)\t\(.count)"), (if ($c | length) > 3 then "+\t\(($c | length) - 3)" else empty end)
    ' > "$tmp" 2>/dev/null && mv "$tmp" "$result_file"
    rm -f "$tmp.ids" "$tmp.async" "$tmp.notified"
}

# mcp__plugin_honcho_honcho__get_config -> honcho:get_config (sets REPLY)
short_tool_name() {
    local name="$1"
    if [[ "$name" != mcp__* ]]; then
        REPLY=$name
        return
    fi
    name=${name#mcp__}
    local server=${name%%__*} tool=${name#*__}
    server=${server#plugin_}
    server=${server#claude_ai_}
    [[ "$server" == *_* && "${server%%_*}" == "${server#*_}" ]] && server=${server%%_*}
    REPLY="${server}:${tool}"
}

# Green → yellow (70) → red (100) color for a 0-100 value; 16-color thresholds without truecolor
# Sets GRAD (no subshell: it runs once per bar cell)
grad_color() {
    local p=$1 r1 g1 b1 r2 g2 b2 t span
    [ "$p" -gt 100 ] && p=100
    [ "$p" -lt 0 ] && p=0
    if [ "$TRUECOLOR" = 0 ]; then
        if [ "$p" -ge 90 ]; then GRAD=$C_RED
        elif [ "$p" -ge 70 ]; then GRAD=$C_YELLOW
        else GRAD=$C_GREEN; fi
        return
    fi
    if [ "$p" -le 70 ]; then
        r1=$LO_R g1=$LO_G b1=$LO_B r2=$MID_R g2=$MID_G b2=$MID_B t=$p span=70
    else
        r1=$MID_R g1=$MID_G b1=$MID_B r2=$HI_R g2=$HI_G b2=$HI_B t=$((p - 70)) span=30
    fi
    printf -v GRAD '\\033[38;2;%d;%d;%dm' $((r1 + (r2 - r1) * t / span)) $((g1 + (g2 - g1) * t / span)) $((b1 + (b2 - b1) * t / span))
}

# Smooth bar with 1/8-cell precision; each cell is colored by its own position (gradient track).
# Sets REPLY
make_bar() {
    local pct=$1 width=${2:-10} i cell eighths bar=""
    local -a parts=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
    [ "$pct" -gt 100 ] && pct=100
    eighths=$((pct * width * 8 / 100))
    for ((i = 0; i < width; i++)); do
        cell=$((eighths - i * 8))
        if [ "$cell" -le 0 ]; then bar+="${C_GRAY}·"; continue; fi
        if [ "$TRUECOLOR" = 1 ]; then grad_color $(( (i * 100 + 50) / width )); else grad_color "$pct"; fi
        bar+=$GRAD
        if [ "$cell" -ge 8 ]; then bar+="█"; else bar+="${parts[$cell]}"; fi
    done
    REPLY="${bar}${C_RESET}"
}

# Sets REPLY to the visible width of a string with literal or raw \033[..m color codes
# Linear scan: bash 3.2 extglob substitution (*([0-9;])) hangs on long lines
vis_len() {
    local s=$1 out esc
    for esc in '\033[' $'\033['; do
        out=""
        while [[ "$s" == *"$esc"* ]]; do
            out+=${s%%"$esc"*}
            s=${s#*"$esc"}
            s=${s#*m}
        done
        s="$out$s"
    done
    REPLY=${#s}
}

# Sets REPLY to "prio<TAB>sep<TAB>text" segments joined in display order, dropping the highest prio first
# until the line fits $1 columns. Prio 0 is never dropped; ⚠ alert segments go last (prio 1).
fit_line() {
    local width=$1; shift
    local -a segs=("$@")
    local line i p max drop rest
    while :; do
        line=""; max=0; drop=-1
        for i in "${!segs[@]}"; do
            [ -z "${segs[$i]}" ] && continue
            p=${segs[$i]%%$'\t'*}; rest=${segs[$i]#*$'\t'}
            [ -n "$line" ] && line+="${rest%%$'\t'*}"
            line+="${rest#*$'\t'}"
            [[ "$rest" == *⚠* ]] && [ "$p" -gt 1 ] && p=1
            # -ge: on ties drop the rightmost segment
            if [ "$p" -gt 0 ] && [ "$p" -ge "$max" ]; then max=$p; drop=$i; fi
        done
        [ "$drop" -lt 0 ] && break
        vis_len "$line"; [ "$REPLY" -le "$width" ] && break
        segs[drop]=""
    done
    REPLY=$line
}

# Sets REPLY to ▁▂▃▄▅▆▇█ for space-separated integers (3+), scaled to $2 (or to their max when omitted)
sparkline() {
    local max=${2:-0} v out=""
    local -a vals ch=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
    REPLY=""
    read -ra vals <<< "$1"
    [ ${#vals[@]} -ge 3 ] || return
    if [ "$max" -eq 0 ]; then
        for v in "${vals[@]}"; do [ "$v" -gt "$max" ] && max=$v; done
    fi
    [ "$max" -le 0 ] && return
    for v in "${vals[@]}"; do
        [ "$v" -gt "$max" ] && v=$max
        [ "$v" -lt 0 ] && v=0
        out+=${ch[$((v * 7 / max))]}
    done
    REPLY=$out
}

# Sets REPLY; in rupiah when RATE_IDR is set
fmt_cents() {
    [ "${RATE_IDR:-0}" -gt 0 ] && { fmt_idr $(($1 * 100)); return; }
    printf -v REPLY '$%d.%02d' $(($1 / 100)) $(($1 % 100))
}

# Sets REPLY to $1 (in 1/10000 USD) as short rupiah: Rp850, Rp12.3k, Rp1.34M
fmt_idr() {
    local n=$((($1 * RATE_IDR + 500000) / 1000000)) frac
    if [ "$n" -lt 1000 ]; then
        REPLY="Rp${n}"
    elif [ "$n" -lt 999950 ]; then
        n=$(((n + 50) / 100))
        REPLY="Rp$((n / 10))"
        [ $((n % 10)) -gt 0 ] && REPLY+=".$((n % 10))"
        REPLY+="k"
    else
        n=$(((n + 5000) / 10000))
        printf -v frac '%02d' $((n % 100))
        frac=${frac%0}; frac=${frac%0}
        REPLY="Rp$((n / 100))${frac:+.$frac}M"
    fi
}

# Writes the live USD->IDR mid-market rate x100 to cache $1; Yahoo Finance (intraday),
# open.er-api.com (daily) as fallback. Rejects values outside Rp1.000-100.000 per USD.
# shellcheck disable=SC2329  # invoked in the background by usd_idr_rate
_fetch_usd_idr() {
    local r
    r=$(curl -fsS -m 5 -A 'Mozilla/5.0' 'https://query1.finance.yahoo.com/v8/finance/chart/USDIDR=X?range=1d&interval=1d' |
        jq -r '.chart.result[0].meta.regularMarketPrice // empty | . * 100 | round')
    [[ "$r" =~ ^[0-9]+$ ]] || r=$(curl -fsS -m 5 'https://open.er-api.com/v6/latest/USD' |
        jq -r '.rates.IDR // empty | . * 100 | round')
    [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -ge 100000 ] && [ "$r" -le 10000000 ] || return
    stamp_cache "$1.$$" "$r" && mv "$1.$$" "$1"
}

# Sets REPLY to the cached rate x100 (empty before the first fetch lands); refetches in the
# background when older than an hour, at most once a minute
usd_idr_rate() {
    local cache="${HOME}/.cache/claude-statusline/usd-idr" at=""
    fresh_cache "$cache" 3600 && return
    [ -f "$cache.try" ] && read -r at < "$cache.try"
    [[ "$at" =~ ^[0-9]+$ ]] && [ $((NOW - at)) -lt 60 ] && return
    mkdir -p "${cache%/*}" 2>/dev/null && echo "$NOW" > "$cache.try" || return
    (_fetch_usd_idr "$cache") </dev/null >/dev/null 2>&1 &
}

# Spend across all sessions: sets REPLY to "<today cents> <last 7 days cents>".
# Per-day ledger rows: session_id, baseline (cost when first seen that day), latest cost.
# A session spanning midnight thus splits its cost between days; a cost reset (resume)
# carries the earlier spend forward by lowering the baseline.
# shortcut: only counts sessions this statusline has rendered since the ledger existed
cost_ledger() {
    local sid=$1 cents=$2 dir="${HOME}/.cache/claude-statusline" now=$NOW today cutoff file memo
    local m_day m_cents m_at m_t m_w
    REPLY=""
    [ -n "$sid" ] || return
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return
    epoch_fmt "$now" +%F; today=$REPLY
    # Same day and cost as a render <60s ago: reuse its totals (awk+mv per render is ~150ms on Windows)
    memo="${STATE_DIR}/ledger-${sid}"
    if [ -f "$memo" ] && read -r m_day m_cents m_at m_t m_w < "$memo" && [ "$m_day" = "$today" ] &&
        [ "$m_cents" = "$cents" ] && [[ "$m_at" =~ ^[0-9]+$ ]] && [ $((now - m_at)) -lt 60 ]; then
        REPLY="$m_t $m_w"
        return
    fi
    epoch_fmt $((now - 6 * 86400)) +%F; cutoff=$REPLY
    file="$dir/cost-${today}.tsv"
    [ -f "$file" ] || : > "$file"
    awk -F'\t' -v OFS='\t' -v s="$sid" -v c="$cents" '
        $1 == s { if (c < $3) $2 -= $3; $3 = c; f = 1 }
        { print }
        END { if (!f) print s, c, c }' "$file" > "$file.$$" && mv "$file.$$" "$file"
    read -r m_t m_w < <(awk -F'\t' -v today="cost-${today}.tsv" -v cutoff="cost-${cutoff}.tsv" '
        { n = FILENAME; sub(/.*\//, "", n); if (n < cutoff) next
          d = $3 - $2; if (d < 0) d = 0; w += d; if (n == today) t += d }
        END { printf "%d %d\n", t, w }' "$dir"/cost-*.tsv)
    echo "$today $cents $now $m_t $m_w" > "$memo"
    REPLY="$m_t $m_w"
}

# Sets REPLY to the cached output of "$@" (cache name $1) and refreshes it in the background when
# older than a minute, so slow commands (network, daemons) never block a render.
# Freshness is an epoch in "$cache.at" (no `find -mmin` fork).
bg_cached() {
    local cache="${STATE_DIR}/$1" at=""; shift
    [ -f "$cache.at" ] && read -r at < "$cache.at"
    if [[ ! "$at" =~ ^[0-9]+$ ]] || [ $((NOW - at)) -gt 60 ]; then
        echo "$NOW" > "$cache.at"
        ("$@" > "$cache.$$" 2>/dev/null; mv "$cache.$$" "$cache") </dev/null >/dev/null 2>&1 &
    fi
    slurp "$cache"
}

# shellcheck disable=SC2329,SC2016  # invoked through bg_cached; $c/$checks are jq variables
_fetch_pr() {
    cd "$1" && gh pr view "$2" --json state,number,reviewDecision,statusCheckRollup --jq 'select(.state == "OPEN") |
        ([.statusCheckRollup[]? | (.conclusion // .state // "")] ) as $c |
        (if ($c | length) == 0 then ""
         elif any($c[]; test("FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED")) then "fail"
         elif any($c[]; . == "" or test("PENDING|QUEUED|IN_PROGRESS|EXPECTED")) then "pending"
         else "pass" end) as $checks |
        [.number, $checks, (.reviewDecision // "")] | @tsv'
}

# Open PR (not merged/closed) for the current branch via gh: sets REPLY to "number<TAB>checks<TAB>review"
get_pr_status() {
    local dir=$1 branch=$2
    REPLY=""
    command -v gh >/dev/null 2>&1 && [ -n "$branch" ] && [ "$branch" != "detached" ] || return
    cache_key "${dir}|${branch}"
    bg_cached "pr-$REPLY" _fetch_pr "$dir" "$branch"
}

# shellcheck disable=SC2329  # invoked through bg_cached
_docker_count() {
    docker ps -q | grep -c .
}

# Sets REPLY to the running container count; empty without docker or a running daemon
get_docker_count() {
    REPLY=""
    command -v docker >/dev/null 2>&1 || return
    bg_cached docker-count _docker_count
    [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -gt 0 ] || REPLY=""
}

# macOS notification, once per key (flag file in STATE_DIR), sent in the background
notify_once() {
    local flag="${STATE_DIR}/notified-$1"
    [ "$NOTIFICATIONS" = "true" ] && [ ! -f "$flag" ] && command -v osascript >/dev/null 2>&1 || return
    : > "$flag"
    osascript -e "display notification \"${3//\"/}\" with title \"${2//\"/}\" sound name \"Submarine\"" \
        </dev/null >/dev/null 2>&1 &
}

# Sets REPLY to the time since epoch $1 ("" when unknown)
format_elapsed_time() {
    local start_epoch="$1" current_time="$2" elapsed
    REPLY=""
    [[ "$start_epoch" =~ ^[0-9]+$ ]] && [ "$start_epoch" -gt 0 ] || return
    elapsed=$((current_time - start_epoch))

    if [ "$elapsed" -lt 60 ]; then
        REPLY="${elapsed}s"
    elif [ "$elapsed" -lt 3600 ]; then
        REPLY="$((elapsed / 60))m $((elapsed % 60))s"
    else
        REPLY="$((elapsed / 3600))h $(( (elapsed % 3600) / 60 ))m"
    fi
}

# ============================================================================
# GIT INFORMATION
# ============================================================================

# git called straight from $(...) (not via a function) so bash execs it in the substitution's own fork
GIT_OPTS=(-c core.fileMode=false --no-optional-locks)

# One `git status --porcelain=v2 --branch` call gives branch, upstream sync and changes.
# Sets REPLY to "branch<TAB>stash count<TAB>formatted info" (empty outside a repo)
get_git_info() {
    local porcelain
    REPLY=""
    porcelain=$(git -C "$1" "${GIT_OPTS[@]}" status --porcelain=v2 --branch --show-stash 2>/dev/null) || return

    local branch="" has_upstream="" ahead=0 behind=0 status="" added=0 removed=0 stash=0
    local line xy
    while IFS= read -r line; do
        case "$line" in
            "# branch.head "*)     branch=${line#"# branch.head "} ;;
            "# branch.upstream "*) has_upstream=1 ;;
            "# stash "*)           stash=${line#"# stash "} ;;
            "# branch.ab "*)
                read -r _ _ ahead behind <<< "$line"
                ahead=${ahead#+}; behind=${behind#-} ;;
            "1 "*|"2 "*|"u "*)
                status="*"
                xy=${line:2:2}
                [ "${xy:0:1}" = "A" ] && added=$((added + 1))
                [[ "$xy" == *D* ]] && removed=$((removed + 1)) ;;
            "? "*) added=$((added + 1)) ;;
        esac
    done <<< "$porcelain"
    [ "$branch" = "(detached)" ] && branch="detached"

    local sync_indicator=""
    if [ -n "$has_upstream" ]; then
        if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
            sync_indicator="↕${ahead}↓${behind}"
        elif [ "$ahead" -gt 0 ]; then
            sync_indicator="↑${ahead}"
        elif [ "$behind" -gt 0 ]; then
            sync_indicator="↓${behind}"
        else
            sync_indicator="="
        fi
    fi

    # Escapes stay literal (\033); the final printf %b renders them
    local git_info="⎇  ${C_CYAN}${branch}${C_RESET}"
    [ -n "$status" ] && git_info+=" ${C_YELLOW}${status}"

    if [ -n "$sync_indicator" ]; then
        git_info+=" "
        case "$sync_indicator" in
            "=")    git_info+="${C_GREEN}${sync_indicator}" ;;
            ↑*|↓*)  git_info+="${C_YELLOW}${sync_indicator}" ;;
            ↕*)     git_info+="${C_RED}${sync_indicator}" ;;
        esac
    fi

    if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
        git_info+="  "
        [ "$added" -gt 0 ] && git_info+="${C_GREEN}+${added}"
        [ "$added" -gt 0 ] && [ "$removed" -gt 0 ] && git_info+=" "
        [ "$removed" -gt 0 ] && git_info+="${C_RED}-${removed}"
    fi

    REPLY="${branch}"$'\t'"${stash}"$'\t'"${git_info}"
}

# Sets REPLY to "last commit age|✓ commits today". One `git log` replaces log -1 + rev-list --count.
# shortcut: counts at most 100 commits today, raise -n if that ever shows up
get_git_metrics() {
    local current_time="$2"

    local log ct h m sec midnight count=0 last_commit_epoch time_diff hours days minutes
    local last_commit_time="" commits_today=""
    REPLY=""
    log=$(git -C "$1" "${GIT_OPTS[@]}" log -n 100 --format=%ct 2>/dev/null) || return
    last_commit_epoch=${log%%$'\n'*}

    if [ -n "$last_commit_epoch" ]; then
        time_diff=$((current_time - last_commit_epoch))
        hours=$((time_diff / 3600))
        days=$((hours / 24))

        if [ "$days" -gt 0 ]; then
            last_commit_time="${days}d ago"
        elif [ "$hours" -gt 0 ]; then
            last_commit_time="${hours}h ago"
        else
            minutes=$((time_diff / 60))
            if [ "$minutes" -gt 0 ]; then
                last_commit_time="${minutes}m ago"
            else
                last_commit_time="just now"
            fi
        fi

        # Local midnight from the render clock
        epoch_fmt "$current_time" "+%H %M %S"; read -r h m sec <<< "$REPLY"
        midnight=$((current_time - 10#$h * 3600 - 10#$m * 60 - 10#$sec))
        while IFS= read -r ct; do
            [[ "$ct" =~ ^[0-9]+$ ]] && [ "$ct" -ge "$midnight" ] && count=$((count + 1))
        done <<< "$log"
        [ "$count" -gt 0 ] && commits_today="✓ ${count}"
    fi

    REPLY="${last_commit_time}|${commits_today}"
}

# ============================================================================
# SESSION MANAGEMENT
# ============================================================================

init_session() {
    local session_id="$1"
    local session_file="${STATE_DIR}/session-${session_id}"
    local session_metrics="${STATE_DIR}/metrics-${session_id}"
    local message_count_file="${STATE_DIR}/messages-${session_id}"

    if [ ! -f "$session_file" ]; then
        echo "$NOW" > "$session_file"
        echo "0" > "$session_metrics"
        echo "0" > "$message_count_file"
    fi
}

# Sets REPLY
format_duration() {
    local start_time="$1"
    local current_time="$2"
    local duration_seconds=$((current_time - start_time))
    local duration_minutes=$((duration_seconds / 60))
    local duration_hours=$((duration_minutes / 60))
    local remaining_minutes=$((duration_minutes % 60))

    if [ "$duration_hours" -ge 24 ]; then
        REPLY="$((duration_hours / 24))d $((duration_hours % 24))h"
    elif [ "$duration_hours" -gt 0 ]; then
        if [ "$remaining_minutes" -gt 0 ]; then
            REPLY="${duration_hours}h ${remaining_minutes}m"
        else
            REPLY="${duration_hours}h"
        fi
    elif [ "$duration_minutes" -gt 0 ]; then
        REPLY="${duration_minutes}m"
    else
        REPLY="<1m"
    fi
}

# ============================================================================
# CLAUDE USAGE (RATE LIMITS)
# ============================================================================

# Format a single rate-limit window (5h or 7d) into a colored segment in REPLY.
# Empty when the window is absent (non-subscribers / pre-first-response).
# Projects the run-out time from the burn rate since the window started; ⚠ when it beats the reset.
format_rate_window() {
    local label="$1" pct="$2" resets="$3" now="$4" window_secs="$5" eta_fmt="$6" alt_name="$7" alt_pct="$8"
    REPLY=""
    [[ ! "$pct" =~ ^[0-9]+$ ]] && return

    local color seg eta=""
    grad_color "$pct"; color=$GRAD
    if [[ "$resets" =~ ^[0-9]+$ ]] && [ "$resets" -gt "$now" ]; then
        # Skip the first 1/30 of a window (10m of 5h): too little data for a stable rate
        local elapsed=$((now - (resets - window_secs)))
        if [ "$pct" -ge 5 ] && [ "$pct" -lt 100 ] && [ "$elapsed" -ge $((window_secs / 30)) ]; then
            local runout=$((now + (100 - pct) * elapsed / pct))
            [ "$runout" -lt "$resets" ] && { epoch_fmt "$runout" "$eta_fmt"; eta=$REPLY; }
        fi
    fi

    if [ "$pct" -ge 90 ] || [ -n "$eta" ]; then
        # Keyed by window reset time: one notification per window
        local why="${pct}% used"
        [ -n "$eta" ] && why+=", projected to run out ~${eta}"
        # Same rule as the statusline suggestion: any healthy account for 7d, 20+ points freer for 5h
        [ -n "$alt_name" ] && { [ "$label" = "7d" ] || [ $((alt_pct + 20)) -le "$pct" ]; } && \
            why+=". Switch to @${alt_name} (${alt_pct}% of 5h)"
        format_duration "$now" "$resets"
        notify_once "quota-${label}-${resets}" "Claude ${label} limit" "${why}. Resets in ${REPLY}."
        seg="${C_ALERT}⚠ ${label}${C_RESET} "
    else
        seg="${label} "
    fi
    make_bar "$pct" 5; seg+="${REPLY} ${color}${pct}%${C_RESET}"
    if [[ "$resets" =~ ^[0-9]+$ ]] && [ "$resets" -gt "$now" ]; then
        format_duration "$now" "$resets"; seg+=" ${C_GRAY}(${REPLY})${C_RESET}"
    fi
    [ -n "$eta" ] && seg+=" ${C_ALERT}→ full ~${eta}${C_RESET}"

    REPLY=$seg
}

# Claude plan from the OAuth account in ~/.claude.json, e.g. "Team 5x", "Max 20x", "Pro".
# Cached in STATE_DIR and refreshed only when the account file changes.
# "account<TAB>plan" for the active account (CLAUDE_CONFIG_DIR, else ~/.claude.json), e.g.
# "naira<TAB>Team 5x"; account is the email's local part. Cached until the account file changes.
# Sets REPLY.
get_account_info() {
    local account_file="${CLAUDE_CONFIG_DIR:+${CLAUDE_CONFIG_DIR}/}.claude.json" cache_file
    [ -n "$CLAUDE_CONFIG_DIR" ] || account_file="${HOME}/.claude.json"
    REPLY=""
    [ -f "$account_file" ] || return
    cache_key "$account_file"; cache_file="${STATE_DIR}/account-${REPLY}"
    if [ ! -f "$cache_file" ] || [ "$account_file" -nt "$cache_file" ]; then
        jq -r '
            .oauthAccount // {} |
            ({claude_max: "Max", claude_pro: "Pro", claude_team: "Team", claude_enterprise: "Enterprise"}[.organizationType // ""] // "") as $plan |
            ((.userRateLimitTier // "") | (capture("max_(?<x>[0-9]+x)")? | .x) // "") as $mult |
            [(.emailAddress // "" | split("@")[0]), ([$plan, $mult] | map(select(. != "")) | join(" "))] | @tsv
        ' "$account_file" > "$cache_file" 2>/dev/null
    fi
    slurp "$cache_file"
}

# Stable per-account color so terminals on different accounts are told apart at a glance.
# Sets REPLY; djb2 over the name's code points (no cksum fork)
account_color() {
    local -a colors=("$C_CYAN" "$C_PURPLE" "$C_GREEN" "$C_YELLOW" "$C_BLUE")
    local i c h=5381
    for ((i = 0; i < ${#1}; i++)); do
        printf -v c '%d' "'${1:i:1}"
        h=$(( (h * 33 + c) % 1000003 ))
    done
    REPLY=${colors[$((h % 5))]}
}

# Each account records its last-seen limits ("5h% 5h_reset 7d% 7d_reset") so any session can
# point to the least-used other account. A window past its reset counts as 0%.
record_account_quota() {
    local dir="${HOME}/.cache/claude-statusline"
    [ -n "$1" ] && [[ "$2" =~ ^[0-9]+$ ]] && mkdir -p "$dir" 2>/dev/null || return
    printf '%s %s %s %s\n' "$2" "${3:-0}" "${4:-0}" "${5:-0}" > "$dir/quota-$1.tsv"
}

# Sets REPLY to "account 5h%" of the other account with the most 5h headroom (7d ≥90% excluded)
suggest_account() {
    local me=$1 now=$2 f name p5 r5 p7 r7 best="" best_p=101
    REPLY=""
    for f in "${HOME}/.cache/claude-statusline"/quota-*.tsv; do
        [ -f "$f" ] || continue
        name=${f##*/quota-}; name=${name%.tsv}
        [ "$name" = "$me" ] && continue
        read -r p5 r5 p7 r7 < "$f"
        [[ "$p5$r5$p7$r7" =~ ^[0-9]+$ ]] || continue
        [ "$r5" -le "$now" ] && p5=0
        [ "$r7" -le "$now" ] && p7=0
        [ "$p7" -ge 90 ] && continue
        [ "$p5" -lt "$best_p" ] && { best_p=$p5; best=$name; }
    done
    [ -n "$best" ] && REPLY="$best $best_p"
}

# Honcho memory activity for this session, written by locally patched Honcho hooks to
# ~/.honcho/status-<session_id>.json: ←recalled conclusions (last prompt) ↑captured tool events ✓saved messages
# Sets REPLY. The status file is a flat object of integers, so a regex replaces jq.
format_honcho_status() {
    local status_file="${HOME}/.honcho/status-${1}.json" json seg="🧠"
    REPLY=""
    [ -n "$1" ] && slurp "$status_file" || return
    json=$REPLY
    [[ "$json" =~ \"recalled\":[[:space:]]*([0-9]+) ]] && seg+=" ${C_PURPLE}←${BASH_REMATCH[1]}${C_RESET}"
    [[ "$json" =~ \"captured\":[[:space:]]*([0-9]+) ]] && seg+=" ${C_GRAY}↑${BASH_REMATCH[1]}${C_RESET}"
    [[ "$json" =~ \"saved\":[[:space:]]*([0-9]+) ]] && seg+=" ${C_GRAY}✓${BASH_REMATCH[1]}${C_RESET}"
    [ "$seg" = "🧠" ] && seg=""
    REPLY=$seg
}

# Prompt cache: hit ratio plus time until the cache goes cold (an idle-cost warning)
# Sets REPLY
format_prompt_cache() {
    local hit_pct="$1" expires_at="$2" warm="$3" now="$4"
    REPLY=""
    [ -z "$hit_pct" ] && [ -z "$warm" ] && return

    if [ "$warm" = "false" ] || { [[ "$expires_at" =~ ^[0-9]+$ ]] && [ "$expires_at" -le "$now" ]; }; then
        REPLY="${C_GRAY}cache${C_RESET} ${C_YELLOW}cold${C_RESET}"
        return
    fi

    local seg="${C_GRAY}cache${C_RESET}"
    [[ "$expires_at" =~ ^[0-9]+$ ]] && [ $((expires_at - now)) -le 300 ] && seg="${C_WARN}⚠ cache${C_RESET}"
    if [[ "$hit_pct" =~ ^[0-9]+$ ]]; then
        local color="${C_GREEN}"
        if [ "$hit_pct" -lt 70 ]; then
            color="${C_RED}"
        elif [ "$hit_pct" -lt 90 ]; then
            color="${C_YELLOW}"
        fi
        seg+=" ${color}${hit_pct}%${C_RESET}"
    fi

    if [[ "$expires_at" =~ ^[0-9]+$ ]]; then
        local left=$((expires_at - now)) left_color="${C_GRAY}"
        [ "$left" -le 300 ] && left_color="${C_YELLOW}"
        format_duration "$now" "$expires_at"
        seg+=" ${left_color}(${REPLY})${C_RESET}"
    fi

    REPLY=$seg
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

main() {
    # Builtin read (no `cat` fork); stdin is read here, not inside <(jq ...), where Cygwin bash
    # doesn't reliably hand it through
    local input=""
    IFS= read -r -d '' input
    # Parse all input fields in one jq call; order must match the read list below
    local current_dir model_raw model_id model total_input total_output context_size session_id
    local json_cost lines_added lines_removed
    local current_input current_cache_creation current_cache_read
    local mcp_servers_count tools_count cache_creation_tokens cache_read_tokens
    local json_tool_calls json_files_edited json_bash_commands transcript_path effort_level
    local native_ctx_pct cache_hit_pct cache_expires_at cache_warm fast_mode thinking_on session_name api_duration
    local five_pct five_resets seven_pct seven_resets
    {
        IFS= read -r current_dir; IFS= read -r model_raw; IFS= read -r model_id
        IFS= read -r total_input; IFS= read -r total_output; IFS= read -r context_size
        IFS= read -r session_id
        IFS= read -r json_cost
        IFS= read -r lines_added; IFS= read -r lines_removed
        IFS= read -r current_input; IFS= read -r current_cache_creation; IFS= read -r current_cache_read
        IFS= read -r mcp_servers_count; IFS= read -r tools_count
        IFS= read -r cache_creation_tokens; IFS= read -r cache_read_tokens
        IFS= read -r json_tool_calls; IFS= read -r json_files_edited; IFS= read -r json_bash_commands
        IFS= read -r transcript_path; IFS= read -r effort_level
        IFS= read -r native_ctx_pct; IFS= read -r cache_hit_pct; IFS= read -r cache_expires_at
        IFS= read -r cache_warm; IFS= read -r fast_mode; IFS= read -r thinking_on; IFS= read -r session_name
        IFS= read -r api_duration
        IFS= read -r five_pct; IFS= read -r five_resets; IFS= read -r seven_pct; IFS= read -r seven_resets
    } < <(jq -Rrs <<< "$input" '
        (fromjson? // {}) as $in | $in |
        def v(p; d): ((p // d) | tostring);
        v(.workspace.current_dir; ""), v(.model.display_name; ""), v(.model.id; ""),
        v(.context_window.total_input_tokens; "0"), v(.context_window.total_output_tokens; "0"),
        v(.context_window.context_window_size; "0"), v(.session_id; ""),
        v(.cost.total_cost_usd; ""),
        v(.cost.total_lines_added; "0"), v(.cost.total_lines_removed; "0"),
        v(.context_window.current_usage.input_tokens; "0"),
        v(.context_window.current_usage.cache_creation_input_tokens; "0"),
        v(.context_window.current_usage.cache_read_input_tokens; "0"),
        (.mcp_servers // [] | length), (.tools // [] | length),
        v(.context_window.cache_creation_input_tokens; "0"), v(.context_window.cache_read_input_tokens; "0"),
        v(.stats.tool_calls; ""), v(.stats.files_edited; ""), v(.stats.bash_commands; ""),
        v(.transcript_path; ""), v(.effort.level; ""),
        v(.context_window.used_percentage | numbers | floor; ""),
        v(.prompt_cache.hit_ratio | numbers | . * 100 | floor; ""), v(.prompt_cache.expires_at | numbers | floor; ""),
        (.prompt_cache.warm | if . == null then "" else tostring end), v(.fast_mode; ""), v(.thinking.enabled; ""),
        v(.session_name | strings | gsub("[\n\t]"; " "); ""),
        v(.cost.total_api_duration_ms | numbers | floor; ""),
        v(.rate_limits.five_hour.used_percentage | numbers | floor; ""), v(.rate_limits.five_hour.resets_at | numbers | floor; ""),
        v(.rate_limits.seven_day.used_percentage | numbers | floor; ""), v(.rate_limits.seven_day.resets_at | numbers | floor; "")
    ' 2>/dev/null)
    # format_model_name is a long echo chain; cache its answer per name instead of forking each render
    local model_cache
    cache_key "$model_raw"; model_cache="${STATE_DIR}/model-${REPLY}"
    if slurp "$model_cache"; then
        model=$REPLY
    else
        model=$(format_model_name "$model_raw")
        printf '%s\n' "$model" > "$model_cache"
    fi
    : "${mcp_servers_count:=0}" "${tools_count:=0}"

    # Ensure numeric values are valid
    [[ ! "$total_input" =~ ^[0-9]+$ ]] && total_input=0
    [[ ! "$total_output" =~ ^[0-9]+$ ]] && total_output=0
    [[ ! "$context_size" =~ ^[0-9]+$ ]] && context_size=0

    if [ "$mcp_servers_count" -eq 0 ] && [ -f "$HOME/.claude/.claude.json" ]; then
        mcp_servers_count=$(jq -r '.mcpServers // {} | length' "$HOME/.claude/.claude.json" 2>/dev/null || echo "0")
    fi

    # Provider
    local provider_name="${CLAUDE_PROVIDER:-Claude}"

    # Session management
    init_session "$session_id"
    local session_file="${STATE_DIR}/session-${session_id}"
    local session_metrics="${STATE_DIR}/metrics-${session_id}"
    local message_count_file="${STATE_DIR}/messages-${session_id}"

    local session_start current_time duration
    slurp "$session_file"; session_start=$REPLY
    current_time=$NOW
    format_duration "$session_start" "$current_time"; duration=$REPLY


    # Message count tracking
    local prev_total current_total message_count
    slurp "$session_metrics"; prev_total=${REPLY:-0}
    current_total=$((total_input + total_output))

    # Always read current message count
    slurp "$message_count_file"; message_count=${REPLY:-0}

    # Increment if tokens increased (including first real message after init)
    local new_message=""
    if [ "$current_total" -gt "$prev_total" ]; then
        new_message=1
        message_count=$((message_count + 1))
        echo "$message_count" > "$message_count_file"
    fi

    echo "$current_total" > "$session_metrics"

    # Session statistics
    local stats_tool_calls_file="${STATE_DIR}/stats-tools-${session_id}"
    local stats_files_file="${STATE_DIR}/stats-files-${session_id}"
    local stats_bash_file="${STATE_DIR}/stats-bash-${session_id}"

    [ ! -f "$stats_tool_calls_file" ] && echo "0" > "$stats_tool_calls_file"
    [ ! -f "$stats_files_file" ] && echo "0" > "$stats_files_file"
    [ ! -f "$stats_bash_file" ] && echo "0" > "$stats_bash_file"

    local tool_calls_count files_edited_count bash_commands_count

    tool_calls_count=$json_tool_calls files_edited_count=$json_files_edited bash_commands_count=$json_bash_commands
    [ -n "$tool_calls_count" ] || { slurp "$stats_tool_calls_file"; tool_calls_count=${REPLY:-0}; }
    [ -n "$files_edited_count" ] || { slurp "$stats_files_file"; files_edited_count=${REPLY:-0}; }
    [ -n "$bash_commands_count" ] || { slurp "$stats_bash_file"; bash_commands_count=${REPLY:-0}; }

    # Detect environment (returns "pkg_manager|language" format)
    local dev_env_result="" package_manager="" prog_lang=""
    if [ "$SHOW_DEV" = "true" ] && { [ "$SHOW_LANGUAGE" = "true" ] || [ "$SHOW_PACKAGE_MANAGER" = "true" ]; }; then
        detect_dev_environment "$current_dir"; dev_env_result=$REPLY
        [ "$SHOW_PACKAGE_MANAGER" = "true" ] && package_manager=${dev_env_result%%|*}
        [ "$SHOW_LANGUAGE" = "true" ] && prog_lang=${dev_env_result#*|}
    fi

    # Detect servers
    local running_servers=""
    # netstat + lsof per port is slow; a minute-old answer is fine for "is my dev server up"
    if [ "$SHOW_DEV" = "true" ] && [ "$SHOW_SERVERS" = "true" ]; then
        bg_cached "servers-${UID}" detect_running_servers; running_servers=$REPLY
    fi

    # Count configs (MCP, Rules, Hooks)
    local claude_md_count=0 rules_count=0 hooks_count_new=0
    [ "$SHOW_CLAUDE_MD" = "true" ] && { count_claude_md_files "$current_dir"; claude_md_count=$REPLY; }
    [ "$SHOW_RULES" = "true" ] && { count_rules "$current_dir"; rules_count=$REPLY; }
    if [ "$SHOW_HOOKS" = "true" ] || [ "$mcp_servers_count" -eq 0 ]; then
        count_config "$current_dir"
        [ "$SHOW_HOOKS" = "true" ] && hooks_count_new=$CFG_HOOKS
        [ "$mcp_servers_count" -eq 0 ] && mcp_servers_count=$CFG_MCP
    fi

    # Parse transcript for tools, agents, todos
    local transcript_result_file="${STATE_DIR}/transcript-lines-${session_id}"

    # Fixed fields first, then one "name<TAB>count" line per top completed tool
    local running_tools_count=0 tool_name tool_target tool_started
    local running_agents_count=0 agent_type agent_model agent_desc agent_started
    local todos_count=0 completed_count=0 active_todo completed_tools_output="" tname tcount
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        parse_transcript "$transcript_path" "$transcript_result_file"
        [ -f "$transcript_result_file" ] && {
            IFS= read -r running_tools_count; IFS= read -r tool_name; IFS= read -r tool_target; IFS= read -r tool_started
            IFS= read -r running_agents_count; IFS= read -r agent_type; IFS= read -r agent_model
            IFS= read -r agent_desc; IFS= read -r agent_started
            IFS= read -r todos_count; IFS= read -r completed_count; IFS= read -r active_todo
            while IFS=$'\t' read -r tname tcount; do
                if [ "$tname" = "+" ]; then
                    completed_tools_output+="${C_GRAY}+${tcount}${C_RESET} "
                elif [ -n "$tname" ]; then
                    short_tool_name "$tname"
                    completed_tools_output+="✓ ${REPLY} ×${tcount} "
                fi
            done
        } < "$transcript_result_file"
    fi
    [[ "$running_tools_count" =~ ^[0-9]+$ ]] || running_tools_count=0
    [[ "$running_agents_count" =~ ^[0-9]+$ ]] || running_agents_count=0
    [[ "$todos_count" =~ ^[0-9]+$ ]] || todos_count=0

    # Estimate cost only when Claude Code doesn't report it
    local session_cost="$json_cost"
    [ -z "$session_cost" ] && session_cost=$(calculate_cost "$provider_name" "$model_id" "$total_input" "$total_output" "$cache_creation_tokens" "$cache_read_tokens")

    # Cache efficiency

    # Calculate context window usage percentage
    local context_usage_pct=0 context_usage_color="${C_GREEN}" current_total_tokens=0
    if [ "$context_size" -gt 0 ]; then
        # Ensure numeric values
        [[ ! "$current_input" =~ ^[0-9]+$ ]] && current_input=0
        [[ ! "$current_cache_creation" =~ ^[0-9]+$ ]] && current_cache_creation=0
        [[ ! "$current_cache_read" =~ ^[0-9]+$ ]] && current_cache_read=0

        current_total_tokens=$((current_input + current_cache_creation + current_cache_read))
        if [ "$current_total_tokens" -gt 0 ]; then
            # Prefer Claude Code's own percentage; it knows about reserved/autocompact space
            if [[ "$native_ctx_pct" =~ ^[0-9]+$ ]]; then
                context_usage_pct=$native_ctx_pct
            else
                context_usage_pct=$((current_total_tokens * 100 / context_size))
            fi

            grad_color "$context_usage_pct"; context_usage_color=$GRAD
        fi
    fi

    # Messages left before the window fills, from a moving average of per-message context growth
    local growth_file="${STATE_DIR}/ctxgrowth-${session_id}" last_ctx=0 avg_growth=0 msgs_left=""
    [ -f "$growth_file" ] && read -r last_ctx avg_growth < "$growth_file"
    [[ "$last_ctx" =~ ^[0-9]+$ ]] || last_ctx=0
    [[ "$avg_growth" =~ ^[0-9]+$ ]] || avg_growth=0
    if [ "$current_total_tokens" -gt "$last_ctx" ] && [ "$last_ctx" -gt 0 ]; then
        local delta=$((current_total_tokens - last_ctx))
        if [ "$avg_growth" -eq 0 ]; then avg_growth=$delta; else avg_growth=$(( (avg_growth * 3 + delta) / 4 )); fi
    fi
    [ "$current_total_tokens" -gt 0 ] && echo "$current_total_tokens $avg_growth" > "$growth_file"
    if [ "$context_usage_pct" -ge 50 ] && [ "$avg_growth" -gt 0 ] && [ "$context_size" -gt 0 ]; then
        msgs_left=$(( context_size * (100 - context_usage_pct) / 100 / avg_growth ))
    fi

    # Git info
    local git_info git_metrics last_commit_time commits_today branch="" stash_count=0 git_out
    # Separate capture: bash 3.2 applies a `IFS=... read <<< "$(cmd)"` IFS inside cmd too
    if [ "$SHOW_GIT" = "true" ]; then
        get_git_info "$current_dir"; git_out=$REPLY
    fi
    IFS=$'\t' read -r branch stash_count git_info <<< "$git_out"
    if [ -n "$git_out" ]; then
        get_git_metrics "$current_dir" "$current_time"; git_metrics=$REPLY
    fi
    last_commit_time=${git_metrics%%|*}
    commits_today=${git_metrics#*|}

    # Directory name (either slash: Windows paths arrive with backslashes)
    local dir=$current_dir
    while [[ "$dir" == ?*[/\\] ]]; do dir=${dir%?}; done
    dir=${dir##*[/\\]}

    # Subscription info
    local subscription_info provider_section
    get_subscription_info "$provider_name"; subscription_info=$REPLY
    local provider_label="$provider_name" plan_label="" account_name=""
    if [ "$provider_name" = "Claude" ]; then
        get_account_info; IFS=$'\t' read -r account_name plan_label <<< "$REPLY"
    fi
    [ -n "$plan_label" ] && provider_label+=" ${plan_label}"
    record_account_quota "$account_name" "$five_pct" "$five_resets" "$seven_pct" "$seven_resets"
    provider_section="${C_CYAN}${provider_label}${C_RESET}"
    [ -n "$subscription_info" ] && provider_section+=" ${subscription_info}"

    # Determine cost display (integer cents avoids bc for the thresholds)
    local final_cost_display final_cost_color cost_cents
    # shellcheck disable=SC2016  # literal dollar sign
    printf -v final_cost_display '$%.2f' "${session_cost:-0}" 2>/dev/null || final_cost_display='$0.00'
    cost_cents=${final_cost_display//[^0-9]/}
    cost_cents=$((10#${cost_cents:-0}))
    RATE_IDR=0
    if [ "$CURRENCY" = "idr" ]; then
        usd_idr_rate
        if [[ "$REPLY" =~ ^[0-9]+$ ]]; then
            RATE_IDR=$REPLY
            local cost_units
            printf -v cost_units '%.4f' "${session_cost:-0}" 2>/dev/null || cost_units=0
            cost_units=${cost_units//[^0-9]/}
            fmt_idr $((10#${cost_units:-0})); final_cost_display=$REPLY
        fi
    fi
    if [ "$cost_cents" -ge 100 ]; then
        final_cost_color="${C_RED}"
    elif [ "$cost_cents" -ge 10 ]; then
        final_cost_color="${C_YELLOW}"
    else
        final_cost_color="${C_GREEN}"
    fi

    # Burn rate per hour of active API time (idle time would dilute it), after 1m of it
    local burn_rate=""
    if [[ "$api_duration" =~ ^[0-9]+$ ]] && [ "$api_duration" -ge 60000 ] && [ "$cost_cents" -gt 0 ]; then
        local cph=$((cost_cents * 3600000 / api_duration))
        fmt_cents "$cph"; burn_rate="${REPLY}/h"
    fi

    # Per-message history ("ctx% cost_cents") for sparklines: context trend and cost per message
    local hist_file="${STATE_DIR}/hist-${session_id}" ctx_spark="" cost_spark=""
    [ -n "$new_message" ] && [ -n "$session_id" ] && echo "$context_usage_pct $cost_cents" >> "$hist_file"
    if [ -f "$hist_file" ]; then
        local ctx_hist cost_hist
        { IFS= read -r ctx_hist; IFS= read -r cost_hist; } < <(tail -n 13 "$hist_file" | awk '
            { c[NR] = $1; d[NR] = $2 }
            END { s = NR > 12 ? 2 : 1
                  for (i = s; i <= NR; i++) printf "%s ", c[i]; print ""
                  for (i = (s > 1 ? s : 2); i <= NR; i++) printf "%d ", d[i] - d[i-1]; print "" }')
        sparkline "$ctx_hist" 100; ctx_spark=$REPLY
        sparkline "$cost_hist"; cost_spark=$REPLY
    fi

    local spend_today=0 spend_week=0
    cost_ledger "$session_id" "$cost_cents"; read -r spend_today spend_week <<< "$REPLY"

    # ========================================================================
    # OUTPUT GENERATION (Ultra compact 2-line layout with ┊ separators)
    # ========================================================================

    local -a out_lines=()
    local SEP=" ${C_GRAY}┊${C_RESET} "

    # --- Line 1: Model · Provider · Cost · Duration · Msg  ┊  Tokens · Ctx ---
    local l1=""
    [ "$SHOW_MODEL" = "true" ] && l1="${C_PURPLE}${model}${C_RESET}"
    if [ -n "$effort_level" ]; then
        local effort_color="${C_CYAN}"
        case "$effort_level" in
            low)        effort_color="${C_GRAY}" ;;
            high)       effort_color="${C_YELLOW}" ;;
            xhigh|max)  effort_color="${C_RED}" ;;
        esac
        # Title Case; bash 3.2 has no ${var^}
        local effort_label
        cap "$effort_level"; effort_label=$CAP
        [ "$effort_level" = "xhigh" ] && effort_label="Extra"
        l1+=" ${effort_color}◆ ${effort_label}${C_RESET}"
    fi
    [ "$fast_mode" = "true" ] && l1+=" ${C_YELLOW}↯ fast${C_RESET}"
    [ "$thinking_on" = "true" ] && l1+=" ${C_GRAY}✻${C_RESET}"

    # Account badge only once more than one account has reported limits
    local -a known_accounts=("${HOME}/.cache/claude-statusline"/quota-*.tsv)
    if [ -n "$account_name" ] && [ ${#known_accounts[@]} -gt 1 ]; then
        account_color "$account_name"; l1="${REPLY}@${account_name}${C_RESET} ${l1}"
    fi

    # Segments: "prio<TAB>separator<TAB>text"; fit_line drops high prio first on narrow terminals
    local T=$'\t' D=" · "
    local -a s1=("0${T}${T}${l1# }")
    [ "$SHOW_PROVIDER" = "true" ] && s1+=("8${T}${D}${T}${provider_section}")
    if [ "$SHOW_COST" = "true" ]; then
        s1+=("2${T}${D}${T}${final_cost_color}${final_cost_display}${C_RESET}")
        [ -n "$cost_spark" ] && s1+=("7${T} ${T}${final_cost_color}${cost_spark}${C_RESET}")
        [ -n "$burn_rate" ] && s1+=("6${T} ${T}${C_GRAY}${burn_rate}${C_RESET}")
        if [[ "$spend_today" =~ ^[0-9]+$ ]] && [ "$spend_today" -gt "$cost_cents" ]; then
            fmt_cents "$spend_today"; s1+=("5${T}${D}${T}${C_GRAY}today${C_RESET} ${C_YELLOW}${REPLY}${C_RESET}")
        fi
        if [[ "$spend_week" =~ ^[0-9]+$ ]] && [ "$spend_week" -gt "$spend_today" ]; then
            fmt_cents "$spend_week"; s1+=("8${T} ${T}${C_GRAY}wk ${REPLY}${C_RESET}")
        fi
    fi
    s1+=("9${T}${D}${T}${C_GRAY}${duration}${C_RESET}")
    [ "$SHOW_MESSAGE_COUNT" = "true" ] && s1+=("7${T}${D}${T}${C_CYAN}${message_count} msg${C_RESET}")

    if [ "$context_usage_pct" -gt 0 ]; then
        local ctx_label=""
        [ "$context_usage_pct" -ge 85 ] && ctx_label="${C_ALERT}⚠ ctx${C_RESET} "
        [ "$context_usage_pct" -ge 90 ] && notify_once "ctx-${session_id}" "Claude context ${context_usage_pct}%" \
            "${session_name:-$dir}: context almost full, auto-compact is near."
        make_bar "$context_usage_pct"
        s1+=("1${T}${SEP}${T}${ctx_label}${REPLY} ${context_usage_color}${context_usage_pct}%${C_RESET}")
        local k_used
        format_k "$current_total_tokens"; k_used=$REPLY
        format_k "$context_size"
        s1+=("5${T} ${T}${C_GRAY}(${k_used}/${REPLY})${C_RESET}")
        [ -n "$ctx_spark" ] && s1+=("6${T} ${T}${C_GRAY}${ctx_spark}${C_RESET}")
        if [ -n "$msgs_left" ]; then
            local left_color="${C_GRAY}"
            [ "$msgs_left" -le 10 ] && left_color="${C_ALERT}"
            s1+=("3${T} ${T}${left_color}~${msgs_left} msg left${C_RESET}")
        fi
    fi

    # macOS memory pressure (1 normal, 2 warn, 4 critical): a hint to move heavy work elsewhere
    if [ "$SHOW_MEM_PRESSURE" = "true" ] && [ "$_OS_FLAVOR" = "bsd" ]; then
        case "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in
            2) s1+=("1${T}${SEP}${T}${C_WARN}⚠ RAM${C_RESET}") ;;
            4) s1+=("1${T}${SEP}${T}${C_ALERT}⚠ RAM critical${C_RESET}") ;;
        esac
    fi

    local cache_section=""
    if [ "$SHOW_CACHE_EFFICIENCY" = "true" ]; then
        format_prompt_cache "$cache_hit_pct" "$cache_expires_at" "$cache_warm" "$current_time"; cache_section=$REPLY
    fi
    [ -n "$cache_section" ] && s1+=("4${T}${SEP}${T}${cache_section}")
    if [ "$SHOW_RATE_LIMIT" = "true" ]; then
        local five seven alt_name="" alt_pct=""
        if [ -n "$account_name" ]; then
            suggest_account "$account_name" "$current_time"; read -r alt_name alt_pct <<< "$REPLY"
        fi
        format_rate_window "5h" "$five_pct" "$five_resets" "$current_time" 18000 "+%H:%M" "$alt_name" "$alt_pct"; five=$REPLY
        format_rate_window "7d" "$seven_pct" "$seven_resets" "$current_time" 604800 "+%a %H:%M" "$alt_name" "$alt_pct"; seven=$REPLY
        [ -n "$five" ] && s1+=("2${T}${SEP}${T}${C_GRAY}◴${C_RESET} ${five}")
        if [ -n "$seven" ]; then
            if [ -n "$five" ]; then s1+=("3${T}${D}${T}${seven}")
            else s1+=("3${T}${SEP}${T}${C_GRAY}◴${C_RESET} ${seven}"); fi
        fi

        # Near a limit: point to the other account with the most 5h headroom
        # (for a 5h squeeze it must be at least 20 points lower to be worth switching)
        if [ -n "$alt_name" ] && { [ "${five_pct:-0}" -ge 80 ] || [ "${seven_pct:-0}" -ge 90 ] || [[ "$five" == *"→ full"* ]]; }; then
            { [ "${seven_pct:-0}" -ge 90 ] || [ $((alt_pct + 20)) -le "${five_pct:-0}" ]; } && \
                { account_color "$alt_name"; s1+=("1${T} ${T}${C_GRAY}⇄${C_RESET} ${REPLY}@${alt_name}${C_RESET} ${C_GRAY}${alt_pct}%${C_RESET}"); }
        fi
    fi

    # Gutter (4 cols) + margin; Claude Code passes the terminal width in COLUMNS
    local line_width=999
    [[ "$COLUMNS" =~ ^[0-9]+$ ]] && line_width=$((COLUMNS - 6))
    # zen: one line of essentials (prio ≤3) plus alerts; compact: first two lines
    local mode=$STATUSLINE_MODE
    [ -n "$mode" ] || { slurp "${HOME}/.cache/claude-statusline/mode"; mode=$REPLY; }
    if [ "$mode" = "zen" ]; then
        local -a zen_segs=()
        local seg
        for seg in "${s1[@]}"; do
            { [ "${seg%%$'\t'*}" -le 3 ] || [[ "$seg" == *⚠* ]]; } && zen_segs+=("$seg")
        done
        s1=("${zen_segs[@]}")
    fi
    fit_line "$line_width" "${s1[@]}"; l1=$REPLY
    out_lines+=("$l1")

    # --- Line 2: Git/folder + changes  ┊  Stats  ┊  Dev + Config ---
    local -a s2=()
    if [ -n "$session_name" ]; then
        local short_name="$session_name"
        [ ${#short_name} -gt 32 ] && short_name="${short_name:0:31}…"
        s2+=("5${T}${T}${C_PURPLE}◇ ${short_name}${C_RESET}")
    fi

    # Section 1: Git or folder + lines changed
    if [ -n "$git_info" ]; then
        s2+=("0${T}${SEP}${T}${dir} ${git_info}${C_RESET}")

        local pr_num pr_checks pr_review
        get_pr_status "$current_dir" "$branch"; IFS=$'\t' read -r pr_num pr_checks pr_review <<< "$REPLY"
        if [[ "$pr_num" =~ ^[0-9]+$ ]]; then
            local pr_seg="PR #${pr_num}"
            case "$pr_checks" in
                pass)    pr_seg+=" ${C_GREEN}✓${C_RESET}" ;;
                fail)    pr_seg+=" ${C_ALERT}✗${C_RESET}" ;;
                pending) pr_seg+=" ${C_YELLOW}◌${C_RESET}" ;;
            esac
            case "$pr_review" in
                APPROVED)          pr_seg+=" ${C_GREEN}approved${C_RESET}" ;;
                CHANGES_REQUESTED) pr_seg+=" ${C_RED}changes${C_RESET}" ;;
            esac
            s2+=("2${T}${D}${T}${C_BLUE}${pr_seg}${C_RESET}")
        fi
        [ "$SHOW_STASH" = "true" ] && [ "${stash_count:-0}" -gt 0 ] && \
            s2+=("6${T}${D}${T}${C_YELLOW}⚑ ${stash_count} stash${C_RESET}")
        [ "$SHOW_LAST_COMMIT" = "true" ] && [ -n "$last_commit_time" ] && s2+=("7${T}${D}${T}${C_GRAY}${last_commit_time}${C_RESET}")
        [ "$SHOW_COMMITS_TODAY" = "true" ] && [ -n "$commits_today" ] && s2+=("8${T}${D}${T}${C_GREEN}${commits_today} today${C_RESET}")
    else
        s2+=("0${T}${SEP}${T}◈ ${dir}")
    fi

    if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
        local changes
        if [ "$lines_added" -gt 0 ] && [ "$lines_removed" -gt 0 ]; then
            changes="${C_GREEN}+${lines_added}${C_RESET}/${C_RED}-${lines_removed}${C_RESET}"
        elif [ "$lines_added" -gt 0 ]; then
            changes="${C_GREEN}+${lines_added}${C_RESET}"
        else
            changes="${C_RED}-${lines_removed}${C_RESET}"
        fi
        s2+=("3${T}${D}${T}${changes}")
    fi

    # Section 2: Stats
    local stats_sec=""
    local stats_parts=()
    [ "$tool_calls_count" -gt 0 ] && stats_parts+=("⚙ $tool_calls_count")
    [ "$files_edited_count" -gt 0 ] && stats_parts+=("✎ $files_edited_count")
    [ "$bash_commands_count" -gt 0 ] && stats_parts+=("⚡ $bash_commands_count")
    if [ ${#stats_parts[@]} -gt 0 ]; then
        printf -v stats_sec '%s ' "${stats_parts[@]}"
        stats_sec="${C_GRAY}${stats_sec% }${C_RESET}"
    fi

    # Section 3: Dev + Config
    local dev_cfg=""
    [ -n "$prog_lang" ] && dev_cfg+="$prog_lang"
    if [ -n "$package_manager" ]; then
        [ -n "$dev_cfg" ] && dev_cfg+=" · "
        dev_cfg+="$package_manager"
    fi
    if [ -n "$running_servers" ]; then
        [ -n "$dev_cfg" ] && dev_cfg+=" · "
        dev_cfg+="${C_GREEN}${running_servers}${C_RESET}"
    fi
    local docker_count=""
    [ "$SHOW_DOCKER" = "true" ] && { get_docker_count; docker_count=$REPLY; }
    if [ -n "$docker_count" ]; then
        [ -n "$dev_cfg" ] && dev_cfg+=" · "
        dev_cfg+="${C_BLUE}🐳 ${docker_count}${C_RESET}"
    fi

    local config_parts=()
    [ "$SHOW_CLAUDE_MD" = "true" ] && [ "$claude_md_count" -gt 0 ] && config_parts+=("📝 ${claude_md_count}")
    [ "$SHOW_RULES" = "true" ] && [ "$rules_count" -gt 0 ] && config_parts+=("§ ${rules_count}")
    [ "$SHOW_MCP_SERVERS" = "true" ] && [ "$mcp_servers_count" -gt 0 ] && config_parts+=("🔌 ${mcp_servers_count}")
    [ "$SHOW_HOOKS" = "true" ] && [ "$hooks_count_new" -gt 0 ] && config_parts+=("⚓ ${hooks_count_new}")
    local honcho_section
    format_honcho_status "$session_id"; honcho_section=$REPLY
    [ -n "$honcho_section" ] && config_parts+=("$honcho_section")
    if [ ${#config_parts[@]} -gt 0 ]; then
        [ -n "$dev_cfg" ] && dev_cfg+=" · "
        local joined
        printf -v joined '%s ' "${config_parts[@]}"
        dev_cfg+=${joined% }
    fi

    # Append sections with ┊ separators
    [ "$SHOW_TOOLS" = "true" ] && [ -n "$stats_sec" ] && s2+=("9${T}${SEP}${T}${stats_sec}")
    [ -n "$dev_cfg" ] && s2+=("4${T}${SEP}${T}${dev_cfg}")

    fit_line "$line_width" "${s2[@]}"; out_lines+=("$REPLY")

    # --- Dynamic lines: Tools, Agents, Todos (only when active) ---
    if [ "$SHOW_RUNNING_TOOLS" = "true" ] && { [ "$running_tools_count" -gt 0 ] || [ -n "$completed_tools_output" ]; }; then
        local lt=""
        local spinner=${SPINNER_FRAMES[$((NOW % 4))]}

        if [ "$running_tools_count" -gt 0 ]; then
            local elapsed
            format_elapsed_time "$tool_started" "$current_time"; elapsed=$REPLY
            short_tool_name "$tool_name"
            lt+="${C_YELLOW}${spinner}${C_RESET} ${REPLY}"
            [ -n "$tool_target" ] && lt+=": ${C_CYAN}${tool_target}${C_RESET}"
            [ -n "$elapsed" ] && lt+=" ${C_GRAY}(${elapsed})${C_RESET}"
            [ "$running_tools_count" -gt 1 ] && lt+=" ${C_GRAY}+$((running_tools_count - 1)) more${C_RESET}"
        fi

        if [ -n "$completed_tools_output" ]; then
            [ "$running_tools_count" -gt 0 ] && lt+=" · "
            lt+="${C_GREEN}${completed_tools_output% }${C_RESET}"
        fi

        out_lines+=("$lt")
    fi

    if [ "$SHOW_AGENTS" = "true" ] && [ "$running_agents_count" -gt 0 ]; then
        local la="" spinner=${SPINNER_FRAMES[$((NOW % 4))]}

        local elapsed
        format_elapsed_time "$agent_started" "$current_time"; elapsed=$REPLY

        la+="${C_YELLOW}${spinner}${C_RESET} ${C_PURPLE}${agent_type}${C_RESET}"
        [ -n "$agent_model" ] && la+=" [${C_CYAN}${agent_model}${C_RESET}]"
        [ -n "$agent_desc" ] && la+=": ${agent_desc}"
        [ -n "$elapsed" ] && la+=" ${C_GRAY}(${elapsed})${C_RESET}"
        [ "$running_agents_count" -gt 1 ] && la+=" ${C_GRAY}+$((running_agents_count - 1)) more${C_RESET}"

        out_lines+=("$la")
    fi

    if [ "$SHOW_TODOS" = "true" ] && [ "$todos_count" -gt 0 ]; then
        local ltodo="▸ "
        if [ -n "$active_todo" ]; then
            ltodo+="${C_YELLOW}${active_todo}${C_RESET}"
        else
            ltodo+="${C_GRAY}No active task${C_RESET}"
        fi
        ltodo+=" ${C_GRAY}(${completed_count}/${todos_count})${C_RESET}"

        out_lines+=("$ltodo")
    fi

    # --- Render with rounded box-drawing gutter ---
    local total=${#out_lines[@]} gutter_color="${C_GRAY}"
    [ "$mode" = "zen" ] && total=1
    [ "$mode" = "compact" ] && [ "$total" -gt 2 ] && total=2
    [[ "$l1" == *⚠* ]] && gutter_color="${C_RED}"
    for ((i=0; i<total; i++)); do
        local gutter
        if [ "$total" -eq 1 ]; then
            gutter="${gutter_color}›${C_RESET}"
        elif [ $i -eq 0 ]; then
            gutter="${gutter_color}╭${C_RESET}"
        elif [ $i -eq $((total - 1)) ]; then
            gutter="${gutter_color}╰${C_RESET}"
        else
            gutter="${gutter_color}│${C_RESET}"
        fi
        printf "  %b %b\n" "$gutter" "${out_lines[$i]}"
    done
}

# `statusline-command.sh --mode zen|compact|full` switches the layout for every session
if [ "$1" = "--mode" ]; then
    case "$2" in
        zen|compact|full)
            mkdir -p "${HOME}/.cache/claude-statusline" && echo "$2" > "${HOME}/.cache/claude-statusline/mode"
            echo "statusline mode: $2"; exit 0 ;;
        *) echo "usage: $0 --mode zen|compact|full" >&2; exit 1 ;;
    esac
fi

main
exit 0