#!/bin/bash

# Claude Code Statusline Script - Enhanced Edition
# Performance optimizations:
# - Configuration-based segment toggling
# - Caching system for expensive operations (git, servers, language detection)
# - Centralized color management
# - Git operations use --no-optional-locks for speed
# - Minimal file system operations

set -o pipefail  # Better error handling

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

CONFIG_FILE="${HOME}/.claude/statusline-config.json"
DEFAULT_CACHE_TTL=5

# Load configuration or use defaults
if [ -f "$CONFIG_FILE" ]; then
    CACHE_TTL=$(jq -r '.performance.cache_ttl // 5' "$CONFIG_FILE" 2>/dev/null || echo "$DEFAULT_CACHE_TTL")
    ENABLE_CACHING=$(jq -r '.performance.enable_caching // true' "$CONFIG_FILE" 2>/dev/null || echo "true")

    # Segment toggles - AI
    SHOW_PROVIDER=$(jq -r '.segments.ai.show_provider // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_MODEL=$(jq -r '.segments.ai.show_model // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_COST=$(jq -r '.segments.ai.show_cost // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_CACHE_EFFICIENCY=$(jq -r '.segments.ai.show_cache_efficiency // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_RATE_LIMIT=$(jq -r '.segments.ai.show_rate_limit // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_MESSAGE_COUNT=$(jq -r '.segments.ai.show_message_count // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_MCP_SERVERS=$(jq -r '.segments.ai.show_mcp_servers // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_TOOLS=$(jq -r '.segments.ai.show_tools_count // true' "$CONFIG_FILE" 2>/dev/null || echo "true")

    # Segment toggles - Git
    SHOW_GIT=$(jq -r '.segments.git.enabled // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_LAST_COMMIT=$(jq -r '.segments.git.show_last_commit // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_COMMITS_TODAY=$(jq -r '.segments.git.show_commits_today // true' "$CONFIG_FILE" 2>/dev/null || echo "true")

    # Segment toggles - Dev
    SHOW_DEV=$(jq -r '.segments.dev.enabled // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_LANGUAGE=$(jq -r '.segments.dev.show_language // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_PACKAGE_MANAGER=$(jq -r '.segments.dev.show_package_manager // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
    SHOW_SERVERS=$(jq -r '.segments.dev.show_running_servers // true' "$CONFIG_FILE" 2>/dev/null || echo "true")

    # Feature toggles
    CLAUDE_STATUSLINE_LINT=$(jq -r '.features.lint_checking // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
    CLAUDE_STATUSLINE_SERVERS=$(jq -r '.features.server_detection // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
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

# Convert string booleans to 0/1 for easier checking
[[ "$CLAUDE_STATUSLINE_LINT" == "true" ]] && CLAUDE_STATUSLINE_LINT=1 || CLAUDE_STATUSLINE_LINT=0
[[ "$CLAUDE_STATUSLINE_SERVERS" == "true" ]] && CLAUDE_STATUSLINE_SERVERS=1 || CLAUDE_STATUSLINE_SERVERS=0

# ============================================================================
# COLOR DEFINITIONS (Centralized)
# ============================================================================

# Primary colors
COLOR_CYAN="\033[36m"
COLOR_BLUE="\033[34m"
COLOR_PURPLE="\033[35m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_GRAY="\033[90m"
COLOR_RESET="%s"

# Semantic color aliases
COLOR_PRIMARY="$COLOR_CYAN"
COLOR_SUCCESS="$COLOR_GREEN"
COLOR_WARNING="$COLOR_YELLOW"
COLOR_ERROR="$COLOR_RED"
COLOR_MUTED="$COLOR_GRAY"
COLOR_INFO="$COLOR_BLUE"

# ============================================================================
# CACHING UTILITIES
# ============================================================================

# Get cache file path for a given key
get_cache_file() {
    local key="$1"
    local session_id="$2"
    echo "/tmp/claude-cache-${session_id}-${key}"
}

# Check if cache is valid
is_cache_valid() {
    local cache_file="$1"
    local ttl="$2"

    if [[ "$ENABLE_CACHING" != "true" ]]; then
        return 1
    fi

    if [ ! -f "$cache_file" ]; then
        return 1
    fi

    local cache_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || echo 0)))
    [ "$cache_age" -lt "$ttl" ]
}

# Read from cache
read_cache() {
    local cache_file="$1"
    cat "$cache_file" 2>/dev/null || echo ""
}

# Write to cache
write_cache() {
    local cache_file="$1"
    local content="$2"
    echo "$content" > "$cache_file" 2>/dev/null
}

# ============================================================================
# INPUT PARSING
# ============================================================================

# Read JSON input from stdin
input=$(cat)

# Extract values from JSON
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
model_raw=$(echo "$input" | jq -r '.model.display_name')
model_id=$(echo "$input" | jq -r '.model.id')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens')

# Format model name (shorten Antigravity/Kiro/proxy model names)
format_model_name() {
    local name="$1"

    # Handle Antigravity/Gemini/Kiro proxy models
    if [[ "$name" =~ gemini-claude-(opus|sonnet|haiku)-([0-9])-([0-9])-(thinking|extended) ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        local mode="${BASH_REMATCH[4]}"

        # Capitalize tier
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"

        # Format mode
        mode="$(echo ${mode:0:1} | tr '[:lower:]' '[:upper:]')${mode:1}"

        echo "${tier} ${major}.${minor} ${mode}"
    # Handle standard Claude model names (claude-opus-4-20250514 -> Opus 4.5)
    elif [[ "$name" =~ claude-(opus|sonnet|haiku)-([0-9])\.?([0-9])?-?[0-9]* ]]; then
        local tier="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"

        # Capitalize tier
        tier="$(echo ${tier:0:1} | tr '[:lower:]' '[:upper:]')${tier:1}"

        # Map version 4 to 4.5 for current generation models
        if [ "$major" = "4" ] && [ -z "$minor" ]; then
            echo "${tier} 4.5"
        elif [ -n "$minor" ]; then
            echo "${tier} ${major}.${minor}"
        else
            echo "${tier} ${major}"
        fi
    # Handle Claude Sonnet 4.5/Opus 4.5 display names
    elif [[ "$name" =~ ^Claude\ (Opus|Sonnet|Haiku)\ ([0-9]\.?[0-9]?) ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    # Handle simple format like "Sonnet 4" -> "Sonnet 4.5"
    elif [[ "$name" =~ ^(Opus|Sonnet|Haiku)\ 4$ ]]; then
        echo "${BASH_REMATCH[1]} 4.5"
    else
        # Return original name for other models
        echo "$name"
    fi
}

model=$(format_model_name "$model_raw")
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size')
session_id=$(echo "$input" | jq -r '.session_id')

# Extract cost and metrics from JSON (if available)
json_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
json_duration=$(echo "$input" | jq -r '.cost.total_duration_ms // empty' 2>/dev/null)
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0' 2>/dev/null)
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0' 2>/dev/null)

# Extract MCP and tools information
mcp_servers_count=$(echo "$input" | jq -r '.mcp_servers // [] | length' 2>/dev/null || echo "0")
tools_count=$(echo "$input" | jq -r '.tools // [] | length' 2>/dev/null || echo "0")

# Fallback: If no MCP servers from input, check .claude.json config file
if [ "$mcp_servers_count" -eq 0 ] && [ -f "$HOME/.claude/.claude.json" ]; then
    mcp_servers_count=$(jq -r '.mcpServers // {} | length' "$HOME/.claude/.claude.json" 2>/dev/null || echo "0")
fi

# Try to extract cache information (if available in the JSON)
cache_creation_tokens=$(echo "$input" | jq -r '.context_window.cache_creation_input_tokens // 0' 2>/dev/null || echo "0")
cache_read_tokens=$(echo "$input" | jq -r '.context_window.cache_read_input_tokens // 0' 2>/dev/null || echo "0")

# Try to extract actual session usage data from JSON input (if available)
session_usage_pct=$(echo "$input" | jq -r '.rate_limit.session_usage_percent // empty' 2>/dev/null)
session_reset_time=$(echo "$input" | jq -r '.rate_limit.session_reset_at // empty' 2>/dev/null)
week_usage_pct=$(echo "$input" | jq -r '.rate_limit.week_usage_percent // empty' 2>/dev/null)
week_reset_time=$(echo "$input" | jq -r '.rate_limit.week_reset_at // empty' 2>/dev/null)

# Detect provider/backend name
provider_name=""
if [ -n "$CLAUDE_PROVIDER" ]; then
    # Use explicit provider from environment variable
    provider_name="$CLAUDE_PROVIDER"
else
    # Default to Claude since we only use .claude directory
    provider_name="Claude"
fi

# Calculate session duration and track metrics
session_file="/tmp/claude-session-${session_id}"
session_metrics="/tmp/claude-metrics-${session_id}"

if [ ! -f "$session_file" ]; then
    # Create session file with current timestamp
    date +%s > "$session_file"
    # Initialize metrics file
    echo "0" > "$session_metrics"  # Previous total tokens
    # Initialize message count
    echo "0" > "/tmp/claude-messages-${session_id}"
fi

session_start=$(cat "$session_file")
current_time=$(date +%s)
duration_seconds=$((current_time - session_start))
duration_minutes=$((duration_seconds / 60))
duration_hours=$((duration_minutes / 60))
remaining_minutes=$((duration_minutes % 60))

# Format duration display
if [ "$duration_hours" -gt 0 ]; then
    if [ "$remaining_minutes" -gt 0 ]; then
        duration="${duration_hours}h ${remaining_minutes}m"
    else
        duration="${duration_hours}h"
    fi
elif [ "$duration_minutes" -gt 0 ]; then
    duration="${duration_minutes}m"
else
    duration="<1m"
fi

# Get current date and time display
current_time_display=$(date '+%H:%M')
current_date_display=$(date '+%b %d')

# Calculate message count (track when tokens change)
message_count_file="/tmp/claude-messages-${session_id}"
prev_total=$(cat "$session_metrics" 2>/dev/null || echo "0")
current_total=$((total_input + total_output))

if [ "$current_total" -gt "$prev_total" ] && [ "$prev_total" -gt 0 ]; then
    # Tokens increased, increment message count
    message_count=$(cat "$message_count_file" 2>/dev/null || echo "0")
    message_count=$((message_count + 1))
    echo "$message_count" > "$message_count_file"
else
    message_count=$(cat "$message_count_file" 2>/dev/null || echo "0")
fi

# Track session statistics: tool calls, files edited, bash commands
stats_tool_calls_file="/tmp/claude-stats-tools-${session_id}"
stats_files_file="/tmp/claude-stats-files-${session_id}"
stats_bash_file="/tmp/claude-stats-bash-${session_id}"

# Initialize stats files if they don't exist
[ ! -f "$stats_tool_calls_file" ] && echo "0" > "$stats_tool_calls_file"
[ ! -f "$stats_files_file" ] && echo "0" > "$stats_files_file"
[ ! -f "$stats_bash_file" ] && echo "0" > "$stats_bash_file"

# Try to extract stats from JSON input (if available)
json_tool_calls=$(echo "$input" | jq -r '.stats.tool_calls // empty' 2>/dev/null)
json_files_edited=$(echo "$input" | jq -r '.stats.files_edited // empty' 2>/dev/null)
json_bash_commands=$(echo "$input" | jq -r '.stats.bash_commands // empty' 2>/dev/null)

# Use JSON stats if available, otherwise use our tracked values
if [ -n "$json_tool_calls" ] && [ "$json_tool_calls" != "null" ]; then
    tool_calls_count=$json_tool_calls
else
    tool_calls_count=$(cat "$stats_tool_calls_file" 2>/dev/null || echo "0")
fi

if [ -n "$json_files_edited" ] && [ "$json_files_edited" != "null" ]; then
    files_edited_count=$json_files_edited
else
    files_edited_count=$(cat "$stats_files_file" 2>/dev/null || echo "0")
fi

if [ -n "$json_bash_commands" ] && [ "$json_bash_commands" != "null" ]; then
    bash_commands_count=$json_bash_commands
else
    bash_commands_count=$(cat "$stats_bash_file" 2>/dev/null || echo "0")
fi

# Detect package manager and programming language in current directory
package_managers=()
prog_langs=()

# Check for JavaScript/Node.js package managers (priority order)
if [ -f "$current_dir/pnpm-lock.yaml" ]; then
    package_managers+=("pnpm")
    if command -v node >/dev/null 2>&1; then
        node_version=$(node --version 2>/dev/null | sed 's/v//')
        prog_langs+=("Node ${node_version}")
    fi
elif [ -f "$current_dir/bun.lockb" ]; then
    package_managers+=("bun")
    if command -v bun >/dev/null 2>&1; then
        bun_version=$(bun --version 2>/dev/null)
        prog_langs+=("Bun ${bun_version}")
    fi
elif [ -f "$current_dir/yarn.lock" ]; then
    package_managers+=("yarn")
    if command -v node >/dev/null 2>&1; then
        node_version=$(node --version 2>/dev/null | sed 's/v//')
        prog_langs+=("Node ${node_version}")
    fi
elif [ -f "$current_dir/package-lock.json" ] || [ -f "$current_dir/package.json" ]; then
    package_managers+=("npm")
    if command -v node >/dev/null 2>&1; then
        node_version=$(node --version 2>/dev/null | sed 's/v//')
        prog_langs+=("Node ${node_version}")
    fi
fi

# Check for PHP (composer)
if [ -f "$current_dir/composer.json" ]; then
    package_managers+=("composer")
    if command -v php >/dev/null 2>&1; then
        php_version=$(php --version 2>/dev/null | head -1 | awk '{print $2}')
        prog_langs+=("PHP ${php_version}")
    fi
fi

# Check for Ruby (gem)
if [ -f "$current_dir/Gemfile" ]; then
    package_managers+=("gem")
    if command -v ruby >/dev/null 2>&1; then
        ruby_version=$(ruby --version 2>/dev/null | awk '{print $2}')
        prog_langs+=("Ruby ${ruby_version}")
    fi
fi

# Check for Python
if [ -f "$current_dir/requirements.txt" ] || [ -f "$current_dir/Pipfile" ] || [ -f "$current_dir/pyproject.toml" ]; then
    package_managers+=("pip")
    if command -v python3 >/dev/null 2>&1; then
        python_version=$(python3 --version 2>/dev/null | awk '{print $2}')
        prog_langs+=("Python ${python_version}")
    elif command -v python >/dev/null 2>&1; then
        python_version=$(python --version 2>/dev/null | awk '{print $2}')
        prog_langs+=("Python ${python_version}")
    fi
fi

# Check for Go
if [ -f "$current_dir/go.mod" ]; then
    package_managers+=("go")
    if command -v go >/dev/null 2>&1; then
        go_version=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')
        prog_langs+=("Go ${go_version}")
    fi
fi

# Check for Rust
if [ -f "$current_dir/Cargo.toml" ]; then
    package_managers+=("cargo")
    if command -v rustc >/dev/null 2>&1; then
        rust_version=$(rustc --version 2>/dev/null | awk '{print $2}')
        prog_langs+=("Rust ${rust_version}")
    fi
fi

# Combine arrays into strings
if [ ${#package_managers[@]} -gt 0 ]; then
    package_manager=$(IFS='+'; echo "${package_managers[*]}")
else
    package_manager=""
fi

if [ ${#prog_langs[@]} -gt 0 ]; then
    prog_lang=$(IFS='+'; echo "${prog_langs[*]}")
else
    prog_lang=""
fi

# Detect linting errors
# DISABLED BY DEFAULT - Too slow for statusline
# Set CLAUDE_STATUSLINE_LINT=1 to enable
lint_errors=""
if [ "$CLAUDE_STATUSLINE_LINT" = "1" ]; then
    if [ -f "$current_dir/package.json" ]; then
        # Check for ESLint
        if command -v npx >/dev/null 2>&1 && [ -f "$current_dir/.eslintrc.json" ] || [ -f "$current_dir/.eslintrc.js" ] || [ -f "$current_dir/eslint.config.js" ]; then
            error_count=$(cd "$current_dir" && npx eslint . --format json 2>/dev/null | jq '[.[].errorCount] | add' 2>/dev/null || echo "0")
            if [ "$error_count" -gt 0 ]; then
                lint_errors="⚠ ${error_count}"
            fi
        fi
    fi
fi

# Check for running local servers on configured listened ports
# OPTIMIZED: Single lsof call instead of multiple separate calls (10-20x faster!)
# Configured via statusline-config.json - set server_detection to false to disable
running_servers=""
config_file="$HOME/Scripts/claude-statusline/statusline-config.json"

if [ -f "$config_file" ]; then
    server_detection=$(jq -r '.features.server_detection // true' "$config_file" 2>/dev/null)
else
    server_detection=true
fi

if [ "$server_detection" = true ]; then
    active_servers=()

    # Read listened_ports and ignored_ports from config file
    if [ -f "$config_file" ]; then
        # Read ports arrays from JSON and convert to bash arrays
        listened_ports=($(jq -r '.features.listened_ports[]? // empty' "$config_file" 2>/dev/null))
        ignored_ports=($(jq -r '.features.ignored_ports[]? // empty' "$config_file" 2>/dev/null))
    fi

    # Fallback to default ports if config doesn't have any
    if [ ${#listened_ports[@]} -eq 0 ]; then
        listened_ports=(80 3000 3001 3306 4200 5173 5174 5432 6379 8000 8001 8080 8888 9000)
    fi

    # Use netstat (faster than lsof) if available, otherwise fall back to lsof
    if command -v netstat >/dev/null 2>&1; then
        # netstat is much faster than lsof (macOS uses dots, Linux uses colons)
        # Match both formats: *.8000 and *:8000
        netstat_output=$(netstat -an -p tcp 2>/dev/null | grep LISTEN | awk '{print $4}')

        if [ -n "$netstat_output" ]; then
            for port in "${listened_ports[@]}"; do
                # Skip if port is in ignored_ports
                skip_port=false
                for ignored in "${ignored_ports[@]}"; do
                    if [ "$port" = "$ignored" ]; then
                        skip_port=true
                        break
                    fi
                done
                [ "$skip_port" = true ] && continue

                # Check if this port is in the netstat output (match both .PORT and :PORT)
                if echo "$netstat_output" | grep -q -E "[.:]${port}$"; then
                    # Get process name for this port using single lsof call
                    process_name=$(lsof -iTCP:$port -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR==2 {print $1}')
                    if [ -n "$process_name" ]; then
                        active_servers+=("${process_name}:${port}")
                    fi
                fi
            done
        fi
    else
        # Fallback: Single lsof call for all TCP LISTEN ports
        lsof_output=$(lsof -iTCP -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR>1 {print $1":"$9}')

        if [ -n "$lsof_output" ]; then
            for port in "${listened_ports[@]}"; do
                # Skip if port is in ignored_ports
                skip_port=false
                for ignored in "${ignored_ports[@]}"; do
                    if [ "$port" = "$ignored" ]; then
                        skip_port=true
                        break
                    fi
                done
                [ "$skip_port" = true ] && continue

                # Check if port exists in output
                match=$(echo "$lsof_output" | grep ":${port}$" | head -1)
                if [ -n "$match" ]; then
                    # Extract process name (before the colon)
                    process_name=$(echo "$match" | cut -d: -f1)
                    active_servers+=("${process_name}:${port}")
                fi
            done
        fi
    fi

    if [ ${#active_servers[@]} -gt 0 ]; then
        servers_list=$(IFS=', '; echo "${active_servers[*]}")
        running_servers="${servers_list}"
    fi
fi

# Calculate API costs based on model pricing (as of December 2025)
# Prices per 1M tokens: Input / Output
calculate_cost() {
    local provider="$1"
    local model_id="$2"
    local input_tokens=$3
    local output_tokens=$4
    local cache_creation=$5
    local cache_read=$6

    # Pricing per million tokens
    local input_price=0
    local output_price=0
    local cache_creation_price=0
    local cache_read_price=0
    local use_free_pricing=false

    # Match model patterns directly (model IDs are unique across providers)
    case "$model_id" in
        # OpenAI GPT-5 family
        *"gpt-5.2"*)
            input_price=1.75
            output_price=14.00
            cache_creation_price=0.175
            cache_read_price=0.175
            ;;
        *"gpt-5.1"*)
            input_price=1.25
            output_price=10.00
            cache_creation_price=0.125
            cache_read_price=0.125
            ;;
        *"gpt-5"*)
            if [[ "$model_id" == *"mini"* ]]; then
                input_price=0.25
                output_price=2.00
                cache_creation_price=0.025
                cache_read_price=0.025
            elif [[ "$model_id" == *"nano"* ]]; then
                input_price=0.05
                output_price=0.40
                cache_creation_price=0.005
                cache_read_price=0.005
            else
                input_price=1.25
                output_price=10.00
                cache_creation_price=0.125
                cache_read_price=0.125
            fi
            ;;

        # OpenAI GPT-4 family
        *"gpt-4o"*|*"gpt-4-o"*)
            input_price=5.00
            output_price=15.00
            cache_creation_price=5.00
            cache_read_price=2.50
            ;;
        *"gpt-4"*)
            input_price=30.00
            output_price=60.00
            ;;
        *"gpt-3.5"*)
            input_price=0.50
            output_price=1.50
            ;;

        # Claude family
        *"opus-4"*|*"opus-4.5"*)
            input_price=5.00
            output_price=25.00
            cache_creation_price=6.25
            cache_read_price=0.50
            ;;
        *"sonnet-4"*|*"sonnet-4.5"*|*"20241022"*)
            input_price=3.00
            output_price=15.00
            cache_creation_price=3.75
            cache_read_price=0.30
            ;;
        *"haiku-4"*|*"haiku-4.5"*)
            input_price=0.80
            output_price=4.00
            cache_creation_price=1.00
            cache_read_price=0.08
            ;;
        *"opus"*)
            input_price=15.00
            output_price=75.00
            cache_creation_price=18.75
            cache_read_price=1.50
            ;;
        *"sonnet"*)
            input_price=3.00
            output_price=15.00
            cache_creation_price=3.75
            cache_read_price=0.30
            ;;
        *"haiku"*)
            input_price=0.25
            output_price=1.25
            cache_creation_price=0.30
            cache_read_price=0.03
            ;;

        # Gemini family
        *"gemini-2.5"*|*"2.5-pro"*)
            input_price=1.25
            output_price=10.00
            ;;
        *"gemini-2.0"*|*"2.0-flash"*)
            input_price=0.10
            output_price=0.40
            ;;
        *"gemini-1.5-pro"*|*"1.5-pro"*)
            input_price=1.25
            output_price=5.00
            ;;
        *"gemini-1.5-flash"*|*"1.5-flash"*)
            input_price=0.075
            output_price=0.30
            ;;

        # DeepSeek family
        *"deepseek"*"reasoner"*|*"deepseek"*"r1"*)
            input_price=0.55
            output_price=2.19
            cache_creation_price=0.55
            cache_read_price=0.14
            ;;
        *"deepseek"*)
            input_price=0.27
            output_price=1.10
            cache_creation_price=0.27
            cache_read_price=0.07
            ;;

        # Kimi / Moonshot AI family
        *"kimi"*"k2"*|*"moonshot"*"k2"*)
            input_price=0.15
            output_price=2.50
            ;;
        *"moonshot"*"128k"*)
            input_price=0.84
            output_price=0.84
            ;;
        *"moonshot"*"32k"*)
            input_price=0.34
            output_price=0.34
            ;;
        *"moonshot"*"8k"*)
            input_price=0.17
            output_price=0.17
            ;;

        # GLM (Zhipu AI) family
        *"glm-4.6"*|*"glm-4-plus"*)
            input_price=0.84
            output_price=0.84
            ;;
        *"glm-4.5"*|*"glm-4.5-air"*)
            input_price=0.14
            output_price=0.14
            ;;
        *"glm"*)
            input_price=0.14
            output_price=0.14
            ;;

        # MiniMax AI family
        *"minimax"*"m2"*|*"m2"*)
            input_price=0.30
            output_price=1.20
            cache_creation_price=0.375
            cache_read_price=0.03
            ;;
        *"abab6.5s"*|*"6.5s"*)
            input_price=0.14
            output_price=0.14
            ;;
        *"abab6.5"*|*"6.5"*)
            input_price=0.42
            output_price=0.42
            ;;
        *"abab5.5"*|*"5.5"*)
            input_price=0.07
            output_price=0.07
            ;;

        # Default fallback (use Claude Sonnet 4.5 pricing)
        *)
            input_price=3.00
            output_price=15.00
            cache_creation_price=3.75
            cache_read_price=0.30
            ;;
    esac

    # Return "FREE" for free providers
    if [ "$use_free_pricing" = true ]; then
        echo "FREE"
        return
    fi

    # Calculate costs (in dollars)
    local regular_input=$((input_tokens - cache_read - cache_creation))
    [ $regular_input -lt 0 ] && regular_input=0

    local cost_input=$(echo "scale=6; $regular_input * $input_price / 1000000" | bc 2>/dev/null || echo "0")
    local cost_output=$(echo "scale=6; $output_tokens * $output_price / 1000000" | bc 2>/dev/null || echo "0")
    local cost_cache_creation=$(echo "scale=6; $cache_creation * $cache_creation_price / 1000000" | bc 2>/dev/null || echo "0")
    local cost_cache_read=$(echo "scale=6; $cache_read * $cache_read_price / 1000000" | bc 2>/dev/null || echo "0")

    local total=$(echo "scale=2; $cost_input + $cost_output + $cost_cache_creation + $cost_cache_read" | bc 2>/dev/null || echo "0")
    echo "$total"
}

