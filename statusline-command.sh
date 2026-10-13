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

readonly CONFIG_FILE="${HOME}/.claude/statusline-config.json"
readonly STATUSLINE_CONFIG_FILE="${HOME}/Scripts/claude-statusline/statusline-config.json"

# ============================================================================
# COLOR DEFINITIONS
# ============================================================================

readonly C_CYAN="\033[36m"
readonly C_BLUE="\033[34m"
readonly C_PURPLE="\033[35m"
readonly C_GREEN="\033[32m"
readonly C_YELLOW="\033[33m"
readonly C_RED="\033[31m"
readonly C_GRAY="\033[90m"
readonly C_RESET="\033[0m"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get JSON value from file with default fallback
json_file_get() {
    local file="$1"
    local path="$2"
    local default="${3:-}"
    if [ -f "$file" ]; then
        jq -r "$path // empty" "$file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Format number in k/M notation with two decimal places
format_k() {
    local num=$1

    # Handle empty or non-numeric values
    if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
        echo "0"
        return
    fi

    if [ "$num" -ge 1000000 ]; then
        # Use awk instead of bc for better reliability
        local millions
        millions=$(awk -v n="$num" 'BEGIN { printf "%.2f", n/1000000 }')
        # Remove trailing zeros and decimal point if needed
        millions=$(echo "$millions" | sed 's/\.00$//' | sed 's/\(\.[0-9]\)0$/\1/' | sed 's/\.$//')
        echo "${millions}M"
    elif [ "$num" -ge 1000 ]; then
        # Use awk instead of bc for better reliability
        local thousands
        thousands=$(awk -v n="$num" 'BEGIN { printf "%.2f", n/1000 }')
        # Remove trailing zeros and decimal point if needed
        thousands=$(echo "$thousands" | sed 's/\.00$//' | sed 's/\(\.[0-9]\)0$/\1/' | sed 's/\.$//')
        echo "${thousands}k"
    else
        echo "$num"
    fi
}

# Convert string boolean to bash boolean (0/1)
str_to_bool() {
    [[ "$1" == "true" ]] && echo 1 || echo 0
}

# --- Cross-platform date/stat helpers (BSD/macOS vs GNU/Linux) ---
case "$(uname -s)" in
    Darwin) _OS_FLAVOR="bsd" ;;
    *)      _OS_FLAVOR="gnu" ;;
esac

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
        v(.segments.agents.enabled; "true"), v(.segments.todos.enabled; "true")
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
    fi

    # Convert string booleans
    CLAUDE_STATUSLINE_LINT=$(str_to_bool "$CLAUDE_STATUSLINE_LINT")
    CLAUDE_STATUSLINE_SERVERS=$(str_to_bool "$CLAUDE_STATUSLINE_SERVERS")
}

