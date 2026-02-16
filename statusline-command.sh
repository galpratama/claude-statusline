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

readonly DEFAULT_CACHE_TTL=5
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

# Print colored text
# Usage: color_print "green" "text"
color_print() {
    local color="$1"
    local text="$2"
    case "$color" in
        cyan)   printf "${C_CYAN}%s${C_RESET}" "$text" ;;
        blue)   printf "${C_BLUE}%s${C_RESET}" "$text" ;;
        purple) printf "${C_PURPLE}%s${C_RESET}" "$text" ;;
        green)  printf "${C_GREEN}%s${C_RESET}" "$text" ;;
        yellow) printf "${C_YELLOW}%s${C_RESET}" "$text" ;;
        red)    printf "${C_RED}%s${C_RESET}" "$text" ;;
        gray)   printf "${C_GRAY}%s${C_RESET}" "$text" ;;
        *)      printf "%s" "$text" ;;
    esac
}

# Get JSON value with default fallback
# Usage: json_get "$json" ".path.to.value" "default"
json_get() {
    local json="$1"
    local path="$2"
    local default="${3:-}"
    local result
    result=$(echo "$json" | jq -r "$path // empty" 2>/dev/null)
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "$default"
    else
        echo "$result"
    fi
}

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
        millions=$(echo "$millions" | sed 's/\.00$//' | sed 's/\([0-9]\)0$/\1/' | sed 's/\.$//')
        echo "${millions}M"
    elif [ "$num" -ge 1000 ]; then
        # Use awk instead of bc for better reliability
        local thousands
        thousands=$(awk -v n="$num" 'BEGIN { printf "%.2f", n/1000 }')
        # Remove trailing zeros and decimal point if needed
        thousands=$(echo "$thousands" | sed 's/\.00$//' | sed 's/\([0-9]\)0$/\1/' | sed 's/\.$//')
        echo "${thousands}k"
    else
        echo "$num"
    fi
}

# Convert string boolean to bash boolean (0/1)
str_to_bool() {
    [[ "$1" == "true" ]] && echo 1 || echo 0
}

# ============================================================================
# CACHING FUNCTIONS
# ============================================================================

get_cache_file() {
    local key="$1"
    local session_id="$2"
    echo "/tmp/claude-cache-${session_id}-${key}"
}

is_cache_valid() {
    local cache_file="$1"
    local ttl="$2"

    [[ "$ENABLE_CACHING" != "true" ]] && return 1
    [ ! -f "$cache_file" ] && return 1

    local cache_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || echo 0)))
    [ "$cache_age" -lt "$ttl" ]
}

read_cache() {
    cat "$1" 2>/dev/null || echo ""
}