session_cost=$(calculate_cost "$provider_name" "$model_id" "$total_input" "$total_output" "$cache_creation_tokens" "$cache_read_tokens")

# Calculate response latency (estimate based on token delta)
# Note: prev_total and current_total already calculated earlier for message count
token_delta=$((current_total - prev_total))

# Update metrics file
echo "$current_total" > "$session_metrics"

# Simulate response time based on token delta (rough estimate)
if [ "$token_delta" -gt 0 ]; then
    # Estimate: ~50 tokens/second for output generation
    response_time_ms=$((token_delta * 20))  # Rough estimate: 20ms per token
else
    response_time_ms=0
fi

if [ "$response_time_ms" -gt 1000 ]; then
    response_time=$(echo "scale=1; $response_time_ms / 1000" | bc)s
elif [ "$response_time_ms" -gt 0 ]; then
    response_time="${response_time_ms}ms"
else
    response_time="-"
fi

# Calculate cache efficiency
cache_total=$((cache_creation_tokens + cache_read_tokens))
if [ "$cache_total" -gt 0 ] && [ "$total_input" -gt 0 ]; then
    cache_efficiency=$((cache_read_tokens * 100 / total_input))
else
    cache_efficiency=0
fi

# Calculate actual rate limit reset time and usage
# Try multiple sources for actual session data
# Flag to track if we have real data
has_real_rate_limit_data=false