# ============================================================================
# MODEL FORMATTING
# ============================================================================

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
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
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
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        if [ "$mode" = "thinking" ]; then
            mode="◉"
        else
            mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        fi
        echo "${tier} ${major}.${minor} ${mode}"

    # Handle Claude 3.x models with version dates (e.g., claude-3-5-sonnet-20241022)
    elif [[ "$clean_name" =~ claude-([0-9])-([0-9])-(opus|sonnet|haiku)-[0-9]{8} ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local tier="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        echo "${tier} ${major}.${minor}"

    # Handle Claude model names with suffixes (e.g., claude-opus-4-6-thinking)
    elif [[ "$clean_name" =~ claude-(opus|sonnet|haiku)-([0-9])-([0-9])-(thinking|extended) ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        echo "${tier} ${major}.${minor}"

    # Handle standard Claude model names with version dates
    elif [[ "$clean_name" =~ claude-(opus|sonnet|haiku)-([0-9])-([0-9])-[0-9]{8} ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        echo "${tier} ${major}.${minor}"

    # Handle standard Claude model names
    elif [[ "$clean_name" =~ claude-(opus|sonnet|haiku)-([0-9])\.?([0-9])?-?[0-9]* ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
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
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
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
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        display+=" Computer"
        echo "$display"
    elif [[ "$clean_name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)?-preview ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        echo "$display"

    # Handle standard Gemini 2.x models
    elif [[ "$clean_name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
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
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "Qwen3 ${size}B ${mode}"

    # Handle Qwen3 VL Plus specifically (must come before generic pattern)
    elif [[ "$clean_name" =~ qwen3-vl-plus ]]; then
        echo "Qwen3 VL Plus"

    # Handle Qwen3 specialized variants
    elif [[ "$clean_name" =~ qwen3-(coder|max)-(flash|plus|preview) ]]; then
        local type="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        type="$(echo ${type:0:1} | tr '[:lower:]' '[:upper:]')${type:1}"
        variant="$(echo ${variant:0:1} | tr '[:lower:]' '[:upper:]')${variant:1}"
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
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "Kimi K${version}.${minor} ${mode}"
    elif [[ "$clean_name" =~ kimi-k([0-9])\.([0-9]) ]]; then
        echo "Kimi K${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$clean_name" =~ kimi-k2-(thinking|instruct)(-[0-9]+)? ]]; then
        local mode="${BASH_REMATCH[1]}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "Kimi K2 ${mode}"
    elif [[ "$clean_name" =~ kimi-k2 ]]; then
        echo "Kimi K2"
    elif [[ "$clean_name" =~ kimi-k([0-9])-(thinking|instruct)(-[0-9]+)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local mode="${BASH_REMATCH[2]}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "Kimi K${version} ${mode}"

    # Handle DeepSeek V3.x models
    elif [[ "$clean_name" =~ deepseek-v([0-9])\.([0-9])-(chat|reasoner) ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local mode="${BASH_REMATCH[3]}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
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
        type="$(echo ${type:0:1} | tr '[:lower:]' '[:upper:]')${type:1}"
        echo "${type} ${version}"
    elif [[ "$clean_name" =~ ^mistral-(small|medium|large)(-latest|-[0-9]{4}-[0-9]{2})?$ ]]; then
        local size="${BASH_REMATCH[1]}"
        size="$(echo ${size:0:1} | tr '[:lower:]' '[:upper:]')${size:1}"
        echo "Mistral ${size}"
    elif [[ "$clean_name" =~ ^mistral-large-([0-9])-.* ]]; then
        echo "Mistral Large ${BASH_REMATCH[1]}"

    # Handle Llama 4.x models
    elif [[ "$clean_name" =~ ^llama-?4\.?([0-9])?-([0-9]+)b-(instruct|base)(-preview)?$ ]]; then
        local minor="${BASH_REMATCH[1]}"
        local size="${BASH_REMATCH[2]}"
        local type="${BASH_REMATCH[3]}"
        local preview="${BASH_REMATCH[4]}"
        type="$(echo ${type:0:1} | tr '[:lower:]' '[:upper:]')${type:1}"
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
        type="$(echo ${type:0:1} | tr '[:lower:]' '[:upper:]')${type:1}"
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
            variant="$(echo ${variant:0:1} | tr '[:lower:]' '[:upper:]')${variant:1}"
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
        suffix="$(echo ${suffix:0:1} | tr '[:lower:]' '[:upper:]')${suffix:1}"
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
        *"haiku-4"*|*"haiku-4.5"*)
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
        *"kimi"*"k2.5"*|*"kimi-k2.5"*)
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
        *"glm-4.5"*|*"glm-4.5-air"*)
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

get_subscription_info() {
    local provider="$1"
    local current_timestamp=$(date +%s)

    [ ! -f "$STATUSLINE_CONFIG_FILE" ] && return

    local subscription_type renewal_date renewal_day
    subscription_type=$(json_file_get "$STATUSLINE_CONFIG_FILE" ".subscriptions.\"$provider\".type" "")
    renewal_date=$(json_file_get "$STATUSLINE_CONFIG_FILE" ".subscriptions.\"$provider\".renewal_date" "")
    renewal_day=$(json_file_get "$STATUSLINE_CONFIG_FILE" ".subscriptions.\"$provider\".renewal_day" "")

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
        local color_code

        if [ "$days_remaining" -lt 0 ]; then
            printf "${C_RED}${label} OVERDUE %dd${C_RESET}" "$((days_remaining * -1))"
        elif [ "$days_remaining" -eq 0 ]; then
            printf "${C_RED}${label} TODAY${C_RESET}"
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

# Returns: "pkg1+pkg2|lang1+lang2" format
detect_dev_environment() {
    local dir="$1"
    local pkg_managers=""
    local languages=""

    # JavaScript/Node.js
    if [ -f "$dir/pnpm-lock.yaml" ]; then
        pkg_managers="pnpm"
        command -v node >/dev/null 2>&1 && languages="Node $(node --version 2>/dev/null | sed 's/v//')"
    elif [ -f "$dir/bun.lockb" ]; then
        pkg_managers="bun"
        command -v bun >/dev/null 2>&1 && languages="Bun $(bun --version 2>/dev/null)"
    elif [ -f "$dir/yarn.lock" ]; then
        pkg_managers="yarn"
        command -v node >/dev/null 2>&1 && languages="Node $(node --version 2>/dev/null | sed 's/v//')"
    elif [ -f "$dir/package-lock.json" ] || [ -f "$dir/package.json" ]; then
        pkg_managers="npm"
        command -v node >/dev/null 2>&1 && languages="Node $(node --version 2>/dev/null | sed 's/v//')"
    fi

    # PHP
    if [ -f "$dir/composer.json" ]; then
        [ -n "$pkg_managers" ] && pkg_managers+="+composer" || pkg_managers="composer"
        if command -v php >/dev/null 2>&1; then
            local php_ver="PHP $(php --version 2>/dev/null | head -1 | awk '{print $2}')"
            [ -n "$languages" ] && languages+="+$php_ver" || languages="$php_ver"
        fi
    fi

    # Ruby
    if [ -f "$dir/Gemfile" ]; then
        [ -n "$pkg_managers" ] && pkg_managers+="+gem" || pkg_managers="gem"
        if command -v ruby >/dev/null 2>&1; then
            local ruby_ver="Ruby $(ruby --version 2>/dev/null | awk '{print $2}')"
            [ -n "$languages" ] && languages+="+$ruby_ver" || languages="$ruby_ver"
        fi
    fi

    # Python
    if [ -f "$dir/requirements.txt" ] || [ -f "$dir/Pipfile" ] || [ -f "$dir/pyproject.toml" ]; then
        [ -n "$pkg_managers" ] && pkg_managers+="+pip" || pkg_managers="pip"
        if command -v python3 >/dev/null 2>&1; then
            local py_ver="Python $(python3 --version 2>/dev/null | awk '{print $2}')"
            [ -n "$languages" ] && languages+="+$py_ver" || languages="$py_ver"
        elif command -v python >/dev/null 2>&1; then
            local py_ver="Python $(python --version 2>/dev/null | awk '{print $2}')"
            [ -n "$languages" ] && languages+="+$py_ver" || languages="$py_ver"
        fi
    fi

    # Go
    if [ -f "$dir/go.mod" ]; then
        [ -n "$pkg_managers" ] && pkg_managers+="+go" || pkg_managers="go"
        if command -v go >/dev/null 2>&1; then
            local go_ver="Go $(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')"
            [ -n "$languages" ] && languages+="+$go_ver" || languages="$go_ver"
        fi
    fi

    # Rust
    if [ -f "$dir/Cargo.toml" ]; then
        [ -n "$pkg_managers" ] && pkg_managers+="+cargo" || pkg_managers="cargo"
        if command -v rustc >/dev/null 2>&1; then
            local rust_ver="Rust $(rustc --version 2>/dev/null | awk '{print $2}')"
            [ -n "$languages" ] && languages+="+$rust_ver" || languages="$rust_ver"
        fi
    fi

    echo "${pkg_managers}|${languages}"
}

# ============================================================================
# SERVER DETECTION
# ============================================================================

detect_running_servers() {
    local server_detection
    server_detection=$(json_file_get "$STATUSLINE_CONFIG_FILE" '.features.server_detection' "true")
    [ "$server_detection" != "true" ] && return

    local -a listened_ports ignored_ports active_servers

    if [ -f "$STATUSLINE_CONFIG_FILE" ]; then
        # Read ports into arrays (compatible with bash 3.x and zsh)
        while IFS= read -r port; do
            [ -n "$port" ] && listened_ports+=("$port")
        done < <(jq -r '.features.listened_ports[]? // empty' "$STATUSLINE_CONFIG_FILE" 2>/dev/null)

        while IFS= read -r port; do
            [ -n "$port" ] && ignored_ports+=("$port")
        done < <(jq -r '.features.ignored_ports[]? // empty' "$STATUSLINE_CONFIG_FILE" 2>/dev/null)
    fi

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
                    process_name=$(lsof -iTCP:$port -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR==2 {print $1}')
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

count_claude_md_files() {
    local cwd="$1"
    local count=0
    local home_dir="$HOME"
    local claude_dir="${home_dir}/.claude"

    # User scope
    [ -f "${claude_dir}/CLAUDE.md" ] && ((count++))

    # Project scope
    if [ -n "$cwd" ]; then
        [ -f "${cwd}/CLAUDE.md" ] && ((count++))
        [ -f "${cwd}/CLAUDE.local.md" ] && ((count++))
        [ -f "${cwd}/.claude/CLAUDE.md" ] && ((count++))
        [ -f "${cwd}/.claude/CLAUDE.local.md" ] && ((count++))
    fi

    echo "$count"
}

count_rules_in_dir() {
    local dir="$1"
    local count=0

    if [ -d "$dir" ]; then
        count=$(find "$dir" -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    fi

    echo "$count"
}

count_rules() {
    local cwd="$1"
    local count=0
    local home_dir="$HOME"
    local claude_dir="${home_dir}/.claude"

    # User scope: ~/.claude/rules/*.md
    count=$((count + $(count_rules_in_dir "${claude_dir}/rules")))

    # Project scope: {cwd}/.claude/rules/*.md
    if [ -n "$cwd" ]; then
        count=$((count + $(count_rules_in_dir "${cwd}/.claude/rules")))
    fi

    echo "$count"
}

count_mcp_servers() {
    local cwd="$1"
    local count=0
    local home_dir="$HOME"
    local claude_dir="${home_dir}/.claude"

    # User settings: ~/.claude/settings.json
    if [ -f "${claude_dir}/settings.json" ]; then
        local user_count
        user_count=$(jq -r '.mcpServers // {} | keys | length' "${claude_dir}/settings.json" 2>/dev/null || echo "0")
        count=$((count + user_count))
    fi

    # User claude.json: ~/.claude.json
    if [ -f "${home_dir}/.claude.json" ]; then
        local json_count
        json_count=$(jq -r '.mcpServers // {} | keys | length' "${home_dir}/.claude.json" 2>/dev/null || echo "0")
        count=$((count + json_count))
    fi

    # Project scope
    if [ -n "$cwd" ]; then
        # {cwd}/.mcp.json
        if [ -f "${cwd}/.mcp.json" ]; then
            local proj_count
            proj_count=$(jq -r '.mcpServers // {} | keys | length' "${cwd}/.mcp.json" 2>/dev/null || echo "0")
            count=$((count + proj_count))
        fi

        # {cwd}/.claude/settings.json
        if [ -f "${cwd}/.claude/settings.json" ]; then
            local proj_settings_count
            proj_settings_count=$(jq -r '.mcpServers // {} | keys | length' "${cwd}/.claude/settings.json" 2>/dev/null || echo "0")
            count=$((count + proj_settings_count))
        fi

        # {cwd}/.claude/settings.local.json
        if [ -f "${cwd}/.claude/settings.local.json" ]; then
            local local_count
            local_count=$(jq -r '.mcpServers // {} | keys | length' "${cwd}/.claude/settings.local.json" 2>/dev/null || echo "0")
            count=$((count + local_count))
        fi
    fi

    echo "$count"
}

count_hooks() {
    local cwd="$1"
    local count=0
    local home_dir="$HOME"
    local claude_dir="${home_dir}/.claude"

    # User settings: ~/.claude/settings.json
    if [ -f "${claude_dir}/settings.json" ]; then
        local user_count
        user_count=$(jq -r '.hooks // {} | keys | length' "${claude_dir}/settings.json" 2>/dev/null || echo "0")
        count=$((count + user_count))
    fi

    # Project scope
    if [ -n "$cwd" ]; then
        # {cwd}/.claude/settings.json
        if [ -f "${cwd}/.claude/settings.json" ]; then
            local proj_count
            proj_count=$(jq -r '.hooks // {} | keys | length' "${cwd}/.claude/settings.json" 2>/dev/null || echo "0")
            count=$((count + proj_count))
        fi

        # {cwd}/.claude/settings.local.json
        if [ -f "${cwd}/.claude/settings.local.json" ]; then
            local local_count
            local_count=$(jq -r '.hooks // {} | keys | length' "${cwd}/.claude/settings.local.json" 2>/dev/null || echo "0")
            count=$((count + local_count))
        fi
    fi

    echo "$count"
}

# ============================================================================
# TRANSCRIPT PARSING (Tools, Agents, Todos)
# ============================================================================

# Spinner frames for running tools
readonly SPINNER_FRAMES=("◐" "◓" "◑" "◒")

get_spinner_frame() {
    local index=$(( $(date +%s) % 4 ))
    echo "${SPINNER_FRAMES[$index]}"
}

parse_transcript() {
    local transcript_path="$1"
    local result_file="$2"

    [ ! -f "$transcript_path" ] && return

    # Tool outputs are most of a transcript's bytes, so tool_result IDs are pulled with a
    # regex instead of parsing JSON; only tool_use lines get parsed. fromjson? skips a
    # partially-written last line. Background agents get an immediate "Async agent launched"
    # tool_result and only finish once a <task-notification> names their tool-use-id.
    _tsearch -F '"type":"tool_use"' "$transcript_path" | jq -nRc \
        --rawfile result_ids <(_tsearch -o '"tool_use_id":"[^"]*"' "$transcript_path") \
        --rawfile async_lines <(_tsearch -F 'Async agent launched' "$transcript_path") \
        --rawfile notified_ids <(_tsearch -o '<tool-use-id>[^<]*</tool-use-id>' "$transcript_path") '
        def is_agent: .name == "Agent" or .name == "Task";
        def text: if type == "array" then map(.text? // "") | join("") else tostring end;
        def id_set(s; re): [s | scan(re)[0] | {key: ., value: true}] | from_entries;
        id_set($result_ids; "\"tool_use_id\":\"([^\"]+)\"") as $results
        | id_set($notified_ids; "<tool-use-id>([^<]+)</tool-use-id>") as $notified
        | ([$async_lines | split("\n")[] | fromjson? | .message.content[]?
            | select(.type? == "tool_result" and (.content | text | startswith("Async agent launched")))
            | {key: .tool_use_id, value: true}] | from_entries) as $async
        | [inputs | fromjson? | select(.message.content? | type == "array") |
            .timestamp as $ts | .message.content[] | select(.type == "tool_use") |
            {id, name, input, timestamp: $ts} | (.id // "") as $id
            | .done = (if $async[$id] then $notified[$id] // false else $results[$id] // false end)] as $uses
        | {
            running_tools: [$uses[] | select((.done | not) and .name != "TodoWrite" and (is_agent | not)) | del(.done)],
            running_agents: [$uses[] | select(is_agent and (.done | not)) | del(.done)],
            todos: ([$uses[] | select(.name == "TodoWrite")] | last | .input.todos // []),
            completed_counts: ([$uses[] | select(.done and .name != "TodoWrite" and (is_agent | not))]
                | group_by(.name) | map({name: .[0].name, count: length}) | sort_by(-.count))
          }
    ' > "$result_file" 2>/dev/null
}

# ripgrep is ~20x faster than BSD grep on large transcripts
_tsearch() {
    if command -v rg >/dev/null 2>&1; then
        rg --no-filename --no-line-number "$@" 2>/dev/null
    else
        LC_ALL=C grep -h "$@" 2>/dev/null
    fi
    return 0
}

# mcp__plugin_honcho_honcho__get_config -> honcho:get_config
short_tool_name() {
    local name="$1"
    if [[ "$name" != mcp__* ]]; then
        printf '%s' "$name"
        return
    fi
    name=${name#mcp__}
    local server=${name%%__*} tool=${name#*__}
    server=${server#plugin_}
    server=${server#claude_ai_}
    [[ "$server" == *_* && "${server%%_*}" == "${server#*_}" ]] && server=${server%%_*}
    printf '%s:%s' "$server" "$tool"
}

# 10-cell bar for a 0-100 percentage
make_bar() {
    local pct=$1 filled i bar=""
    [ "$pct" -gt 100 ] && pct=100
    filled=$(( (pct + 5) / 10 ))
    for ((i = 0; i < 10; i++)); do
        if [ "$i" -lt "$filled" ]; then bar+="▰"; else bar+="▱"; fi
    done
    printf '%s' "$bar"
}

format_tool_target() {
    local name="$1"
    local input="$2"

    case "$name" in
        Read|Write|Edit)
            local file_path
            file_path=$(echo "$input" | jq -r '.file_path // .path // empty' 2>/dev/null)
            if [ -n "$file_path" ]; then
                basename "$file_path"
            fi
            ;;
        Glob)
            echo "$input" | jq -r '.pattern // empty' 2>/dev/null
            ;;
        Grep)
            echo "$input" | jq -r '.pattern // empty' 2>/dev/null | head -c 20
            ;;
        Bash)
            local cmd
            cmd=$(echo "$input" | jq -r '.command // empty' 2>/dev/null)
            echo "${cmd:0:25}..."
            ;;
        Task)
            echo "$input" | jq -r '.description // empty' 2>/dev/null
            ;;
    esac
}

format_elapsed_time() {
    local start_timestamp="$1"
    local current_time="$2"

    # Parse ISO timestamp to epoch
    local start_epoch
    # Transcript timestamps are UTC ("...Z"); parse them as UTC, not local time
    start_epoch=$(TZ=UTC _date_to_epoch "%Y-%m-%dT%H:%M:%S" "${start_timestamp%%.*}" || echo "0")
    [ -z "$start_epoch" ] && start_epoch="0"

    if [ "$start_epoch" -eq 0 ]; then
        echo ""
        return
    fi

    local elapsed=$((current_time - start_epoch))

    if [ "$elapsed" -lt 60 ]; then
        echo "${elapsed}s"
    elif [ "$elapsed" -lt 3600 ]; then
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        echo "${mins}m ${secs}s"
    else
        local hours=$((elapsed / 3600))
        local mins=$(( (elapsed % 3600) / 60 ))
        echo "${hours}h ${mins}m"
    fi
}

# ============================================================================
# GIT INFORMATION
# ============================================================================

_git() {
    git -C "$GIT_DIR_ARG" -c core.fileMode=false --no-optional-locks "$@" 2>/dev/null
}

# One `git status --porcelain=v2 --branch` call gives branch, upstream sync and changes
get_git_info() {
    local GIT_DIR_ARG="$1"
    local porcelain
    porcelain=$(_git status --porcelain=v2 --branch) || return

    local branch="" has_upstream="" ahead=0 behind=0 status="" added=0 removed=0
    local line xy
    while IFS= read -r line; do
        case "$line" in
            "# branch.head "*)     branch=${line#"# branch.head "} ;;
            "# branch.upstream "*) has_upstream=1 ;;
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

    local git_info
    git_info=$(printf "⎇  ${C_CYAN}%s${C_RESET}" "$branch")
    [ -n "$status" ] && git_info+=$(printf " ${C_YELLOW}%s" "$status")

    if [ -n "$sync_indicator" ]; then
        git_info+=" "
        case "$sync_indicator" in
            "=")    git_info+=$(printf "${C_GREEN}%s" "$sync_indicator") ;;
            ↑*|↓*)  git_info+=$(printf "${C_YELLOW}%s" "$sync_indicator") ;;
            ↕*)     git_info+=$(printf "${C_RED}%s" "$sync_indicator") ;;
        esac
    fi

    if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
        git_info+="  "
        [ "$added" -gt 0 ] && git_info+=$(printf "${C_GREEN}+%s" "$added")
        [ "$added" -gt 0 ] && [ "$removed" -gt 0 ] && git_info+=" "
        [ "$removed" -gt 0 ] && git_info+=$(printf "${C_RED}-%s" "$removed")
    fi

    echo "$git_info"
}

get_git_metrics() {
    local GIT_DIR_ARG="$1"
    local current_time="$2"

    local last_commit_epoch time_diff hours days minutes last_commit_time="" commits_today=""
    last_commit_epoch=$(_git log -1 --format=%ct) || return

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

        local commit_count
        commit_count=$(_git rev-list --count --since=midnight HEAD)
        [ "${commit_count:-0}" -gt 0 ] && commits_today="✓ ${commit_count}"
    fi

    echo "${last_commit_time}|${commits_today}"
}

# ============================================================================
# SESSION MANAGEMENT
# ============================================================================

init_session() {
    local session_id="$1"
    local session_file="/tmp/claude-session-${session_id}"
    local session_metrics="/tmp/claude-metrics-${session_id}"
    local message_count_file="/tmp/claude-messages-${session_id}"

    if [ ! -f "$session_file" ]; then
        date +%s > "$session_file"
        echo "0" > "$session_metrics"
        echo "0" > "$message_count_file"
    fi
}

format_duration() {
    local start_time="$1"
    local current_time="$2"
    local duration_seconds=$((current_time - start_time))
    local duration_minutes=$((duration_seconds / 60))
    local duration_hours=$((duration_minutes / 60))
    local remaining_minutes=$((duration_minutes % 60))

    if [ "$duration_hours" -ge 24 ]; then
        echo "$((duration_hours / 24))d $((duration_hours % 24))h"
    elif [ "$duration_hours" -gt 0 ]; then
        if [ "$remaining_minutes" -gt 0 ]; then
            echo "${duration_hours}h ${remaining_minutes}m"
        else
            echo "${duration_hours}h"
        fi
    elif [ "$duration_minutes" -gt 0 ]; then
        echo "${duration_minutes}m"
    else
        echo "<1m"
    fi
}

# ============================================================================
# CLAUDE USAGE (RATE LIMITS)
# ============================================================================

# Format a single rate-limit window (5h or 7d) into a colored segment.
# Echoes nothing when the window is absent (non-subscribers / pre-first-response).
format_rate_window() {
    local label="$1" path="$2" input="$3" now="$4"

    local pct
    pct=$(echo "$input" | jq -r "${path}.used_percentage // empty" 2>/dev/null)
    [ -z "$pct" ] && return
    pct=${pct%.*}
    [[ ! "$pct" =~ ^[0-9]+$ ]] && return

    local color="${C_GREEN}"
    if [ "$pct" -ge 90 ]; then
        color="${C_RED}"
    elif [ "$pct" -ge 70 ]; then
        color="${C_YELLOW}"
    fi

    local seg="${label} ${color}${pct}%${C_RESET}"

    local resets
    resets=$(echo "$input" | jq -r "${path}.resets_at // empty" 2>/dev/null)
    if [[ "$resets" =~ ^[0-9]+$ ]] && [ "$resets" -gt "$now" ]; then
        seg+=" ${C_GRAY}($(format_duration "$now" "$resets"))${C_RESET}"
    fi

    printf '%s' "$seg"
}

# Build the Claude usage segment from .rate_limits. Echoes nothing when no
# window data is present, so the caller can append it unconditionally.
format_rate_limits() {
    local input="$1" now="$2"

    local five seven out=""
    five=$(format_rate_window "5h" ".rate_limits.five_hour" "$input" "$now")
    seven=$(format_rate_window "7d" ".rate_limits.seven_day" "$input" "$now")

    [ -n "$five" ] && out+="$five"
    if [ -n "$seven" ]; then
        [ -n "$out" ] && out+=" · "
        out+="$seven"
    fi

    [ -z "$out" ] && return
    printf '%s %s' "${C_GRAY}◴${C_RESET}" "$out"
}

# Claude plan from the OAuth account in ~/.claude.json, e.g. "Team 5x", "Max 20x", "Pro".
# Cached in /tmp and refreshed only when ~/.claude.json changes.
get_plan_label() {
    local account_file="${HOME}/.claude.json" cache_file="/tmp/claude-statusline-plan"
    [ -f "$account_file" ] || return
    if [ ! -f "$cache_file" ] || [ "$account_file" -nt "$cache_file" ]; then
        jq -r '
            .oauthAccount // {} |
            ({claude_max: "Max", claude_pro: "Pro", claude_team: "Team", claude_enterprise: "Enterprise"}[.organizationType // ""] // "") as $plan |
            ((.userRateLimitTier // "") | capture("max_(?<x>[0-9]+x)")?.x // "") as $mult |
            [$plan, $mult] | map(select(. != "")) | join(" ")
        ' "$account_file" > "$cache_file" 2>/dev/null
    fi
    cat "$cache_file" 2>/dev/null
}

# Prompt cache: hit ratio plus time until the cache goes cold (an idle-cost warning)
format_prompt_cache() {
    local hit_pct="$1" expires_at="$2" warm="$3" now="$4"
    [ -z "$hit_pct" ] && [ -z "$warm" ] && return

    if [ "$warm" = "false" ] || { [[ "$expires_at" =~ ^[0-9]+$ ]] && [ "$expires_at" -le "$now" ]; }; then
        printf '%s' "${C_GRAY}cache${C_RESET} ${C_YELLOW}cold${C_RESET}"
        return
    fi

    local seg="${C_GRAY}cache${C_RESET}"
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
        seg+=" ${left_color}($(format_duration "$now" "$expires_at"))${C_RESET}"
    fi

    printf '%s' "$seg"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

main() {
    # Load configuration
    load_config

    # Read input
    local input
    input=$(cat)

    # Parse all input fields in one jq call; order must match the read list below
    local current_dir model_raw model_id model total_input total_output context_size session_id
    local json_cost json_duration lines_added lines_removed
    local current_input current_cache_creation current_cache_read
    local mcp_servers_count tools_count cache_creation_tokens cache_read_tokens
    local json_tool_calls json_files_edited json_bash_commands transcript_path effort_level
    local native_ctx_pct cache_hit_pct cache_expires_at cache_warm fast_mode thinking_on session_name
    {
        IFS= read -r current_dir; IFS= read -r model_raw; IFS= read -r model_id
        IFS= read -r total_input; IFS= read -r total_output; IFS= read -r context_size
        IFS= read -r session_id
        IFS= read -r json_cost; IFS= read -r json_duration
        IFS= read -r lines_added; IFS= read -r lines_removed
        IFS= read -r current_input; IFS= read -r current_cache_creation; IFS= read -r current_cache_read
        IFS= read -r mcp_servers_count; IFS= read -r tools_count
        IFS= read -r cache_creation_tokens; IFS= read -r cache_read_tokens
        IFS= read -r json_tool_calls; IFS= read -r json_files_edited; IFS= read -r json_bash_commands
        IFS= read -r transcript_path; IFS= read -r effort_level
        IFS= read -r native_ctx_pct; IFS= read -r cache_hit_pct; IFS= read -r cache_expires_at
        IFS= read -r cache_warm; IFS= read -r fast_mode; IFS= read -r thinking_on; IFS= read -r session_name
    } < <(printf '%s' "$input" | jq -Rrs '
        (fromjson? // {}) as $in | $in |
        def v(p; d): ((p // d) | tostring);
        v(.workspace.current_dir; ""), v(.model.display_name; ""), v(.model.id; ""),
        v(.context_window.total_input_tokens; "0"), v(.context_window.total_output_tokens; "0"),
        v(.context_window.context_window_size; "0"), v(.session_id; ""),
        v(.cost.total_cost_usd; ""), v(.cost.total_duration_ms; ""),
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
        v(.session_name | strings | gsub("[\n\t]"; " "); "")
    ' 2>/dev/null)
    model=$(format_model_name "$model_raw")
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
    local session_file="/tmp/claude-session-${session_id}"
    local session_metrics="/tmp/claude-metrics-${session_id}"
    local message_count_file="/tmp/claude-messages-${session_id}"

    local session_start current_time duration
    session_start=$(cat "$session_file")
    current_time=$(date +%s)
    duration=$(format_duration "$session_start" "$current_time")

    # Claude usage (5h / 7d rate limits) — only present for Pro/Max subscribers
    local rate_limit_section=""
    [ "$SHOW_RATE_LIMIT" = "true" ] && rate_limit_section=$(format_rate_limits "$input" "$current_time")

    # Message count tracking
    local prev_total current_total message_count
    prev_total=$(cat "$session_metrics" 2>/dev/null || echo "0")
    current_total=$((total_input + total_output))

    # Always read current message count
    message_count=$(cat "$message_count_file" 2>/dev/null || echo "0")

    # Increment if tokens increased (including first real message after init)
    if [ "$current_total" -gt "$prev_total" ]; then
        message_count=$((message_count + 1))
        echo "$message_count" > "$message_count_file"
    fi

    echo "$current_total" > "$session_metrics"

    # Session statistics
    local stats_tool_calls_file="/tmp/claude-stats-tools-${session_id}"
    local stats_files_file="/tmp/claude-stats-files-${session_id}"
    local stats_bash_file="/tmp/claude-stats-bash-${session_id}"

    [ ! -f "$stats_tool_calls_file" ] && echo "0" > "$stats_tool_calls_file"
    [ ! -f "$stats_files_file" ] && echo "0" > "$stats_files_file"
    [ ! -f "$stats_bash_file" ] && echo "0" > "$stats_bash_file"

    local tool_calls_count files_edited_count bash_commands_count

    tool_calls_count=${json_tool_calls:-$(cat "$stats_tool_calls_file" 2>/dev/null || echo "0")}
    files_edited_count=${json_files_edited:-$(cat "$stats_files_file" 2>/dev/null || echo "0")}
    bash_commands_count=${json_bash_commands:-$(cat "$stats_bash_file" 2>/dev/null || echo "0")}

    # Detect environment (returns "pkg_manager|language" format)
    local dev_env_result package_manager prog_lang
    dev_env_result=$(detect_dev_environment "$current_dir")
    package_manager=$(echo "$dev_env_result" | cut -d'|' -f1)
    prog_lang=$(echo "$dev_env_result" | cut -d'|' -f2)

    # Detect servers
    local running_servers
    running_servers=$(detect_running_servers)

    # Count configs (MCP, Rules, Hooks)
    local claude_md_count rules_count mcp_count_new hooks_count_new
    claude_md_count=$(count_claude_md_files "$current_dir")
    rules_count=$(count_rules "$current_dir")
    mcp_count_new=$(count_mcp_servers "$current_dir")
    hooks_count_new=$(count_hooks "$current_dir")

    # Use counted MCP if JSON count is 0
    [ "$mcp_servers_count" -eq 0 ] && mcp_servers_count="$mcp_count_new"

    # Parse transcript for tools, agents, todos
    local transcript_result_file
    transcript_result_file="/tmp/claude-transcript-result-${session_id}"

    local running_tools_json running_agents_json todos_json completed_counts_json
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        parse_transcript "$transcript_path" "$transcript_result_file"
        if [ -f "$transcript_result_file" ]; then
            { IFS= read -r running_tools_json; IFS= read -r running_agents_json
              IFS= read -r todos_json; IFS= read -r completed_counts_json; } < <(
                jq -c '.running_tools // [], .running_agents // [], .todos // [], .completed_counts // []' "$transcript_result_file" 2>/dev/null)
        fi
    fi

    # Default to empty arrays if not set
    [ -z "$running_tools_json" ] && running_tools_json="[]"
    [ -z "$running_agents_json" ] && running_agents_json="[]"
    [ -z "$todos_json" ] && todos_json="[]"
    [ -z "$completed_counts_json" ] && completed_counts_json="[]"

    # Estimate cost only when Claude Code doesn't report it
    local session_cost="$json_cost"
    [ -z "$session_cost" ] && session_cost=$(calculate_cost "$provider_name" "$model_id" "$total_input" "$total_output" "$cache_creation_tokens" "$cache_read_tokens")

    # Cache efficiency
    local cache_total cache_efficiency=0
    cache_total=$((cache_creation_tokens + cache_read_tokens))
    [ "$cache_total" -gt 0 ] && [ "$total_input" -gt 0 ] && cache_efficiency=$((cache_read_tokens * 100 / total_input))

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

            # Color based on usage
            if [ "$context_usage_pct" -ge 90 ]; then
                context_usage_color="${C_RED}"
            elif [ "$context_usage_pct" -ge 70 ]; then
                context_usage_color="${C_YELLOW}"
            else
                context_usage_color="${C_GREEN}"
            fi
        fi
    fi

    # Git info
    local git_info git_metrics last_commit_time commits_today
    git_info=$(get_git_info "$current_dir")
    git_metrics=$(get_git_metrics "$current_dir" "$current_time")
    last_commit_time=$(echo "$git_metrics" | cut -d'|' -f1)
    commits_today=$(echo "$git_metrics" | cut -d'|' -f2)

    # Directory name
    local dir
    dir=$(basename "$current_dir")

    # Subscription info
    local subscription_info provider_section
    subscription_info=$(get_subscription_info "$provider_name")
    local provider_label="$provider_name" plan_label=""
    [ "$provider_name" = "Claude" ] && plan_label=$(get_plan_label)
    [ -n "$plan_label" ] && provider_label+=" ${plan_label}"
    if [ -n "$subscription_info" ]; then
        provider_section=$(printf "${C_CYAN}%s${C_RESET} %s" "$provider_label" "$subscription_info")
    else
        provider_section=$(printf "${C_CYAN}%s${C_RESET}" "$provider_label")
    fi

    # Determine cost display (integer cents avoids bc for the thresholds)
    local final_cost_display final_cost_color cost_cents
    final_cost_display=$(printf '$%.2f' "${session_cost:-0}" 2>/dev/null) || final_cost_display='$0.00'
    cost_cents=${final_cost_display//[^0-9]/}
    cost_cents=$((10#${cost_cents:-0}))
    if [ "$cost_cents" -ge 100 ]; then
        final_cost_color="${C_RED}"
    elif [ "$cost_cents" -ge 10 ]; then
        final_cost_color="${C_YELLOW}"
    else
        final_cost_color="${C_GREEN}"
    fi

    # ========================================================================
    # OUTPUT GENERATION (Ultra compact 2-line layout with ┊ separators)
    # ========================================================================

    local -a out_lines=()
    local -a out_types=()
    local SEP=" ${C_GRAY}┊${C_RESET} "

    # --- Line 1: Model · Provider · Cost · Duration · Msg  ┊  Tokens · Ctx ---
    local l1="${C_PURPLE}${model}${C_RESET}"
    if [ -n "$effort_level" ]; then
        local effort_color="${C_CYAN}"
        case "$effort_level" in
            low)        effort_color="${C_GRAY}" ;;
            high)       effort_color="${C_YELLOW}" ;;
            xhigh|max)  effort_color="${C_RED}" ;;
        esac
        # Title Case; bash 3.2 has no ${var^}
        local effort_label
        effort_label="$(printf '%s' "${effort_level:0:1}" | tr '[:lower:]' '[:upper:]')${effort_level:1}"
        [ "$effort_level" = "xhigh" ] && effort_label="Extra"
        l1+=" ${effort_color}◆ ${effort_label}${C_RESET}"
    fi
    [ "$fast_mode" = "true" ] && l1+=" ${C_YELLOW}↯ fast${C_RESET}"
    [ "$thinking_on" = "true" ] && l1+=" ${C_GRAY}✻${C_RESET}"
    l1+=" · ${provider_section}"
    l1+=" · ${final_cost_color}${final_cost_display}${C_RESET}"
    l1+=" · ${C_GRAY}${duration}${C_RESET}"
    l1+=" · ${C_CYAN}${message_count} msg${C_RESET}"

    local tok_sec=""
    if [ "$context_usage_pct" -gt 0 ]; then
        tok_sec+="${context_usage_color}$(make_bar "$context_usage_pct") ${context_usage_pct}%${C_RESET}"
        tok_sec+=" ${C_GRAY}($(format_k "$current_total_tokens")/$(format_k "$context_size"))${C_RESET}"
    fi
    [ -n "$tok_sec" ] && l1+="${SEP}${tok_sec}"

    local cache_section
    cache_section=$(format_prompt_cache "$cache_hit_pct" "$cache_expires_at" "$cache_warm" "$current_time")
    [ -n "$cache_section" ] && l1+="${SEP}${cache_section}"

    [ -n "$rate_limit_section" ] && l1+="${SEP}${rate_limit_section}"

    out_lines+=("$l1"); out_types+=("n")

    # --- Line 2: Git/folder + changes  ┊  Stats  ┊  Dev + Config ---
    local l2=""
    if [ -n "$session_name" ]; then
        local short_name="$session_name"
        [ ${#short_name} -gt 32 ] && short_name="${short_name:0:31}…"
        l2+="${C_PURPLE}◇ ${short_name}${C_RESET}${SEP}"
    fi

    # Section 1: Git or folder + lines changed
    if [ -n "$git_info" ]; then
        l2+="${dir} ${git_info}"
        [ -n "$last_commit_time" ] && l2+=" · ${C_GRAY}${last_commit_time}${C_RESET}"
        [ -n "$commits_today" ] && l2+=" · ${C_GREEN}${commits_today} today${C_RESET}"
    else
        l2+="◈ ${dir}"
    fi

    if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
        l2+=" · "
        if [ "$lines_added" -gt 0 ] && [ "$lines_removed" -gt 0 ]; then
            l2+="${C_GREEN}+${lines_added}${C_RESET}/${C_RED}-${lines_removed}${C_RESET}"
        elif [ "$lines_added" -gt 0 ]; then
            l2+="${C_GREEN}+${lines_added}${C_RESET}"
        else
            l2+="${C_RED}-${lines_removed}${C_RESET}"
        fi
    fi

    # Section 2: Stats
    local stats_sec=""
    local stats_parts=()
    [ "$tool_calls_count" -gt 0 ] && stats_parts+=("⚙ $tool_calls_count")
    [ "$files_edited_count" -gt 0 ] && stats_parts+=("✎ $files_edited_count")
    [ "$bash_commands_count" -gt 0 ] && stats_parts+=("⚡ $bash_commands_count")
    [ ${#stats_parts[@]} -gt 0 ] && stats_sec="${C_GRAY}$(IFS=' '; echo "${stats_parts[*]}")${C_RESET}"

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

    local config_parts=()
    [ "$SHOW_CLAUDE_MD" = "true" ] && [ "$claude_md_count" -gt 0 ] && config_parts+=("📝 ${claude_md_count}")
    [ "$SHOW_RULES" = "true" ] && [ "$rules_count" -gt 0 ] && config_parts+=("§ ${rules_count}")
    [ "$SHOW_MCP_SERVERS" = "true" ] && [ "$mcp_servers_count" -gt 0 ] && config_parts+=("🔌 ${mcp_servers_count}")
    [ "$SHOW_HOOKS" = "true" ] && [ "$hooks_count_new" -gt 0 ] && config_parts+=("⚓ ${hooks_count_new}")
    if [ ${#config_parts[@]} -gt 0 ]; then
        [ -n "$dev_cfg" ] && dev_cfg+=" · "
        dev_cfg+="$(IFS=' '; echo "${config_parts[*]}")"
    fi

    # Append sections with ┊ separators
    [ -n "$stats_sec" ] && l2+="${SEP}${stats_sec}"
    [ -n "$dev_cfg" ] && l2+="${SEP}${dev_cfg}"

    out_lines+=("$l2"); out_types+=("n")

    # --- Dynamic lines: Tools, Agents, Todos (only when active) ---
    local running_tools_count completed_tools_output
    running_tools_count=$(echo "$running_tools_json" | jq 'length' 2>/dev/null || echo "0")
    completed_tools_output=""

    # Top 3 completed tools, then "+N" for the rest
    local tname tcount
    while IFS=$'\t' read -r tname tcount; do
        if [ "$tname" = "+" ]; then
            completed_tools_output+="${C_GRAY}+${tcount}${C_RESET} "
        elif [ -n "$tname" ]; then
            completed_tools_output+="✓ $(short_tool_name "$tname") ×${tcount} "
        fi
    done < <(jq -r '(.[:3][] | "\(.name)\t\(.count)"), (if length > 3 then "+\t\(length - 3)" else empty end)' \
        <<< "$completed_counts_json" 2>/dev/null)

    if [ "$SHOW_RUNNING_TOOLS" = "true" ] && { [ "$running_tools_count" -gt 0 ] || [ -n "$completed_tools_output" ]; }; then
        local lt=""
        local spinner
        spinner=$(get_spinner_frame)

        if [ "$running_tools_count" -gt 0 ]; then
            local first_running_tool tool_name tool_input tool_target tool_timestamp elapsed
            first_running_tool=$(echo "$running_tools_json" | jq -c '.[0]' 2>/dev/null)
            tool_name=$(echo "$first_running_tool" | jq -r '.name // empty' 2>/dev/null)
            tool_input=$(echo "$first_running_tool" | jq -c '.input // {}' 2>/dev/null)
            tool_target=$(format_tool_target "$tool_name" "$tool_input")
            tool_timestamp=$(echo "$first_running_tool" | jq -r '.timestamp // empty' 2>/dev/null)
            [ -n "$tool_timestamp" ] && elapsed=$(format_elapsed_time "$tool_timestamp" "$current_time")

            lt+="${C_YELLOW}${spinner}${C_RESET} $(short_tool_name "$tool_name")"
            [ -n "$tool_target" ] && lt+=": ${C_CYAN}${tool_target}${C_RESET}"
            [ -n "$elapsed" ] && lt+=" ${C_GRAY}(${elapsed})${C_RESET}"
            [ "$running_tools_count" -gt 1 ] && lt+=" ${C_GRAY}+$((running_tools_count - 1)) more${C_RESET}"
        fi

        if [ -n "$completed_tools_output" ]; then
            [ "$running_tools_count" -gt 0 ] && lt+=" · "
            lt+="${C_GREEN}${completed_tools_output% }${C_RESET}"
        fi

        out_lines+=("$lt"); out_types+=("n")
    fi

    local running_agents_count
    running_agents_count=$(echo "$running_agents_json" | jq 'length' 2>/dev/null || echo "0")

    if [ "$SHOW_AGENTS" = "true" ] && [ "$running_agents_count" -gt 0 ]; then
        local la="" spinner
        spinner=$(get_spinner_frame)

        local first_agent agent_type agent_model agent_desc agent_timestamp elapsed
        first_agent=$(echo "$running_agents_json" | jq -c '.[0]' 2>/dev/null)
        agent_type=$(echo "$first_agent" | jq -r '.input.subagent_type // "unknown"' 2>/dev/null)
        agent_model=$(echo "$first_agent" | jq -r '.input.model // empty' 2>/dev/null)
        agent_desc=$(echo "$first_agent" | jq -r '.input.description // empty' 2>/dev/null)
        agent_timestamp=$(echo "$first_agent" | jq -r '.timestamp // empty' 2>/dev/null)
        [ -n "$agent_timestamp" ] && elapsed=$(format_elapsed_time "$agent_timestamp" "$current_time")

        la+="${C_YELLOW}${spinner}${C_RESET} ${C_PURPLE}${agent_type}${C_RESET}"
        [ -n "$agent_model" ] && la+=" [${C_CYAN}${agent_model}${C_RESET}]"
        [ -n "$agent_desc" ] && la+=": ${agent_desc}"
        [ -n "$elapsed" ] && la+=" ${C_GRAY}(${elapsed})${C_RESET}"
        [ "$running_agents_count" -gt 1 ] && la+=" ${C_GRAY}+$((running_agents_count - 1)) more${C_RESET}"

        out_lines+=("$la"); out_types+=("n")
    fi

    local todos_count
    todos_count=$(echo "$todos_json" | jq 'length' 2>/dev/null || echo "0")

    if [ "$SHOW_TODOS" = "true" ] && [ "$todos_count" -gt 0 ]; then
        local ltodo="" in_progress_todo completed_count
        in_progress_todo=$(echo "$todos_json" | jq -c '[.[] | select(.status == "in_progress")] | .[0] // empty' 2>/dev/null)
        completed_count=$(echo "$todos_json" | jq '[.[] | select(.status == "completed")] | length' 2>/dev/null || echo "0")

        ltodo+="▸ "
        if [ -n "$in_progress_todo" ] && [ "$in_progress_todo" != "null" ]; then
            local active_form content
            active_form=$(echo "$in_progress_todo" | jq -r '.activeForm // empty' 2>/dev/null)
            content=$(echo "$in_progress_todo" | jq -r '.content // empty' 2>/dev/null)
            if [ -n "$active_form" ]; then
                ltodo+="${C_YELLOW}${active_form}${C_RESET}"
            elif [ -n "$content" ]; then
                ltodo+="${C_YELLOW}${content}${C_RESET}"
            fi
        else
            ltodo+="${C_GRAY}No active task${C_RESET}"
        fi
        ltodo+=" ${C_GRAY}(${completed_count}/${todos_count})${C_RESET}"

        out_lines+=("$ltodo"); out_types+=("n")
    fi

    # --- Render with rounded box-drawing gutter ---
    local total=${#out_lines[@]}
    for ((i=0; i<total; i++)); do
        local gutter
        if [ $i -eq 0 ]; then
            gutter="${C_GRAY}╭${C_RESET}"
        elif [ $i -eq $((total - 1)) ]; then
            gutter="${C_GRAY}╰${C_RESET}"
        else
            gutter="${C_GRAY}│${C_RESET}"
        fi
        printf "  %b %b\n" "$gutter" "${out_lines[$i]}"
    done
}

# Run main
main
exit 0