#!/bin/sh

# Tailcat-OneShot
# Minimal one-shot Linux helper for Tailcat.
#
# https://github.com/tailscale/tailcat

set -eu
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
    cleanup_exit_status=$?

    trap - 0 1 2 15

    printf '\nCleaning up...\n'

    if [ -n "${TAILCAT_PID:-}" ]; then
        if kill -0 "$TAILCAT_PID" 2>/dev/null; then
            kill "$TAILCAT_PID" 2>/dev/null || true

            cleanup_attempt=1

            while [ "$cleanup_attempt" -le 20 ]; do
                if ! kill -0 "$TAILCAT_PID" 2>/dev/null; then
                    break
                fi

                sleep 0.1
                cleanup_attempt=$((cleanup_attempt + 1))
            done

            if kill -0 "$TAILCAT_PID" 2>/dev/null; then
                kill -9 "$TAILCAT_PID" 2>/dev/null || true
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

    if [ -n "${RUNTIME_DIR:-}" ] && [ -d "$RUNTIME_DIR" ]; then
        case "${RUNTIME_DIR##*/}" in
            tailcat-oneshot.*)
                rm -rf "$RUNTIME_DIR" || true
                ;;
            *)
                printf '[WARN] Refusing to remove unexpected path: %s\n' \
                    "$RUNTIME_DIR"
                ;;
        esac
    fi

    if [ -n "${RUNTIME_DIR:-}" ] && [ -e "$RUNTIME_DIR" ]; then
        printf '[WARN] Runtime directory remains: %s\n' "$RUNTIME_DIR"
    else
        printf '[OK] Runtime directory removed and verified\n'
    fi

    exit "$cleanup_exit_status"
}


download_tailcat() {
    download_architecture=$1
    version_number=${TAILCAT_VERSION#v}
    archive_name="tailcat_${version_number}_linux_${download_architecture}.tar.gz"
    archive_path="$RUNTIME_DIR/$archive_name"
    checksums_path="$RUNTIME_DIR/checksums.txt"
    expected_hash=""
    actual_hash=""

    printf '\nDownloading Tailcat %s for linux/%s...\n' \
        "$TAILCAT_VERSION" "$download_architecture"

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

    case "$expected_hash" in
        ''|*[!0-9a-f]*)
            fail "SHA256 checksum was not found for $archive_name"
            ;;
    esac

    [ "${#expected_hash}" -eq 64 ] ||
        fail "SHA256 checksum was not found for $archive_name"

    actual_hash="$(sha256sum "$archive_path")"
    actual_hash=${actual_hash%% *}

    [ "$actual_hash" = "$expected_hash" ] ||
        fail "Tailcat SHA256 verification failed"

    printf 'SHA256 verified.\n'

    tar -xzf "$archive_path" -C "$RUNTIME_DIR"

    TAILCAT_BIN="$RUNTIME_DIR/tailcat"

    [ -f "$TAILCAT_BIN" ] ||
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
    client_token=""
    client_socks_port=""

    while :; do
        printf 'Tailcat tc... token: '

        if ! IFS= read -r client_token; then
            printf '\n' >&2
            return 1
        fi

        case "$client_token" in
            tc*)
                break
                ;;
        esac
    done

    printf 'Local SOCKS5 port [1080]: '

    if ! IFS= read -r client_socks_port; then
        printf '\n' >&2
        return 1
    fi

    client_socks_port=${client_socks_port:-1080}

    case "$client_socks_port" in
        ''|*[!0-9]*)
            fail "SOCKS5 port must be a number"
            ;;
    esac

    while [ "${client_socks_port#0}" != "$client_socks_port" ]; do
        client_socks_port=${client_socks_port#0}
    done

    client_socks_port=${client_socks_port:-0}

    [ "${#client_socks_port}" -le 5 ] &&
        [ "$client_socks_port" -ge 1 ] &&
        [ "$client_socks_port" -le 65535 ] ||
        fail "SOCKS5 port must be between 1 and 65535"

    show_runtime_info

    printf '\nStarting Tailcat SOCKS5 proxy with these settings:\n\n'
    printf 'SOCKS5 host : 127.0.0.1\n'
    printf 'SOCKS5 port : %s\n' "$client_socks_port"
    printf 'Proxy DNS   : enable it in the application when available\n'
    printf '\nConfigure Firefox, PuTTY or another application manually.\n'
    printf 'Press Ctrl+C to disconnect and clean up.\n\n'

    run_tailcat \
        --key=new \
        socks \
        --listen="$client_socks_port" \
        "$client_token"
}


main() {
    choice=""
    architecture=""
    temp_base=${TMPDIR:-/tmp}

    printf '%s\n' 'Tailcat-OneShot for Linux'
    printf '%s\n\n' '========================='
    printf '%s\n' '[1] SERVER'
    printf '%s\n\n' '    Expose this machine/network as a Tailcat exit-node'
    printf '%s\n' '[2] CLIENT'
    printf '%s\n\n' '    Start a local SOCKS5 proxy for manual configuration'
    printf '%s\n\n' '[Q] Quit'

    printf 'Select: '

    if ! IFS= read -r choice; then
        printf '\n' >&2
        return 1
    fi

    case "$choice" in
        1|2)
            ;;
        q|Q)
            return 0
            ;;
        *)
            fail "Invalid selection"
            ;;
    esac

    require_commands
    architecture="$(detect_architecture)"

    if [ ! -d "$temp_base" ] || [ ! -w "$temp_base" ]; then
        fail "Temporary directory is not writable: $temp_base"
    fi

    RUNTIME_DIR="$(mktemp -d "$temp_base/tailcat-oneshot.XXXXXXXX")"

    trap cleanup 0
    trap 'exit 130' 2
    trap 'exit 143' 15
    trap 'exit 129' 1

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