# Check environment variables first
if [ -n "$CLAUDE_SESSION_USAGE_PCT" ]; then
    rate_limit_pct=$((100 - CLAUDE_SESSION_USAGE_PCT))
    has_real_rate_limit_data=true
elif [ -n "$session_usage_pct" ] && [ "$session_usage_pct" != "null" ] && [ "$session_usage_pct" != "" ]; then
    rate_limit_pct=$((100 - session_usage_pct))
    has_real_rate_limit_data=true
else
    # Try to read from Claude session files
    claude_stats_file="$HOME/.claude/stats-cache.json"
    if [ -f "$claude_stats_file" ]; then
        session_usage_pct=$(jq -r '.session.usage_percent // empty' "$claude_stats_file" 2>/dev/null)
        if [ -n "$session_usage_pct" ] && [ "$session_usage_pct" != "null" ]; then
            rate_limit_pct=$((100 - session_usage_pct))
            has_real_rate_limit_data=true
        fi
    fi
fi

# Only calculate reset time if we have real data
if [ "$has_real_rate_limit_data" = true ]; then
    # Calculate reset time
    # Claude sessions typically reset at :59 minutes past the hour
    current_hour=$(date +%H)
    current_minute=$(date +%M)
    current_second=$(date +%S)

    # If we have actual reset time from API data
    if [ -n "$session_reset_time" ] && [ "$session_reset_time" != "null" ] && [ "$session_reset_time" != "" ]; then
        # Parse reset time (format might be ISO 8601 or Unix timestamp)
        if [[ "$session_reset_time" =~ ^[0-9]+$ ]]; then
            # Unix timestamp
            reset_timestamp=$session_reset_time
        else
            # Try to parse as date string
            reset_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${session_reset_time:0:19}" +%s 2>/dev/null || echo "0")
        fi

        if [ "$reset_timestamp" -gt 0 ]; then
            seconds_until_reset=$((reset_timestamp - current_time))
        fi
    fi

    # Fallback: Calculate based on :59 minute reset pattern
    if [ -z "$seconds_until_reset" ] || [ "$seconds_until_reset" -le 0 ]; then
        # Calculate seconds until next :59 minute mark
        if [ "$current_minute" -lt 59 ]; then
            # Reset at current hour :59
            target_minute=59
            minutes_until=$((target_minute - current_minute))
            seconds_until_reset=$((minutes_until * 60 - current_second))
        else
            # Reset at next hour :59
            minutes_until=$((60 - current_minute))
            seconds_until_reset=$((minutes_until * 60 + (59 * 60) - current_second))
        fi
    fi

    # Format time until reset
    if [ "$seconds_until_reset" -ge 3600 ]; then
        hours=$((seconds_until_reset / 3600))
        remaining=$((seconds_until_reset % 3600))
        minutes=$((remaining / 60))
        if [ "$minutes" -gt 0 ]; then
            rate_limit_time="${hours}h ${minutes}m"
        else
            rate_limit_time="${hours}h"
        fi
    elif [ "$seconds_until_reset" -ge 60 ]; then
        minutes=$((seconds_until_reset / 60))
        rate_limit_time="${minutes}m"
    else
        rate_limit_time="${seconds_until_reset}s"
    fi
