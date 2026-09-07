#!/bin/sh

# Tailcat-OneShot
# Minimal one-shot Linux helper for Tailcat.
#
# https://github.com/tailscale/tailcat

set -eu
umask 077

TAILCAT_VERSION="v0.6.0"
RELEASE_BASE_URL="https://github.com/tailscale/tailcat/releases/download"

RUNTIME_DIR=""
RUNTIME_BASE=""
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


stop_tailcat() {

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
            return 1
        else
            printf '[OK] Tailcat stopped and verified\n'
        fi
    else
        printf '[OK] No Tailcat process to stop\n'
    fi
    TAILCAT_PID=""
}


remove_runtime_directory() {
    [ -n "$RUNTIME_DIR" ] || return 0

    # Only remove a direct child of the original, absolute temporary base.
    if [ "${RUNTIME_DIR%/*}/" != "${RUNTIME_BASE%/}/" ] || [ -L "$RUNTIME_DIR" ]; then
        printf '[WARN] Refusing to remove unexpected runtime path: %s\n' "$RUNTIME_DIR"
        return 1
    fi

    case "${RUNTIME_DIR##*/}" in
        tailcat-oneshot.????????) rm -rf -- "$RUNTIME_DIR" || true ;;
        *)
            printf '[WARN] Refusing to remove unexpected runtime path: %s\n' "$RUNTIME_DIR"
            return 1
            ;;
    esac

    if [ -e "$RUNTIME_DIR" ]; then
        printf '[WARN] Runtime directory remains: %s\n' "$RUNTIME_DIR"
        return 1
    else
        printf '[OK] Runtime directory removed and verified\n'
    fi
}


cleanup() {
    cleanup_exit_status=$?
    trap - 0 1 2 15

    printf '\nCleaning up...\n'

    stop_tailcat || {
        [ "$cleanup_exit_status" -ne 0 ] || cleanup_exit_status=1
    }
    remove_runtime_directory || {
        [ "$cleanup_exit_status" -ne 0 ] || cleanup_exit_status=1
    }

    exit "$cleanup_exit_status"
}


download_file() {
    curl \
        --disable \
        --fail \
        --location \
        --silent \
        --show-error \
        --connect-timeout 15 \
        --max-time 120 \
        --retry 2 \
        --retry-delay 2 \
        --retry-max-time 360 \
        --retry-connrefused \
        --output "$2" \
        "$1" || fail "Download failed: $1"
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

    download_file \
        "$RELEASE_BASE_URL/$TAILCAT_VERSION/$archive_name" \
        "$archive_path"

    download_file \
        "$RELEASE_BASE_URL/$TAILCAT_VERSION/checksums.txt" \
        "$checksums_path"

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

    wait_tailcat
}


wait_tailcat() {
    tailcat_exit_status=0
    wait "$TAILCAT_PID" || tailcat_exit_status=$?
    # The child has been reaped; its PID must no longer be used by cleanup.
    TAILCAT_PID=""
    return "$tailcat_exit_status"
}


show_server_qr() {
    qr_attempt=0
    while [ "$qr_attempt" -lt 300 ]; do
        kill -0 "$TAILCAT_PID" 2>/dev/null || return 0
        if [ -s "$1" ]; then
            # Tailcat writes no trailing newline. Reject an incomplete write.
            qr_token=""
            IFS= read -r qr_token < "$1" || true
            if "$TAILCAT_BIN" parse "$qr_token" >/dev/null 2>&1; then
                printf '\nScan this QR code to copy the server token:\n'
                if ! printf '%s' "$qr_token" | qrencode -t ANSIUTF8 -l M -m 4; then
                    printf '[WARN] QR could not be displayed; use the printed token.\n'
                fi
                return 0
            fi
        fi
        sleep 0.1
        qr_attempt=$((qr_attempt + 1))
    done
    printf '[WARN] QR token was not ready within 30 seconds; use the printed token.\n'
}


run_server() {
    show_runtime_info

    qr_answer=""
    if command -v qrencode >/dev/null 2>&1; then
        printf '\nQR needs a UTF-8 console with room for the whole code (80x40 recommended).\n'
        printf 'Show the server token as a QR code? [y/N]: '
        IFS= read -r qr_answer || qr_answer=""
    else
        printf '\n[INFO] Optional QR codes need qrencode. Install separately as administrator:\n'
        printf '       Debian/Ubuntu: apt install qrencode\n'
        printf '       Alpine Linux : apk add libqrencode-tools\n'
    fi

    printf '\nStarting Tailcat exit-node...\n\n'
    printf '%s\n' 'Share the generated tc... token with the client.'
    printf '%s\n\n' 'Press Ctrl+C to stop and clean up.'

    case "$qr_answer" in
        y|Y|yes|YES)
            TAILCAT_ADDR_FILE="$RUNTIME_DIR/tc.txt" \
                "$TAILCAT_BIN" --key=new serve exit-node &
            TAILCAT_PID=$!
            show_server_qr "$RUNTIME_DIR/tc.txt"
            wait_tailcat
            ;;
        *)
            run_tailcat --key=new serve exit-node
            ;;
    esac
}


read_client_token() {
    client_token=""

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
}


run_forward() {
    read_client_token
    printf '\nMapping: local-port:remote-IP:remote-port\n'
    printf 'Example: 13389:192.168.1.20:3389\n'
    printf 'Use local port 0 to choose a free port automatically.\n'
    printf 'Mapping: '
    if ! IFS= read -r forward_mapping; then
        printf '\n' >&2
        return 1
    fi
    [ -n "$forward_mapping" ] || fail "A port mapping is required"

    show_runtime_info
    printf '\nStarting TCP forwarding on localhost...\n'
    printf 'Tailcat will print the local endpoint when ready.\n'
    printf 'Press Ctrl+C to disconnect and clean up.\n\n'
    run_tailcat --key=new forward "$client_token" "$forward_mapping"
}


run_client() {
    read_client_token
    client_socks_port=""

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
    printf '%s\n' '[3] FORWARD'
    printf '%s\n\n' '    Forward a local TCP port to a service on the remote network'
    printf '%s\n\n' '[Q] Quit'

    printf 'Select: '

    if ! IFS= read -r choice; then
        printf '\n' >&2
        return 1
    fi

    case "$choice" in
        1|2|3)
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

    RUNTIME_BASE="$(CDPATH= cd -P -- "$temp_base" && pwd -P)"
    RUNTIME_DIR="$(mktemp -d "${RUNTIME_BASE%/}/tailcat-oneshot.XXXXXXXX")"

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
        3)
            run_forward
            ;;
    esac
}


main "$@"
