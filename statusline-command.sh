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

    # Handle Kiro AWS proxy models
    if [[ "$name" =~ kiro-claude-(opus|sonnet|haiku)-([0-9])-([0-9])(-agentic)? ]]; then
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
    elif [[ "$name" =~ gemini-claude-(opus|sonnet|haiku)-([0-9])-([0-9])-(thinking|extended) ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        local mode="${BASH_REMATCH[4]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "${tier} ${major}.${minor} ${mode}"

    # Handle Claude 3.x models with version dates (e.g., claude-3-5-sonnet-20241022)
    elif [[ "$name" =~ claude-([0-9])-([0-9])-(opus|sonnet|haiku)-[0-9]{8} ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local tier="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        echo "${tier} ${major}.${minor}"

    # Handle standard Claude model names with version dates
    elif [[ "$name" =~ claude-(opus|sonnet|haiku)-([0-9])-([0-9])-[0-9]{8} ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        echo "${tier} ${major}.${minor}"

    # Handle standard Claude model names
    elif [[ "$name" =~ claude-(opus|sonnet|haiku)-([0-9])\.?([0-9])?-?[0-9]* ]]; then
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
    elif [[ "$name" =~ ^Claude\ (Opus|Sonnet|Haiku)\ ([0-9]\.?[0-9]?) ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"

    # Handle simple format like "Sonnet 4"
    elif [[ "$name" =~ ^(Opus|Sonnet|Haiku)\ 4$ ]]; then
        echo "${BASH_REMATCH[1]} 4.5"

    # Handle OpenAI GPT-5 family
    elif [[ "$name" =~ gpt-5\.([0-9])(-codex)?(-mini|-max|-nano)? ]]; then
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
    elif [[ "$name" =~ gpt-5(-codex)?(-mini|-nano)? ]]; then
        local codex="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        local display="GPT-5"
        [ -n "$codex" ] && display+=" Codex"
        [ "$variant" = "-mini" ] && display+=" Mini"
        [ "$variant" = "-nano" ] && display+=" Nano"
        echo "$display"

    # Handle Gemini 3.x models
    elif [[ "$name" =~ gemini-3-(pro|flash)(-image)?-preview ]]; then
        local tier="${BASH_REMATCH[1]}"
        local image="${BASH_REMATCH[2]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        if [ -n "$image" ]; then
            echo "Gemini 3 ${tier} Image"
        else
            echo "Gemini 3 ${tier}"
        fi

    # Handle Gemini 2.x computer-use without tier (e.g., gemini-2.5-computer-use-preview-10-2025)
    elif [[ "$name" =~ gemini-2\.([0-9])-computer-use-preview(-[0-9]+-[0-9]+)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        echo "Gemini 2.${minor} Computer"

    # Handle Gemini 2.x models with computer-use mode and tier (with or without date suffix)
    elif [[ "$name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)?-computer-use-preview(-[0-9]+-[0-9]+)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        display+=" Computer"
        echo "$display"
    elif [[ "$name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)?-preview ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        echo "$display"

    # Handle standard Gemini 2.x models
    elif [[ "$name" =~ gemini-2\.([0-9])-(pro|flash)(-lite)? ]]; then
        local minor="${BASH_REMATCH[1]}"
        local tier="${BASH_REMATCH[2]}"
        local lite="${BASH_REMATCH[3]}"
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"
        local display="Gemini 2.${minor} ${tier}"
        [ -n "$lite" ] && display+=" Lite"
        echo "$display"

    # Handle Qwen3 models with thinking/instruct modes
    elif [[ "$name" =~ qwen3-([0-9]+)b-a22b-(thinking|instruct)(-[0-9]+)? ]]; then
        local size="${BASH_REMATCH[1]}"
        local mode="${BASH_REMATCH[2]}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "Qwen3 ${size}B ${mode}"

    # Handle Qwen3 VL Plus specifically (must come before generic pattern)
    elif [[ "$name" =~ qwen3-vl-plus ]]; then
        echo "Qwen3 VL Plus"

    # Handle Qwen3 specialized variants
    elif [[ "$name" =~ qwen3-(coder|max)-(flash|plus|preview) ]]; then
        local type="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        type="$(echo ${type:0:1} | tr '[:lower:]' '[:upper:]')${type:1}"
        variant="$(echo ${variant:0:1} | tr '[:lower:]' '[:upper:]')${variant:1}"
        echo "Qwen3 ${type} ${variant}"

    # Handle Qwen3 simple variants (max only, since vl-plus handled above)
    elif [[ "$name" =~ qwen3-max ]]; then
        echo "Qwen3 Max"

    # Handle Qwen3 size-based models
    elif [[ "$name" =~ qwen3-([0-9]+)b ]]; then
        echo "Qwen3 ${BASH_REMATCH[1]}B"

    # Handle older Qwen models
    elif [[ "$name" =~ qwen/qwen([0-9])-(next-)?([0-9]+)b ]]; then
        local version="${BASH_REMATCH[1]}"
        local next="${BASH_REMATCH[2]}"
        local size="${BASH_REMATCH[3]}"
        if [ -n "$next" ]; then
            echo "Qwen${version} Next ${size}B"
        else
            echo "Qwen${version} ${size}B"
        fi
    elif [[ "$name" =~ alibaba-qwen([0-9])-(coder-)?([0-9]+)b ]]; then
        local version="${BASH_REMATCH[1]}"
        local coder="${BASH_REMATCH[2]}"
        local size="${BASH_REMATCH[3]}"
        if [ -n "$coder" ]; then
            echo "Qwen${version} Coder ${size}B"
        else
            echo "Qwen${version} ${size}B"
        fi

    # Handle Kimi/Moonshot K2 models
    elif [[ "$name" =~ kimi-k2-(thinking|instruct)(-[0-9]+)? ]]; then
        local mode="${BASH_REMATCH[1]}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "Kimi K2 ${mode}"
    elif [[ "$name" =~ kimi-k2 ]]; then
        echo "Kimi K2"
    elif [[ "$name" =~ moonshotai/kimi-k([0-9])-(thinking|instruct)(-[0-9]+)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local mode="${BASH_REMATCH[2]}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "Kimi K${version} ${mode}"

    # Handle DeepSeek V3.x models
    elif [[ "$name" =~ deepseek-v([0-9])\.([0-9])-(chat|reasoner) ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local mode="${BASH_REMATCH[3]}"
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"
        echo "DeepSeek V${major}.${minor} ${mode}"

    # Handle DeepSeek R1 and distill models
    elif [[ "$name" =~ deepseek-r([0-9])(-distill-llama-([0-9]+)b)? ]]; then
        local version="${BASH_REMATCH[1]}"
        local distill="${BASH_REMATCH[2]}"
        local size="${BASH_REMATCH[3]}"
        if [ -n "$distill" ]; then
            echo "DeepSeek R${version} Distill ${size}B"
        else
            echo "DeepSeek R${version}"
        fi

    # Handle DeepSeek versioned models
    elif [[ "$name" =~ deepseek-ai/deepseek-v([0-9])\.([0-9])-(terminus)? ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        local variant="${BASH_REMATCH[3]}"
        if [ -n "$variant" ]; then
            echo "DeepSeek V${major}.${minor} Terminus"
        else
            echo "DeepSeek V${major}.${minor}"
        fi
    elif [[ "$name" =~ deepseek-v([0-9])\.([0-9]) ]]; then
        echo "DeepSeek V${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$name" =~ deepseek-v([0-9])$ ]]; then
        echo "DeepSeek V${BASH_REMATCH[1]}"

    # Handle GLM models
    elif [[ "$name" =~ glm-([0-9])\.([0-9]) ]]; then
        echo "GLM ${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$name" =~ z-ai/glm-([0-9])\.([0-9])-air ]]; then
        echo "GLM ${BASH_REMATCH[1]}.${BASH_REMATCH[2]} Air"

    # Handle MiniMax models
    elif [[ "$name" =~ minimax-m([0-9]) ]]; then
        echo "MiniMax M${BASH_REMATCH[1]}"
    elif [[ "$name" =~ minimaxai/minimax-m([0-9]) ]]; then
        echo "MiniMax M${BASH_REMATCH[1]}"

    # Handle Mistral models
    elif [[ "$name" =~ mistralai/mistral-nemotron ]]; then
        echo "Mistral Nemotron"
    elif [[ "$name" =~ mistralai/devstral-([0-9]+) ]]; then
        echo "Devstral ${BASH_REMATCH[1]}"
    elif [[ "$name" =~ mistral-large-([0-9])-.* ]]; then
        echo "Mistral Large ${BASH_REMATCH[1]}"

    # Handle Llama models
    elif [[ "$name" =~ llama([0-9])\.?([0-9])?-([0-9]+)b-(instruct|base) ]]; then
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
    elif [[ "$name" =~ gpt-oss-([0-9]+)b-(medium|large)? ]]; then
        local size="${BASH_REMATCH[1]}"
        local variant="${BASH_REMATCH[2]}"
        if [ -n "$variant" ]; then
            variant="$(echo ${variant:0:1} | tr '[:lower:]' '[:upper:]')${variant:1}"
            echo "GPT OSS ${size}B ${variant}"
        else
            echo "GPT OSS ${size}B"
        fi
    elif [[ "$name" =~ openai/gpt-oss-([0-9]+)b ]]; then
        echo "GPT OSS ${BASH_REMATCH[1]}B"
    elif [[ "$name" =~ openai-gpt-oss-([0-9]+)b ]]; then
        echo "GPT OSS ${BASH_REMATCH[1]}B"

    # Handle T-Stars models
    elif [[ "$name" =~ tstars([0-9])\.([0-9]) ]]; then
        echo "T-Stars ${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"

    # Handle Kwai models
    elif [[ "$name" =~ kwaipilot/kat-coder-pro ]]; then
        echo "KAT Coder Pro"

    # Handle generic vision models
    elif [[ "$name" =~ vision-model ]]; then
        echo "Vision Model"

    else
        echo "$name"
    fi
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
            cache_creation_price=0.175; cache_read_price=0.175 ;;
        *"gpt-5.1"*)
            input_price=1.25; output_price=10.00
            cache_creation_price=0.125; cache_read_price=0.125 ;;
        *"gpt-5"*)
            if [[ "$model_id" == *"mini"* ]]; then
                input_price=0.25; output_price=2.00
                cache_creation_price=0.025; cache_read_price=0.025
            elif [[ "$model_id" == *"nano"* ]]; then
                input_price=0.05; output_price=0.40
                cache_creation_price=0.005; cache_read_price=0.005
            else
                input_price=1.25; output_price=10.00
                cache_creation_price=0.125; cache_read_price=0.125
            fi ;;

        # OpenAI GPT-4 family
        *"gpt-4o"*|*"gpt-4-o"*)
            input_price=5.00; output_price=15.00
            cache_creation_price=5.00; cache_read_price=2.50 ;;
        *"gpt-4"*)
            input_price=30.00; output_price=60.00 ;;
        *"gpt-3.5"*)
            input_price=0.50; output_price=1.50 ;;

        # Claude family
        *"opus-4"*|*"opus-4.5"*)
            input_price=5.00; output_price=25.00
            cache_creation_price=6.25; cache_read_price=0.50 ;;
        *"sonnet-4"*|*"sonnet-4.5"*|*"20241022"*)
            input_price=3.00; output_price=15.00
            cache_creation_price=3.75; cache_read_price=0.30 ;;
        *"haiku-4"*|*"haiku-4.5"*)
            input_price=0.80; output_price=4.00
            cache_creation_price=1.00; cache_read_price=0.08 ;;
        *"opus"*)
            input_price=15.00; output_price=75.00
            cache_creation_price=18.75; cache_read_price=1.50 ;;
        *"sonnet"*)
            input_price=3.00; output_price=15.00
            cache_creation_price=3.75; cache_read_price=0.30 ;;
        *"haiku"*)
            input_price=0.25; output_price=1.25
            cache_creation_price=0.30; cache_read_price=0.03 ;;

        # Gemini family
        *"gemini-2.5"*|*"2.5-pro"*)
            input_price=1.25; output_price=10.00 ;;
        *"gemini-2.0"*|*"2.0-flash"*)
            input_price=0.10; output_price=0.40 ;;
        *"gemini-1.5-pro"*|*"1.5-pro"*)
            input_price=1.25; output_price=5.00 ;;
        *"gemini-1.5-flash"*|*"1.5-flash"*)
            input_price=0.075; output_price=0.30 ;;

        # DeepSeek family
        *"deepseek"*"reasoner"*|*"deepseek"*"r1"*)
            input_price=0.55; output_price=2.19
            cache_creation_price=0.55; cache_read_price=0.14 ;;
        *"deepseek"*)
            input_price=0.27; output_price=1.10
            cache_creation_price=0.27; cache_read_price=0.07 ;;

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

    # Calculate cost
    local session_cost
    session_cost=$(calculate_cost "$provider_name" "$model_id" "$total_input" "$total_output" "$cache_creation_tokens" "$cache_read_tokens")

    # Cache efficiency
    local cache_total cache_efficiency=0
    cache_total=$((cache_creation_tokens + cache_read_tokens))
    [ "$cache_total" -gt 0 ] && [ "$total_input" -gt 0 ] && cache_efficiency=$((cache_read_tokens * 100 / total_input))

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
    # OUTPUT GENERATION
    # ========================================================================

    # Line 1: Cost info
    printf "  💰"
    printf " ${C_YELLOW}%s${C_RESET}" "$final_cost_display"
    printf " · %s · %s" "$provider_section" "$model"
    printf " · %s" "$duration"
   
    printf " · ${C_CYAN}↑ %s${C_RESET} · ${C_PURPLE}↓ %s${C_RESET}" "$(format_k "$total_input")" "$(format_k "$total_output")"

    # Always show message count
    printf " · ${C_CYAN}%d msg${C_RESET}" "$message_count"

    # Lines changed
    if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
        if [ "$lines_added" -gt 0 ] && [ "$lines_removed" -gt 0 ]; then
            printf " · ${C_GREEN}+%d${C_RESET}/${C_RED}-%d${C_RESET}" "$lines_added" "$lines_removed"
        elif [ "$lines_added" -gt 0 ]; then
            printf " · ${C_GREEN}+%d${C_RESET}" "$lines_added"
        elif [ "$lines_removed" -gt 0 ]; then
            printf " · ${C_RED}-%d${C_RESET}" "$lines_removed"
        fi
    fi

    # Session statistics
    local stats_parts=()
    [ "$tool_calls_count" -gt 0 ] && stats_parts+=("🔧 $tool_calls_count")
    [ "$files_edited_count" -gt 0 ] && stats_parts+=("✏ $files_edited_count")
    [ "$bash_commands_count" -gt 0 ] && stats_parts+=("⚡ $bash_commands_count")

    if [ ${#stats_parts[@]} -gt 0 ]; then
        printf " · ${C_GRAY}%s${C_RESET}" "$(IFS=' · '; echo "${stats_parts[*]}")"
    fi

    # Folder if not git
    [ -z "$git_info" ] && printf " · 📁 %s" "$dir"
    printf "\n"

    # Line 2: Git info
    if [ -n "$git_info" ]; then
        printf "  📁 %s %s" "$dir" "$git_info"
        [ -n "$last_commit_time" ] && printf " · ${C_GRAY}%s${C_RESET}" "$last_commit_time"
        [ -n "$commits_today" ] && printf " · ${C_GREEN}%s today" "$commits_today"
        printf "\n"
    fi

    # Line 3: Dev info
    local dev_info=""
    [ -n "$prog_lang" ] && dev_info+="$prog_lang"
    if [ -n "$package_manager" ]; then
        [ -n "$dev_info" ] && dev_info+=" · "
        dev_info+="$package_manager"
    fi
    if [ -n "$running_servers" ]; then
        [ -n "$dev_info" ] && dev_info+=" · "
        dev_info+="${C_GREEN}${running_servers}${C_RESET}"
    fi

    [ -n "$dev_info" ] && printf "  🔧 %b\n" "$dev_info"
}

# Run main
main
exit 0