fi

# Calculate directory display (show only directory name, not full path)
dir=$(basename "$current_dir")

# Get git information with push/pull indicators and file changes
git_info=""
if git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$current_dir" -c core.fileMode=false --no-optional-locks branch --show-current 2>/dev/null || echo "detached")

    # Check for uncommitted changes
    if ! git -C "$current_dir" -c core.fileMode=false --no-optional-locks diff --quiet 2>/dev/null || \
       ! git -C "$current_dir" -c core.fileMode=false --no-optional-locks diff --cached --quiet 2>/dev/null; then
        status="*"
    else
        status=""
    fi

    # Get file change counts (added/removed)
    file_changes=""
    git_status=$(git -C "$current_dir" -c core.fileMode=false --no-optional-locks status --porcelain 2>/dev/null)
    if [ -n "$git_status" ]; then
        # Count new/added files (A, ??)
        added=$(echo "$git_status" | grep -c "^A\|^??" || echo "0")
        # Count deleted files (D)
        removed=$(echo "$git_status" | grep -c "^ D\|^D" || echo "0")

        if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
            file_changes=" "
            [ "$added" -gt 0 ] && file_changes+="+${added}"
            [ "$removed" -gt 0 ] && file_changes+="-${removed}"
        fi
    fi

    # Check for push/pull status with remote
    sync_indicator=""
    if [ "$branch" != "detached" ]; then
        # Get remote tracking branch
        remote_branch=$(git -C "$current_dir" -c core.fileMode=false --no-optional-locks rev-parse --abbrev-ref @{upstream} 2>/dev/null)

        if [ -n "$remote_branch" ]; then
            # Count commits ahead and behind
            ahead=$(git -C "$current_dir" -c core.fileMode=false --no-optional-locks rev-list --count @{upstream}..HEAD 2>/dev/null || echo "0")
            behind=$(git -C "$current_dir" -c core.fileMode=false --no-optional-locks rev-list --count HEAD..@{upstream} 2>/dev/null || echo "0")

            if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
                sync_indicator="↕${ahead}↓${behind}"  # Diverged
            elif [ "$ahead" -gt 0 ]; then
                sync_indicator="↑${ahead}"  # Ahead
            elif [ "$behind" -gt 0 ]; then
                sync_indicator="↓${behind}"  # Behind
            else
                sync_indicator="="  # In sync
            fi
        fi
    fi

    # Build git info with nice spacing, using printf to create colored output
    git_info=$(printf "⎇  \033[36m%s\033[0m" "$branch")  # Cyan branch with git symbol and extra space

    # Add status indicator (yellow for uncommitted changes)
    if [ -n "$status" ]; then
        git_info+=$(printf " \033[33m%s%s" "$status")  # Yellow with space
    fi

    # Add sync indicator with appropriate color
    if [ -n "$sync_indicator" ]; then
        git_info+=" "  # Add space before sync indicator
        if [[ "$sync_indicator" == "=" ]]; then
            git_info+=$(printf "\033[32m%s%s" "$sync_indicator")  # Green
        elif [[ "$sync_indicator" == ↑* ]]; then
            git_info+=$(printf "\033[33m%s%s" "$sync_indicator")  # Yellow
        elif [[ "$sync_indicator" == ↓* ]]; then
            git_info+=$(printf "\033[33m%s%s" "$sync_indicator")  # Yellow
        elif [[ "$sync_indicator" == ↕* ]]; then
            git_info+=$(printf "\033[31m%s%s" "$sync_indicator")  # Red
        fi
    fi

    # Add file changes with colors and spacing
    if [ -n "$file_changes" ]; then
        temp_changes="$file_changes"
        git_info+="  "  # Double space before file changes

        # Extract and color added files
        if [[ "$temp_changes" =~ \+([0-9]+) ]]; then
            git_info+=$(printf "\033[32m+%s%s" "${BASH_REMATCH[1]}")  # Green
        fi

        # Add space between added and removed if both exist
        if [[ "$temp_changes" =~ \+([0-9]+) ]] && [[ "$temp_changes" =~ -([0-9]+) ]]; then
            git_info+=" "
        fi

        # Extract and color removed files
        if [[ "$temp_changes" =~ -([0-9]+) ]]; then
            git_info+=$(printf "\033[31m-%s%s" "${BASH_REMATCH[1]}")  # Red
        fi
    fi
