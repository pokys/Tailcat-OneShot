#!/usr/bin/env bash

# Tailcat-OneShot
# Minimal one-shot Linux helper for Tailcat.
#
# https://github.com/tailscale/tailcat

set -euo pipefail
IFS=$'\n\t'
umask 077

TAILCAT_VERSION="v0.4.0"
RELEASE_BASE_URL="https://github.com/tailscale/tailcat/releases/download"

RUNTIME_DIR=""
TAILCAT_BIN=""
TAILCAT_PID=""


fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}


require_commands() {
    local command_name

    for command_name in curl tar sha256sum awk mktemp uname; do
        command -v "$command_name" >/dev/null 2>&1 ||
            fail "Required command was not found: $command_name"
    done
}


detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'amd64\n'
            ;;
        aarch64|arm64)
            printf 'arm64\n'
            ;;
        armv7l|armv7)
            printf 'armv7\n'
            ;;
        *)
            fail "Unsupported Linux architecture: $(uname -m)"
            ;;
    esac
}


cleanup() {
    local exit_status=$?
    local attempt

    trap - EXIT INT TERM HUP

    printf '\nCleaning up...\n'

    if [[ -n "${TAILCAT_PID:-}" ]]; then
        if kill -0 "$TAILCAT_PID" 2>/dev/null; then
            kill "$TAILCAT_PID" 2>/dev/null || true

            for attempt in {1..20}; do
                if ! kill -0 "$TAILCAT_PID" 2>/dev/null; then
                    break
                fi

                sleep 0.1
            done

            if kill -0 "$TAILCAT_PID" 2>/dev/null; then
                kill -KILL "$TAILCAT_PID" 2>/dev/null || true
            fi
        fi

        wait "$TAILCAT_PID" 2>/dev/null || true

        if kill -0 "$TAILCAT_PID" 2>/dev/null; then
            printf '[WARN] Tailcat process remains: %s\n' "$TAILCAT_PID"
        else
            printf '[OK] Tailcat stopped and verified\n'
        fi
    else
        printf '[OK] No Tailcat process to stop\n'
    fi

    if [[ -n "${RUNTIME_DIR:-}" && -d "$RUNTIME_DIR" ]]; then
        if [[ "${RUNTIME_DIR##*/}" == tailcat-oneshot.* ]]; then
            rm -rf -- "$RUNTIME_DIR" || true
        else
            printf '[WARN] Refusing to remove unexpected path: %s\n' \
                "$RUNTIME_DIR"
        fi
    fi

    if [[ -n "${RUNTIME_DIR:-}" && -e "$RUNTIME_DIR" ]]; then
        printf '[WARN] Runtime directory remains: %s\n' "$RUNTIME_DIR"
    else
        printf '[OK] Runtime directory removed and verified\n'
    fi

    exit "$exit_status"
}


download_tailcat() {
    local architecture=$1
    local version_number=${TAILCAT_VERSION#v}
    local archive_name="tailcat_${version_number}_linux_${architecture}.tar.gz"
    local archive_path="$RUNTIME_DIR/$archive_name"
    local checksums_path="$RUNTIME_DIR/checksums.txt"
    local expected_hash
    local actual_hash

    printf '\nDownloading Tailcat %s for linux/%s...\n' \
        "$TAILCAT_VERSION" "$architecture"

    curl \
        --disable \
        --fail \
        --location \
        --silent \
        --show-error \
        --output "$archive_path" \
        "$RELEASE_BASE_URL/$TAILCAT_VERSION/$archive_name"

    curl \
        --disable \
        --fail \
        --location \
        --silent \
        --show-error \
        --output "$checksums_path" \
        "$RELEASE_BASE_URL/$TAILCAT_VERSION/checksums.txt"

    expected_hash="$(
        awk -v archive="$archive_name" \
            '$2 == archive { print tolower($1); exit }' \
            "$checksums_path"
    )"

    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] ||
        fail "SHA256 checksum was not found for $archive_name"

    actual_hash="$(sha256sum "$archive_path" | awk '{ print tolower($1) }')"

    [[ "$actual_hash" == "$expected_hash" ]] ||
        fail "Tailcat SHA256 verification failed"

    printf 'SHA256 verified.\n'

    tar -xzf "$archive_path" -C "$RUNTIME_DIR"

    TAILCAT_BIN="$RUNTIME_DIR/tailcat"

    [[ -f "$TAILCAT_BIN" ]] ||
        fail "Tailcat executable was not found after extraction"

    chmod 700 "$TAILCAT_BIN"
}


