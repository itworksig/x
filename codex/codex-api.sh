```bash
#!/usr/bin/env bash
set -euo pipefail

info()    { printf "\033[36m[INFO]\033[0m %s\n" "$*"; }
success() { printf "\033[32m[OK]\033[0m   %s\n" "$*"; }
err()     { printf "\033[31m[ERR]\033[0m  %s\n" "$*" >&2; }
warn()    { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CODEX_HOME/config.toml"
AUTH_FILE="$CODEX_HOME/auth.json"

trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

confirm() {
    local prompt="$1"
    local answer

    printf "%s [y/N]: " "$prompt"
    read -r answer

    case "$(trim "$answer")" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

escape_json_string() {
    local value="$1"

    if command -v node &>/dev/null; then
        node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$value"
    elif command -v jq &>/dev/null; then
        jq -Rn --arg value "$value" '$value'
    else
        python3 -c 'import json, sys; print(json.dumps(sys.argv[1]), end="")' "$value"
    fi
}

backup_file() {
    local path="$1"

    if [ -f "$path" ]; then
        local backup="${path}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$path" "$backup"
        success "Backed up $path -> $backup"
    fi
}

detect_mode() {
    if [ -f "$AUTH_FILE" ]; then
        info "Current mode: API Key or saved auth file"
    else
        info "Current mode: Account Login / Not configured"
    fi
}

write_api_auth() {
    local api_key="$1"
    local api_key_json

    api_key_json="$(escape_json_string "$api_key")"
    cat > "$AUTH_FILE" <<EOF
{
  "OPENAI_API_KEY": $api_key_json
}
EOF
    chmod 600 "$AUTH_FILE"
}

patch_config_for_api() {
    local base_url="$1"
    local model="${2:-gpt-5.4}"
    local effort="${3:-high}"

    export CONFIG_FILE base_url model effort

    python3 <<'PY'
from pathlib import Path
import os

path = Path(os.environ["CONFIG_FILE"])
base_url = os.environ["base_url"]
model = os.environ["model"]
effort = os.environ["effort"]

text = path.read_text() if path.exists() else ""
lines = text.splitlines()

top_updates = {
    "model_provider": '"codex"',
    "model": f'"{model}"',
    "model_reasoning_effort": f'"{effort}"',
    "disable_response_storage": "true",
}

new_lines = []
seen = set()
i = 0

while i < len(lines):
    line = lines[i]
    stripped = line.strip()

    if stripped == "[model_providers.codex]":
        i += 1
        while i < len(lines) and not lines[i].lstrip().startswith("["):
            i += 1
        continue

    if stripped and not stripped.startswith("#") and "=" in line and not line.startswith("["):
        key = line.split("=", 1)[0].strip()
        if key in top_updates:
            new_lines.append(f"{key} = {top_updates[key]}")
            seen.add(key)
            i += 1
            continue

    new_lines.append(line)
    i += 1

insert_at = 0
while insert_at < len(new_lines):
    stripped = new_lines[insert_at].strip()
    if stripped.startswith("["):
        break
    insert_at += 1

missing = [f"{key} = {value}" for key, value in top_updates.items() if key not in seen]

if missing:
    while insert_at > 0 and new_lines[insert_at - 1].strip() == "":
        insert_at -= 1
    new_lines[insert_at:insert_at] = missing + [""]

escaped_base_url = base_url.replace("\\", "\\\\").replace('"', '\\"')

block = [
    "",
    "[model_providers.codex]",
    'name = "codex"',
    f'base_url = "{escaped_base_url}"',
    'wire_api = "responses"',
    "requires_openai_auth = true",
]

while new_lines and new_lines[-1].strip() == "":
    new_lines.pop()

new_lines.extend(block)

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(new_lines) + "\n")
PY

    chmod 600 "$CONFIG_FILE"
}

setup_api_mode() {
    echo ""
    echo "---- API Key Mode ----"

    local base_url api_key model effort

    printf "Enter API Base URL: "
    read -r base_url
    base_url="$(trim "$base_url")"

    while [ -z "$base_url" ]; do
        err "Base URL cannot be empty"
        printf "Enter API Base URL: "
        read -r base_url
        base_url="$(trim "$base_url")"
    done

    printf "Enter API Key: "
    read -rs api_key
    echo ""
    api_key="$(trim "$api_key")"

    while [ -z "$api_key" ]; do
        err "API Key cannot be empty"
        printf "Enter API Key: "
        read -rs api_key
        echo ""
        api_key="$(trim "$api_key")"
    done

    printf "Model [gpt-5.4]: "
    read -r model
    model="$(trim "$model")"
    model="${model:-gpt-5.4}"

    printf "Reasoning effort [high]: "
    read -r effort
    effort="$(trim "$effort")"
    effort="${effort:-high}"

    mkdir -p "$CODEX_HOME"
    backup_file "$CONFIG_FILE"
    backup_file "$AUTH_FILE"

    patch_config_for_api "$base_url" "$model" "$effort"
    write_api_auth "$api_key"

    success "Switched to API mode without removing MCP, skills, plugins, sessions, or memory"
}

setup_account_mode() {
    echo ""
    echo "---- Account Login Mode ----"

    mkdir -p "$CODEX_HOME"
    backup_file "$AUTH_FILE"

    rm -f "$AUTH_FILE"
    unset OPENAI_API_KEY || true

    if command -v launchctl &>/dev/null; then
        launchctl unsetenv OPENAI_API_KEY 2>/dev/null || true
    fi

    success "Removed only $AUTH_FILE"
    info "MCP, skills, plugins, sessions, and memory were preserved"

    if command -v codex &>/dev/null; then
        info "Opening Codex login..."
        codex login || codex
    else
        warn "codex command not found. Install Codex first, then run: codex login"
    fi
}

clear
echo "======================================"
echo "   Codex Safe Mode Switcher"
echo "======================================"
echo ""
echo "This script only changes API/account auth."
echo "It preserves MCP, skills, plugins, sessions, and memory."
echo ""

detect_mode

echo ""
echo "Select Mode:"
echo "1) API Key Mode"
echo "2) Account Login Mode"
echo ""

printf "Enter choice (1 or 2): "
read -r mode

case "$mode" in
    1)
        setup_api_mode
        ;;
    2)
        warn "This removes only auth.json, not the whole ~/.codex directory."
        confirm "Continue switching to account login mode?" || {
            err "Cancelled"
            exit 1
        }
        setup_account_mode
        ;;
    *)
        err "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "======================================"
echo " Done!"
echo "======================================"
echo ""
echo "Restart Codex after switching modes."
echo ""
```