fi

# Get git metrics (last commit time and commits today)
last_commit_time=""
commits_today=""
if git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
    # Get last commit time
    last_commit_epoch=$(git -C "$current_dir" log -1 --format=%ct 2>/dev/null)
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

    # Count commits today
    today_start=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
    if [ -n "$today_start" ]; then
        commit_count=$(git -C "$current_dir" log --since="$today_start" --oneline 2>/dev/null | wc -l | tr -d ' ')
        if [ "$commit_count" -gt 0 ]; then
            commits_today="✓ ${commit_count}"
        fi
    fi
fi

# Calculate context usage percentage
total_tokens=$((total_input + total_output))
percentage=0
if [ "$context_size" -gt 0 ]; then
    percentage=$((total_tokens * 100 / context_size))
    # Cap display percentage at 100%
    display_pct=$percentage
    [ $display_pct -gt 100 ] && display_pct=100
else
    display_pct=0
fi

# Determine color based on usage (green < 50%, yellow 50-80%, red > 80%)
if [ "$percentage" -lt 50 ]; then
    color="\033[32m"  # Green
elif [ "$percentage" -lt 80 ]; then
    color="\033[33m"  # Yellow
else
    color="\033[31m"  # Red
fi
reset="\033[0m"

# Format token count in k/M notation with two decimal places
format_k() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        # Format as M (millions) with 2 decimal places
        local millions=$(echo "scale=2; $num / 1000000" | bc 2>/dev/null || echo "0")
        # Remove trailing zeros and decimal point if not needed
        millions=$(echo "$millions" | sed 's/\.00$//' | sed 's/0$//' | sed 's/\.$//')
        echo "${millions}M"
    elif [ "$num" -ge 1000 ]; then
        # Format as k (thousands) with 2 decimal places
        local thousands=$(echo "scale=2; $num / 1000" | bc 2>/dev/null || echo "0")
        # Remove trailing zeros and decimal point if not needed
        thousands=$(echo "$thousands" | sed 's/\.00$//' | sed 's/0$//' | sed 's/\.$//')
        echo "${thousands}k"
    else
        echo "$num"
    fi
}