write_cache() {
    echo "$2" > "$1" 2>/dev/null
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        CACHE_TTL=$(json_file_get "$CONFIG_FILE" '.performance.cache_ttl' "$DEFAULT_CACHE_TTL")
        ENABLE_CACHING=$(json_file_get "$CONFIG_FILE" '.performance.enable_caching' "true")

        # AI segment toggles
        SHOW_PROVIDER=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_provider' "true")
        SHOW_MODEL=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_model' "true")
        SHOW_COST=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_cost' "true")
        SHOW_CACHE_EFFICIENCY=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_cache_efficiency' "true")
        SHOW_RATE_LIMIT=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_rate_limit' "true")
        SHOW_MESSAGE_COUNT=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_message_count' "true")
        SHOW_MCP_SERVERS=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_mcp_servers' "true")
        SHOW_TOOLS=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_tools_count' "true")

        # Git segment toggles
        SHOW_GIT=$(json_file_get "$CONFIG_FILE" '.segments.git.enabled' "true")
        SHOW_LAST_COMMIT=$(json_file_get "$CONFIG_FILE" '.segments.git.show_last_commit' "true")
        SHOW_COMMITS_TODAY=$(json_file_get "$CONFIG_FILE" '.segments.git.show_commits_today' "true")

        # Dev segment toggles
        SHOW_DEV=$(json_file_get "$CONFIG_FILE" '.segments.dev.enabled' "true")
        SHOW_LANGUAGE=$(json_file_get "$CONFIG_FILE" '.segments.dev.show_language' "true")
        SHOW_PACKAGE_MANAGER=$(json_file_get "$CONFIG_FILE" '.segments.dev.show_package_manager' "true")
        SHOW_SERVERS=$(json_file_get "$CONFIG_FILE" '.segments.dev.show_running_servers' "true")

        # Feature toggles
        CLAUDE_STATUSLINE_LINT=$(json_file_get "$CONFIG_FILE" '.features.lint_checking' "false")
        CLAUDE_STATUSLINE_SERVERS=$(json_file_get "$CONFIG_FILE" '.features.server_detection' "true")

        # New feature toggles (from claude-hud)
        SHOW_RULES=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_rules' "true")
        SHOW_HOOKS=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_hooks' "true")
        SHOW_CLAUDE_MD=$(json_file_get "$CONFIG_FILE" '.segments.ai.show_claude_md' "true")
        SHOW_RUNNING_TOOLS=$(json_file_get "$CONFIG_FILE" '.segments.tools.enabled' "true")
        SHOW_AGENTS=$(json_file_get "$CONFIG_FILE" '.segments.agents.enabled' "true")
        SHOW_TODOS=$(json_file_get "$CONFIG_FILE" '.segments.todos.enabled' "true")
    else
        # Defaults when no config file
        CACHE_TTL=$DEFAULT_CACHE_TTL
        ENABLE_CACHING="true"
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

    # Handle MiniMax models
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

        # Kimi / Moonshot AI family
        *"kimi"*"k2"*|*"moonshot"*"k2"*)
            input_price=0.15; output_price=2.50 ;;
        *"moonshot"*"128k"*)
            input_price=0.84; output_price=0.84 ;;
        *"moonshot"*"32k"*)
            input_price=0.34; output_price=0.34 ;;
        *"moonshot"*"8k"*)
            input_price=0.17; output_price=0.17 ;;

        # GLM (Zhipu AI) family
        *"glm-4.6"*|*"glm-4-plus"*)
            input_price=0.84; output_price=0.84 ;;
        *"glm-4.5"*|*"glm-4.5-air"*)
            input_price=0.14; output_price=0.14 ;;
        *"glm"*)
            input_price=0.14; output_price=0.14 ;;

        # MiniMax AI family
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
    renewal_timestamp=$(date -j -f "%Y-%m-%d" "$renewal_date" +%s 2>/dev/null)

    case "$subscription_type" in
        "monthly")
            while [ "$renewal_timestamp" -lt "$current_timestamp" ]; do
                local current_month current_year next_month next_year day_of_month
                current_month=$(date -j -f "%s" "$renewal_timestamp" +%m 2>/dev/null)
                current_year=$(date -j -f "%s" "$renewal_timestamp" +%Y 2>/dev/null)
                next_month=$((10#$current_month + 1))
                next_year=$current_year
                [ $next_month -gt 12 ] && { next_month=1; next_year=$((next_year + 1)); }
                next_month=$(printf "%02d" $next_month)
                day_of_month=${renewal_day:-$(echo "$renewal_date" | cut -d'-' -f3)}
                renewal_timestamp=$(date -j -f "%Y-%m-%d" "${next_year}-${next_month}-${day_of_month}" +%s 2>/dev/null)
            done
            expiry_timestamp=$renewal_timestamp ;;
        "yearly")
            while [ "$renewal_timestamp" -lt "$current_timestamp" ]; do
                local current_year next_year month_day
                current_year=$(date -j -f "%s" "$renewal_timestamp" +%Y 2>/dev/null)
                next_year=$((current_year + 1))
                month_day=$(echo "$renewal_date" | cut -d'-' -f2-)
                renewal_timestamp=$(date -j -f "%Y-%m-%d" "${next_year}-${month_day}" +%s 2>/dev/null)
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

    # Parse JSONL and extract tool_use/tool_result blocks
    # Output format: JSON with tools, agents, todos arrays
    local tools_json agents_json todos_json

    # Use jq to process the JSONL file
    # Extract all tool_use and tool_result blocks with their IDs and timestamps
    local parsed
    parsed=$(cat "$transcript_path" 2>/dev/null | while IFS= read -r line; do
        echo "$line" | jq -c '
            select(.message.content != null) |
            .timestamp as $ts |
            .message.content[] |
            select(.type == "tool_use" or .type == "tool_result") |
            {type: .type, id: .id, tool_use_id: .tool_use_id, name: .name, input: .input, is_error: .is_error, timestamp: $ts}
        ' 2>/dev/null
    done)

    # Build running tools list (tool_use without matching tool_result)
    local tool_uses tool_results running_tools completed_counts

    # Get all tool_use entries
    tool_uses=$(echo "$parsed" | jq -sc '[.[] | select(.type == "tool_use")]' 2>/dev/null)

    # Get all tool_result entries
    tool_results=$(echo "$parsed" | jq -sc '[.[] | select(.type == "tool_result") | .tool_use_id]' 2>/dev/null)

    # Find running tools (tool_use IDs not in tool_results)
    running_tools=$(echo "$tool_uses" | jq -c --argjson completed "$tool_results" '
        [.[] | select(.id as $id | ($completed | index($id)) == null) | select(.name != "TodoWrite")]
    ' 2>/dev/null)

    # Find running agents (Task tool calls that are still running)
    local running_agents
    running_agents=$(echo "$tool_uses" | jq -c --argjson completed "$tool_results" '
        [.[] | select(.name == "Task") | select(.id as $id | ($completed | index($id)) == null)]
    ' 2>/dev/null)

    # Get latest todos from last TodoWrite call
    local latest_todos
    latest_todos=$(echo "$tool_uses" | jq -c '
        [.[] | select(.name == "TodoWrite")] | last | .input.todos // []
    ' 2>/dev/null)

    # Count completed tools by name
    local completed_tool_uses
    completed_tool_uses=$(echo "$tool_uses" | jq -c --argjson completed "$tool_results" '
        [.[] | select(.id as $id | ($completed | index($id)) != null) | select(.name != "TodoWrite" and .name != "Task")]
    ' 2>/dev/null)

    completed_counts=$(echo "$completed_tool_uses" | jq -c '
        group_by(.name) | map({name: .[0].name, count: length}) | sort_by(-.count)
    ' 2>/dev/null)

    # Write results to temp file
    echo "{\"running_tools\": $running_tools, \"running_agents\": $running_agents, \"todos\": $latest_todos, \"completed_counts\": $completed_counts}" > "$result_file"
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
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${start_timestamp%%.*}" +%s 2>/dev/null || echo "0")

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

get_git_info() {
    local dir="$1"

    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return

    local branch status file_changes sync_indicator git_info
    branch=$(git -C "$dir" -c core.fileMode=false --no-optional-locks branch --show-current 2>/dev/null || echo "detached")

    # Check uncommitted changes
    if ! git -C "$dir" -c core.fileMode=false --no-optional-locks diff --quiet 2>/dev/null || \
       ! git -C "$dir" -c core.fileMode=false --no-optional-locks diff --cached --quiet 2>/dev/null; then
        status="*"
    fi

    # File change counts
    local git_status added removed
    git_status=$(git -C "$dir" -c core.fileMode=false --no-optional-locks status --porcelain 2>/dev/null)
    if [ -n "$git_status" ]; then
        added=$(echo "$git_status" | grep -c -E "^A|^\?\?" 2>/dev/null || echo "0")
        removed=$(echo "$git_status" | grep -c -E "^ D|^D" 2>/dev/null || echo "0")
        added=${added//[^0-9]/}
        removed=${removed//[^0-9]/}
        [ -z "$added" ] && added=0
        [ -z "$removed" ] && removed=0
        if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
            file_changes=" "
            [ "$added" -gt 0 ] && file_changes+="+${added}"
            [ "$removed" -gt 0 ] && file_changes+="-${removed}"
        fi
    fi

    # Sync status
    if [ "$branch" != "detached" ]; then
        local remote_branch ahead behind
        remote_branch=$(git -C "$dir" -c core.fileMode=false --no-optional-locks rev-parse --abbrev-ref @{upstream} 2>/dev/null)
        if [ -n "$remote_branch" ]; then
            ahead=$(git -C "$dir" -c core.fileMode=false --no-optional-locks rev-list --count @{upstream}..HEAD 2>/dev/null || echo "0")
            behind=$(git -C "$dir" -c core.fileMode=false --no-optional-locks rev-list --count HEAD..@{upstream} 2>/dev/null || echo "0")
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
    fi

    # Build output
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

    if [ -n "$file_changes" ]; then
        git_info+="  "
        [[ "$file_changes" =~ \+([0-9]+) ]] && git_info+=$(printf "${C_GREEN}+%s" "${BASH_REMATCH[1]}")
        [[ "$file_changes" =~ \+([0-9]+) ]] && [[ "$file_changes" =~ -([0-9]+) ]] && git_info+=" "
        [[ "$file_changes" =~ -([0-9]+) ]] && git_info+=$(printf "${C_RED}-%s" "${BASH_REMATCH[1]}")
    fi

    echo "$git_info"
}

get_git_metrics() {
    local dir="$1"
    local current_time="$2"

    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return

    local last_commit_epoch time_diff hours days minutes last_commit_time commits_today
    last_commit_epoch=$(git -C "$dir" log -1 --format=%ct 2>/dev/null)

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
    fi

    local today_start commit_count
    today_start=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
    if [ -n "$today_start" ]; then
        commit_count=$(git -C "$dir" log --since="$today_start" --oneline 2>/dev/null | wc -l | tr -d ' ')
        [ "$commit_count" -gt 0 ] && commits_today="✓ ${commit_count}"
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

    if [ "$duration_hours" -gt 0 ]; then
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
# MAIN SCRIPT
# ============================================================================

main() {
    # Load configuration
    load_config

    # Read input
    local input
    input=$(cat)

    # Parse basic values
    local current_dir model_raw model_id model total_input total_output context_size session_id
    current_dir=$(json_get "$input" '.workspace.current_dir' "")
    model_raw=$(json_get "$input" '.model.display_name' "")
    model_id=$(json_get "$input" '.model.id' "")
    model=$(format_model_name "$model_raw")
    total_input=$(json_get "$input" '.context_window.total_input_tokens' "0")
    total_output=$(json_get "$input" '.context_window.total_output_tokens' "0")
    context_size=$(json_get "$input" '.context_window.context_window_size' "0")
    session_id=$(json_get "$input" '.session_id' "")

    # Ensure numeric values are valid
    [[ ! "$total_input" =~ ^[0-9]+$ ]] && total_input=0
    [[ ! "$total_output" =~ ^[0-9]+$ ]] && total_output=0
    [[ ! "$context_size" =~ ^[0-9]+$ ]] && context_size=0

    # Extract cost and metrics
    local json_cost json_duration lines_added lines_removed
    json_cost=$(json_get "$input" '.cost.total_cost_usd' "")
    json_duration=$(json_get "$input" '.cost.total_duration_ms' "")
    lines_added=$(json_get "$input" '.cost.total_lines_added' "0")
    lines_removed=$(json_get "$input" '.cost.total_lines_removed' "0")

    # Extract current usage context window data
    local current_input current_cache_creation current_cache_read
    current_input=$(json_get "$input" '.context_window.current_usage.input_tokens' "0")
    current_cache_creation=$(json_get "$input" '.context_window.current_usage.cache_creation_input_tokens' "0")
    current_cache_read=$(json_get "$input" '.context_window.current_usage.cache_read_input_tokens' "0")

    # Extract MCP and tools info
    local mcp_servers_count tools_count
    mcp_servers_count=$(echo "$input" | jq -r '.mcp_servers // [] | length' 2>/dev/null || echo "0")
    tools_count=$(echo "$input" | jq -r '.tools // [] | length' 2>/dev/null || echo "0")

    if [ "$mcp_servers_count" -eq 0 ] && [ -f "$HOME/.claude/.claude.json" ]; then
        mcp_servers_count=$(jq -r '.mcpServers // {} | length' "$HOME/.claude/.claude.json" 2>/dev/null || echo "0")
    fi

    # Cache tokens
    local cache_creation_tokens cache_read_tokens
    cache_creation_tokens=$(json_get "$input" '.context_window.cache_creation_input_tokens' "0")
    cache_read_tokens=$(json_get "$input" '.context_window.cache_read_input_tokens' "0")

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

    local json_tool_calls json_files_edited json_bash_commands
    local tool_calls_count files_edited_count bash_commands_count

    json_tool_calls=$(json_get "$input" '.stats.tool_calls' "")
    json_files_edited=$(json_get "$input" '.stats.files_edited' "")
    json_bash_commands=$(json_get "$input" '.stats.bash_commands' "")

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
    local transcript_path transcript_result_file
    transcript_path=$(json_get "$input" '.transcript_path' "")
    transcript_result_file="/tmp/claude-transcript-result-${session_id}"

    local running_tools_json running_agents_json todos_json completed_counts_json
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        parse_transcript "$transcript_path" "$transcript_result_file"
        if [ -f "$transcript_result_file" ]; then
            running_tools_json=$(jq -c '.running_tools // []' "$transcript_result_file" 2>/dev/null)
            running_agents_json=$(jq -c '.running_agents // []' "$transcript_result_file" 2>/dev/null)
            todos_json=$(jq -c '.todos // []' "$transcript_result_file" 2>/dev/null)
            completed_counts_json=$(jq -c '.completed_counts // []' "$transcript_result_file" 2>/dev/null)
        fi
    fi

    # Default to empty arrays if not set
    [ -z "$running_tools_json" ] && running_tools_json="[]"
    [ -z "$running_agents_json" ] && running_agents_json="[]"
    [ -z "$todos_json" ] && todos_json="[]"
    [ -z "$completed_counts_json" ] && completed_counts_json="[]"

    # Calculate cost
    local session_cost
    session_cost=$(calculate_cost "$provider_name" "$model_id" "$total_input" "$total_output" "$cache_creation_tokens" "$cache_read_tokens")

    # Cache efficiency
    local cache_total cache_efficiency=0
    cache_total=$((cache_creation_tokens + cache_read_tokens))
    [ "$cache_total" -gt 0 ] && [ "$total_input" -gt 0 ] && cache_efficiency=$((cache_read_tokens * 100 / total_input))

    # Calculate context window usage percentage
    local context_usage_pct=0 context_usage_color="${C_GREEN}"
    if [ "$context_size" -gt 0 ]; then
        # Ensure numeric values
        [[ ! "$current_input" =~ ^[0-9]+$ ]] && current_input=0
        [[ ! "$current_cache_creation" =~ ^[0-9]+$ ]] && current_cache_creation=0
        [[ ! "$current_cache_read" =~ ^[0-9]+$ ]] && current_cache_read=0

        local current_total_tokens=$((current_input + current_cache_creation + current_cache_read))
        if [ "$current_total_tokens" -gt 0 ]; then
            context_usage_pct=$((current_total_tokens * 100 / context_size))

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
    if [ -n "$subscription_info" ]; then
        provider_section=$(printf "${C_CYAN}%s${C_RESET} %s" "$provider_name" "$subscription_info")
    else
        provider_section=$(printf "${C_CYAN}%s${C_RESET}" "$provider_name")
    fi

    # Determine cost display
    local final_cost_display final_cost_color
    if [ -n "$json_cost" ]; then
        final_cost_display=$(printf "\$%.2f" "$json_cost" 2>/dev/null || echo "\$0.00")
        local cost_value
        cost_value=$(echo "$json_cost" | bc 2>/dev/null || echo "0")
        if [ $(echo "$cost_value >= 1.00" | bc 2>/dev/null || echo "0") -eq 1 ]; then
            final_cost_color="${C_RED}"
        elif [ $(echo "$cost_value >= 0.10" | bc 2>/dev/null || echo "0") -eq 1 ]; then
            final_cost_color="${C_YELLOW}"
        else
            final_cost_color="${C_GREEN}"
        fi
    else
        final_cost_display=$(printf "\$%.2f" "$session_cost" 2>/dev/null || echo "\$0.00")
        local cost_value
        cost_value=$(echo "$session_cost" | bc 2>/dev/null || echo "0")
        if [ $(echo "$cost_value >= 1.00" | bc 2>/dev/null || echo "0") -eq 1 ]; then
            final_cost_color="${C_RED}"
        elif [ $(echo "$cost_value >= 0.10" | bc 2>/dev/null || echo "0") -eq 1 ]; then
            final_cost_color="${C_YELLOW}"
        else
            final_cost_color="${C_GREEN}"
        fi
    fi

    # ========================================================================
    # OUTPUT GENERATION (Ultra compact 2-line layout with ┊ separators)
    # ========================================================================

    local -a out_lines=()
    local -a out_types=()
    local SEP=" ${C_GRAY}┊${C_RESET} "

    # --- Line 1: Model · Provider · Cost · Duration · Msg  ┊  Tokens · Ctx ---
    local l1="${C_PURPLE}${model}${C_RESET} · ${provider_section}"
    l1+=" · ${final_cost_color}${final_cost_display}${C_RESET}"
    l1+=" · ${C_GRAY}${duration}${C_RESET}"
    l1+=" · ${C_CYAN}${message_count} msg${C_RESET}"

    local tok_sec="${C_CYAN}↑ $(format_k "$total_input")${C_RESET} ${C_PURPLE}↓ $(format_k "$total_output")${C_RESET}"
    [ "$context_usage_pct" -gt 0 ] && tok_sec+=" · ${context_usage_color}${context_usage_pct}% ctx${C_RESET}"
    l1+="${SEP}${tok_sec}"

    out_lines+=("$l1"); out_types+=("n")

    # --- Line 2: Git/folder + changes  ┊  Stats  ┊  Dev + Config ---
    local l2=""

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

    local completed_arr
    completed_arr=$(echo "$completed_counts_json" | jq -c '.[]' 2>/dev/null)
    if [ -n "$completed_arr" ]; then
        while IFS= read -r tool_entry; do
            local tname tcount
            tname=$(echo "$tool_entry" | jq -r '.name' 2>/dev/null)
            tcount=$(echo "$tool_entry" | jq -r '.count' 2>/dev/null)
            [ -n "$tname" ] && [ "$tcount" -gt 0 ] && completed_tools_output+="✓ ${tname} ×${tcount} "
        done <<< "$completed_arr"
    fi

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

            lt+="${C_YELLOW}${spinner}${C_RESET} ${tool_name}"
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