prepare_runtime_environment() {
    export HOME="$RUNTIME_DIR/home"
    export XDG_CONFIG_HOME="$RUNTIME_DIR/xdg/config"
    export XDG_CACHE_HOME="$RUNTIME_DIR/xdg/cache"
    export XDG_DATA_HOME="$RUNTIME_DIR/xdg/data"
    export XDG_STATE_HOME="$RUNTIME_DIR/xdg/state"
    export TMPDIR="$RUNTIME_DIR/tmp"

    mkdir -p \
        "$HOME" \
        "$XDG_CONFIG_HOME" \
        "$XDG_CACHE_HOME" \
        "$XDG_DATA_HOME" \
        "$XDG_STATE_HOME" \
        "$TMPDIR"
}


show_runtime_info() {
    printf '\nRuntime information\n'
    printf '%s\n' '-------------------'
    printf 'Tailcat version : %s\n' "$TAILCAT_VERSION"
    printf 'Temporary path  : %s\n' "$RUNTIME_DIR"
    printf '\n'
    printf '%s\n' 'Tailcat-OneShot does NOT intentionally modify:'
    printf '%s\n' '  - installed packages'
    printf '%s\n' '  - firewall rules'
    printf '%s\n' '  - system proxy settings'
    printf '%s\n' '  - routing or network interfaces'
    printf '%s\n' '  - services or startup configuration'
    printf '%s\n' '  - persistent environment variables'
}


run_tailcat() {
    "$TAILCAT_BIN" "$@" &
    TAILCAT_PID=$!

    wait "$TAILCAT_PID"
}


run_server() {
    show_runtime_info

    printf '\nStarting Tailcat exit-node...\n\n'
    printf '%s\n' 'Share the generated tc... token with the client.'
    printf '%s\n\n' 'Press Ctrl+C to stop and clean up.'

    run_tailcat --key=new serve exit-node
}


run_client() {
    local token=""
    local socks_port=""
    local port_number

    while [[ "$token" != tc* ]]; do
        if ! IFS= read -r -p "Tailcat tc... token: " token; then
            printf '\n' >&2
            return 1
        fi
    done

    if ! IFS= read -r -p "Local SOCKS5 port [1080]: " socks_port; then
        printf '\n' >&2
        return 1
    fi

    socks_port=${socks_port:-1080}

    [[ "$socks_port" =~ ^[0-9]+$ ]] ||
        fail "SOCKS5 port must be a number"

    port_number=$((10#$socks_port))

    ((port_number >= 1 && port_number <= 65535)) ||
        fail "SOCKS5 port must be between 1 and 65535"

    socks_port=$port_number

    show_runtime_info

    printf '\nStarting Tailcat SOCKS5 proxy with these settings:\n\n'
    printf 'SOCKS5 host : 127.0.0.1\n'
    printf 'SOCKS5 port : %s\n' "$socks_port"
    printf 'Proxy DNS   : enable it in the application when available\n'
    printf '\nConfigure Firefox, PuTTY or another application manually.\n'
    printf 'Press Ctrl+C to disconnect and clean up.\n\n'

    run_tailcat \
        --key=new \
        socks \
        --listen="$socks_port" \
        "$token"
}


main() {
    local choice
    local architecture
    local temp_base=${TMPDIR:-/tmp}

    printf '%s\n' 'Tailcat-OneShot for Linux'
    printf '%s\n\n' '========================='
    printf '%s\n' '[1] SERVER'
    printf '%s\n\n' '    Expose this machine/network as a Tailcat exit-node'
    printf '%s\n' '[2] CLIENT'
    printf '%s\n\n' '    Start a local SOCKS5 proxy for manual configuration'
    printf '%s\n\n' '[Q] Quit'

    if ! IFS= read -r -p "Select: " choice; then
        printf '\n' >&2
        return 1
    fi

    case "${choice^^}" in
        1|2)
            ;;
        Q)
            return 0
            ;;
        *)
            fail "Invalid selection"
            ;;
    esac

    require_commands
    architecture="$(detect_architecture)"

    [[ -d "$temp_base" && -w "$temp_base" ]] ||
        fail "Temporary directory is not writable: $temp_base"

    RUNTIME_DIR="$(mktemp -d "$temp_base/tailcat-oneshot.XXXXXXXX")"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    download_tailcat "$architecture"
    prepare_runtime_environment

    case "$choice" in
        1)
            run_server
            ;;
        2)
            run_client
            ;;
    esac
}


main "$@"