formatted_total=$(format_k "$total_tokens")
formatted_context=$(format_k "$context_size")

# Format API metrics with colors
# Handle FREE pricing or numeric costs
if [ "$session_cost" = "FREE" ]; then
    cost_display="Free"
    cost_color="\033[32m"  # Green
else
    # Cost: green if < $0.10, yellow if < $1.00, red if >= $1.00
    cost_display=$(printf "\$%.2f" "$session_cost" 2>/dev/null || echo "\$0.00")
    cost_color="\033[32m"  # Green
    cost_value=$(echo "$session_cost" | bc 2>/dev/null || echo "0")
    if [ $(echo "$cost_value >= 1.00" | bc 2>/dev/null || echo "0") -eq 1 ]; then
        cost_color="\033[31m"  # Red
    elif [ $(echo "$cost_value >= 0.10" | bc 2>/dev/null || echo "0") -eq 1 ]; then
        cost_color="\033[33m"  # Yellow
    fi
fi

# Cache efficiency: green if > 20%, yellow if > 5%, gray otherwise
cache_color="\033[90m"  # Gray
if [ "$cache_efficiency" -gt 20 ]; then
    cache_color="\033[32m"  # Green
elif [ "$cache_efficiency" -gt 5 ]; then
    cache_color="\033[33m"  # Yellow
fi

# Only create rate limit section if we have real data
if [ "$has_real_rate_limit_data" = true ]; then
    # Rate limit: green if > 80%, yellow if > 50%, red otherwise
    rate_color="\033[32m"  # Green
    if [ "$rate_limit_pct" -lt 50 ]; then
        rate_color="\033[31m"  # Red
    elif [ "$rate_limit_pct" -lt 80 ]; then
        rate_color="\033[33m"  # Yellow
    fi

    # Build rate limit section
    rate_limit_section=$(printf " · ${rate_color}≈%d%% %s%s" "$rate_limit_pct" "$rate_limit_time")
else
    rate_limit_section=""
fi

