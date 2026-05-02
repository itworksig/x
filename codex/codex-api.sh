#!/usr/bin/env bash
set -euo pipefail

# ---------- Color ----------
info()    { printf "\033[36m[INFO]\033[0m %s\n" "$*"; }
success() { printf "\033[32m[OK]\033[0m   %s\n" "$*"; }
err()     { printf "\033[31m[ERR]\033[0m  %s\n" "$*" >&2; }
warn()    { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }

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

download_file() {
    local url="$1"
    local output="$2"

    info "Downloading: $url"
    curl --fail --location --show-error --silent "$url" --output "$output"
}

escape_json_string() {
    local value="$1"

    if command -v node &>/dev/null; then
        node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$value"
    else
        jq -Rn --arg value "$value" '$value'
    fi
}

escape_toml_basic_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

# ---------- Detect OS ----------
OS="$(uname -s)"

# ---------- Install Node.js ----------
install_node() {
    if command -v node &>/dev/null; then
        success "Node.js already installed: $(node -v)"
        return
    fi

    info "Installing Node.js..."

    if [ "$OS" = "Darwin" ]; then
        if command -v brew &>/dev/null; then
            info "Installing Node.js with Homebrew..."
            brew install node
        else
            local node_version="v22.16.0"
            local arch
            local pkg_path="/tmp/node-${node_version}.pkg"

            arch="$(uname -m)"
            case "$arch" in
                arm64|x86_64)
                    ;;
                *)
                    err "Unsupported macOS architecture: $arch"
                    exit 1
                    ;;
            esac

            warn "Homebrew was not found. The script can install the official Node.js LTS pkg with sudo."
            confirm "Install Node.js ${node_version} from nodejs.org?" || {
                err "Node.js installation cancelled"
                exit 1
            }

            download_file "https://nodejs.org/dist/${node_version}/node-${node_version}.pkg" "$pkg_path"
            sudo installer -pkg "$pkg_path" -target /
        fi
    else
        if command -v apt-get &>/dev/null; then
            local setup_script="/tmp/nodesource_setup.sh"

            warn "This will run the downloaded NodeSource setup script with sudo."
            confirm "Continue with NodeSource setup?" || {
                err "Node.js installation cancelled"
                exit 1
            }

            download_file "https://deb.nodesource.com/setup_lts.x" "$setup_script"
            sed -n '1,80p' "$setup_script"
            sudo bash "$setup_script"
            sudo apt-get install -y nodejs
        else
            local nvm_script="/tmp/nvm_install.sh"

            warn "No apt-get found. The script can install nvm from the official nvm-sh repository."
            confirm "Download and run the nvm installer?" || {
                err "Node.js installation cancelled"
                exit 1
            }

            download_file "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh" "$nvm_script"
            sed -n '1,80p' "$nvm_script"
            bash "$nvm_script"
            export NVM_DIR="$HOME/.nvm"
            source "$NVM_DIR/nvm.sh"
            nvm install --lts
        fi
    fi

    success "Node installed: $(node -v)"
}

# ---------- Install Codex ----------
install_codex() {
    if command -v codex &>/dev/null; then
        success "codex already installed"
        return
    fi

    info "Installing codex..."
    npm install -g @openai/codex --registry https://registry.npmmirror.com
    success "codex installed"
}

# ---------- Detect Current Mode ----------
detect_mode() {
    if [ -f "$HOME/.codex/auth.json" ]; then
        info "Current mode: API Key"
    else
        info "Current mode: Account Login / Not configured"
    fi
}

# ---------- API Mode ----------
setup_api_mode() {
    echo ""
    echo "---- API Mode ----"

    local BASE_URL API_KEY BASE_URL_TOML API_KEY_JSON

    printf "Enter API Base URL: "
    read -r BASE_URL
    BASE_URL="$(trim "$BASE_URL")"

    while [ -z "$BASE_URL" ]; do
        err "Base URL cannot be empty"
        read -r BASE_URL
        BASE_URL="$(trim "$BASE_URL")"
    done

    printf "Enter API Key: "
    read -rs API_KEY
    echo ""
    API_KEY="$(trim "$API_KEY")"

    while [ -z "$API_KEY" ]; do
        err "API Key cannot be empty"
        printf "Enter API Key: "
        read -rs API_KEY
        echo ""
        API_KEY="$(trim "$API_KEY")"
    done

    mkdir -p "$HOME/.codex"
    BASE_URL_TOML="$(escape_toml_basic_string "$BASE_URL")"
    API_KEY_JSON="$(escape_json_string "$API_KEY")"

    cat > "$HOME/.codex/config.toml" <<EOF
model_provider = "codex"
model = "gpt-5.4"
model_reasoning_effort = "high"
disable_response_storage = true

[model_providers.codex]
name = "codex"
base_url = "$BASE_URL_TOML"
wire_api = "responses"
requires_openai_auth = true
EOF

    cat > "$HOME/.codex/auth.json" <<EOF
{
  "OPENAI_API_KEY": $API_KEY_JSON
}
EOF

    chmod 600 "$HOME/.codex/config.toml" "$HOME/.codex/auth.json"

    success "Switched to API mode"
}

# ---------- Account Mode ----------
setup_account_mode() {
    echo ""
    echo "---- Account Login Mode ----"

    rm -rf "$HOME/.codex"
    unset OPENAI_API_KEY || true

    success "Cleared API config"

    echo "Opening login..."
    codex login || codex

    success "Logged in with account"
}

# ---------- MAIN ----------
clear
echo "======================================"
echo "   Codex Installer & Mode Switcher"
echo "======================================"

install_node
install_codex
detect_mode

echo ""
echo "Select Mode:"
echo "1) API Key Mode"
echo "2) Account Login Mode"
echo ""

printf "Enter choice (1 or 2): "
read -r MODE

case "$MODE" in
    1)
        setup_api_mode
        ;;
    2)
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
echo "Run: codex"
echo ""