# Output the status line with color and symbols
# Conditionally include cache efficiency only when cache is being used
if [ "$cache_efficiency" -gt 0 ]; then
    cache_section=$(printf " · ${cache_color}⚡%d%%%s" "$cache_efficiency")
else
    cache_section=""
fi

# Get subscription expiration info based on provider (with dynamic countdown)
get_subscription_info() {
    local provider="$1"
    local config_file="$HOME/Scripts/claude-statusline/statusline-config.json"
    local current_timestamp=$(date +%s)
    local expiry_timestamp=""
    local is_renewal=false
    local label=""

    # Check if config file exists
    if [ ! -f "$config_file" ]; then
        echo ""
        return
    fi

    # Read subscription info from JSON
    local subscription_type=$(jq -r ".subscriptions.\"$provider\".type // empty" "$config_file" 2>/dev/null)
    local renewal_date=$(jq -r ".subscriptions.\"$provider\".renewal_date // empty" "$config_file" 2>/dev/null)
    local renewal_day=$(jq -r ".subscriptions.\"$provider\".renewal_day // empty" "$config_file" 2>/dev/null)

    # If no subscription found for this provider, return empty
    if [ -z "$subscription_type" ] || [ -z "$renewal_date" ]; then
        echo ""
        return
    fi

    # Calculate next renewal date
    local renewal_timestamp=$(date -j -f "%Y-%m-%d" "$renewal_date" +%s 2>/dev/null)

    case "$subscription_type" in
        "monthly")
            # Keep advancing by 1 month until we find the next renewal date
            while [ "$renewal_timestamp" -lt "$current_timestamp" ]; do
                local current_month=$(date -j -f "%s" "$renewal_timestamp" +%m 2>/dev/null)
                local current_year=$(date -j -f "%s" "$renewal_timestamp" +%Y 2>/dev/null)

                # Calculate next month
                local next_month=$((10#$current_month + 1))
                local next_year=$current_year

                # Handle year rollover
                if [ $next_month -gt 12 ]; then
                    next_month=1
                    next_year=$((next_year + 1))
                fi

                # Format month with leading zero
                next_month=$(printf "%02d" $next_month)

                # Use renewal_day if specified, otherwise use day from renewal_date
                local day_of_month=${renewal_day:-$(echo "$renewal_date" | cut -d'-' -f3)}

                # Set to specified day of next month
                renewal_timestamp=$(date -j -f "%Y-%m-%d" "${next_year}-${next_month}-${day_of_month}" +%s 2>/dev/null)
            done

            expiry_timestamp=$renewal_timestamp
            is_renewal=true
            label="↻"
            ;;
        "yearly")
            # Keep advancing by 1 year until we find the next renewal date
            while [ "$renewal_timestamp" -lt "$current_timestamp" ]; do
                local current_year=$(date -j -f "%s" "$renewal_timestamp" +%Y 2>/dev/null)
                local next_year=$((current_year + 1))
                local month_day=$(echo "$renewal_date" | cut -d'-' -f2-)
                renewal_timestamp=$(date -j -f "%Y-%m-%d" "${next_year}-${month_day}" +%s 2>/dev/null)
            done

            expiry_timestamp=$renewal_timestamp
            is_renewal=true
            label="↻"
            ;;
        *)
            echo ""
            return
            ;;
    esac

    # Calculate days remaining
    if [ -n "$expiry_timestamp" ]; then
        local seconds_remaining=$((expiry_timestamp - current_timestamp))
        local days_remaining=$((seconds_remaining / 86400))

        # Determine color based on days remaining
        local color_code=""
        if [ "$days_remaining" -lt 0 ]; then
            # Expired - red
            color_code="\033[31m"
            if [ "$is_renewal" = true ]; then
                printf "${color_code}${label} OVERDUE %dd\033[0m" "$((days_remaining * -1))"
            else
                printf "${color_code}${label} EXPIRED %dd ago\033[0m" "$((days_remaining * -1))"
            fi
        elif [ "$days_remaining" -eq 0 ]; then
            # Today - red
            color_code="\033[31m"
            printf "${color_code}${label} TODAY\033[0m"
        elif [ "$days_remaining" -le 7 ]; then
            # 1-7 days - red (urgent)
            color_code="\033[31m"
            printf "${color_code}${label} %dd\033[0m" "$days_remaining"
        elif [ "$days_remaining" -le 30 ]; then
            # 8-30 days - yellow (warning)
            color_code="\033[33m"
            printf "${color_code}${label} %dd\033[0m" "$days_remaining"
        else
            # 30+ days - gray (normal)
            color_code="\033[90m"
            printf "${color_code}${label} %dd\033[0m" "$days_remaining"
        fi
    else
        echo ""
    fi
}

subscription_info=$(get_subscription_info "$provider_name")

# Format provider name with cyan color
# Removed cyan color
if [ -n "$subscription_info" ]; then
    provider_section=$(printf "\033[36m%s\033[0m %s" "$provider_name" "$subscription_info")
else
    provider_section=$(printf "\033[36m%s\033[0m" "$provider_name")
fi

# Build AI/Claude Code info sections
ai_info=""

# Message count (if > 0)
if [ "$message_count" -gt 0 ]; then
    ai_info+=$(printf " · \033[36m%d msg\033[0m%s" "$message_count")
fi


# Tools count (if any available)
if [ "$tools_count" -gt 0 ]; then
    ai_info+=$(printf " · \033[90m⚙ %d tools\033[0m%s" "$tools_count")
fi

# Build git info section
git_line=""
if [ -n "$git_info" ]; then
    git_line+="$git_info"
fi

# Add git metrics to git line
# Last commit time (if in git repo)
if [ -n "$last_commit_time" ]; then
    git_line+=$(printf " · \033[90m%s\033[0m%s" "$last_commit_time")  # Gray - last commit
fi

# Commits today (if any)
if [ -n "$commits_today" ]; then
    git_line+=$(printf " · \033[32m%s today%s" "$commits_today")  # Green - commits today
fi

# Build development environment info sections
dev_info=""

# Programming language (if detected)
if [ -n "$prog_lang" ]; then
    dev_info+=$(printf "%s%s" "$prog_lang")  # Cyan - language
fi

# Package manager (if detected)
if [ -n "$package_manager" ]; then
    if [ -n "$dev_info" ]; then
        dev_info+=$(printf " · %s%s" "$package_manager")  # Gray - package manager
    else
        dev_info+=$(printf "%s%s" "$package_manager")  # Gray - package manager
    fi
fi

# Linting errors (if any)
if [ -n "$lint_errors" ]; then
    if [ -n "$dev_info" ]; then
        dev_info+=$(printf " · \033[33m%s lint%s" "$lint_errors")  # Yellow - warnings
    else
        dev_info+=$(printf "\033[33m%s lint%s" "$lint_errors")  # Yellow - warnings
    fi
fi

# Running servers (if any)
if [ -n "$running_servers" ]; then
    if [ -n "$dev_info" ]; then
        dev_info+=$(printf " · \033[32m%s%s" "$running_servers")  # Green - active servers with ports
    else
        dev_info+=$(printf "\033[32m%s%s" "$running_servers")  # Green - active servers with ports
    fi
fi

# Build response time/duration display
duration_display=""
if [ -n "$json_duration" ] && [ "$json_duration" != "null" ] && [ "$json_duration" != "" ]; then
    # Convert ms to h/m/s format
    total_seconds=$((json_duration / 1000))

    if [ "$total_seconds" -ge 3600 ]; then
        # Has hours
        hours=$((total_seconds / 3600))
        remaining=$((total_seconds % 3600))
        minutes=$((remaining / 60))
        seconds=$((remaining % 60))

        if [ "$minutes" -gt 0 ] && [ "$seconds" -gt 0 ]; then
            duration_display=$(printf " · ⚡ %dh %dm %ds" "$hours" "$minutes" "$seconds")
        elif [ "$minutes" -gt 0 ]; then
            duration_display=$(printf " · ⚡ %dh %dm" "$hours" "$minutes")
        else
            duration_display=$(printf " · ⚡ %dh" "$hours")
        fi
    elif [ "$total_seconds" -ge 60 ]; then
        # Has minutes
        minutes=$((total_seconds / 60))
        seconds=$((total_seconds % 60))

        if [ "$seconds" -gt 0 ]; then
            duration_display=$(printf " · ⚡ %dm %ds" "$minutes" "$seconds")
        else
            duration_display=$(printf " · ⚡ %dm" "$minutes")
        fi
    elif [ "$total_seconds" -gt 0 ]; then
        # Only seconds
        duration_display=$(printf " · ⚡ %ds" "$total_seconds")
    else
        # Milliseconds (< 1 second)
        duration_display=$(printf " · ⚡ ${json_duration}ms")
    fi
elif [ -n "$response_time" ] && [ "$response_time" != "-" ]; then
    duration_display=$(printf " · ⚡ %s" "$response_time")
fi

# Build lines changed section (if any)
lines_changed_section=""
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
    if [ "$lines_added" -gt 0 ] && [ "$lines_removed" -gt 0 ]; then
        lines_changed_section=$(printf " · \033[32m+%d\033[0m \033[31m-%d\033[0m lines" "$lines_added" "$lines_removed")
    elif [ "$lines_added" -gt 0 ]; then
        lines_changed_section=$(printf " · \033[32m+%d\033[0m lines" "$lines_added")
    elif [ "$lines_removed" -gt 0 ]; then
        lines_changed_section=$(printf " · \033[31m-%d\033[0m lines" "$lines_removed")
    fi
fi

# Determine which cost to use (JSON if available, otherwise calculated)
final_cost_display=""
final_cost_color=""
if [ -n "$json_cost" ] && [ "$json_cost" != "null" ] && [ "$json_cost" != "" ]; then
    final_cost_display=$(printf "\$%.2f" "$json_cost" 2>/dev/null || echo "\$0.00")
    # Apply color based on cost value
    cost_value=$(echo "$json_cost" | bc 2>/dev/null || echo "0")
    if [ $(echo "$cost_value >= 1.00" | bc 2>/dev/null || echo "0") -eq 1 ]; then
        final_cost_color="\033[31m"  # Red
    elif [ $(echo "$cost_value >= 0.10" | bc 2>/dev/null || echo "0") -eq 1 ]; then
        final_cost_color="\033[33m"  # Yellow
    else
        final_cost_color="\033[32m"  # Green
    fi
else
    final_cost_display="$cost_display"
    final_cost_color="$cost_color"
fi

# Line 1 (Cost): 💰 emoji prefix - Cost information first
printf "  💰"

# Show cost first
if [ "$session_cost" = "FREE" ]; then
    printf " \033[33mFree\033[0m"
else
    printf " \033[33m%s\033[0m" "$final_cost_display"
fi

# Add provider and model
printf " · %s · %s" "$provider_section" "$model"

# Add duration
printf " · %s" "$duration"

# Add token usage
printf " · \033[36m↑ %s\033[0m · \033[35m↓ %s\033[0m" \
    "$(format_k "$total_input")" \
    "$(format_k "$total_output")"

# Add message count (if > 0)
if [ "$message_count" -gt 0 ]; then
    printf " · \033[36m%d msg\033[0m" "$message_count"
fi

# Add lines changed
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
    if [ "$lines_added" -gt 0 ] && [ "$lines_removed" -gt 0 ]; then
        printf " · \033[32m+%d\033[0m/\033[31m-%d\033[0m" "$lines_added" "$lines_removed"
    elif [ "$lines_added" -gt 0 ]; then
        printf " · \033[32m+%d\033[0m" "$lines_added"
    elif [ "$lines_removed" -gt 0 ]; then
        printf " · \033[31m-%d\033[0m" "$lines_removed"
    fi
fi

# Add session statistics (tool calls, files edited, bash commands)
stats_parts=()
if [ "$tool_calls_count" -gt 0 ]; then
    stats_parts+=("🔧 $tool_calls_count")
fi
if [ "$files_edited_count" -gt 0 ]; then
    stats_parts+=("✏ $files_edited_count")
fi
if [ "$bash_commands_count" -gt 0 ]; then
    stats_parts+=("⚡ $bash_commands_count")
fi

# Display stats if any exist
if [ ${#stats_parts[@]} -gt 0 ]; then
    stats_display=$(IFS=' · '; echo "${stats_parts[*]}")
    printf " · \033[90m%s\033[0m" "$stats_display"
fi

# Add folder name to line 1 if NOT in a git repository
if [ -z "$git_line" ]; then
    printf " · 📁 %s" "$dir"
fi

printf "\n"

# Line 2 (Git/Directory): Only show if in a git repository
if [ -n "$git_line" ]; then
    printf "  📁 %s %s\n" "$dir" "$git_line"
fi

# Line 4 (Dev): 🔧 emoji prefix - Running servers and development info (only show if there's content)
if [ -n "$dev_info" ]; then
    printf "  🔧 %s\n" "$dev_info"
fi
