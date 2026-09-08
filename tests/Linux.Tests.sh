#!/bin/sh
# Offline regression checks. Run: sh tests/Linux.Tests.sh
set -eu
umask 077

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
test_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_dir=$(mktemp -d "$test_base/tailcat-tests.XXXXXXXX")
trap 'case "$test_dir" in "$test_base"/tailcat-tests.????????) rm -rf -- "$test_dir" ;; esac' 0
trap 'exit 130' 2
trap 'exit 143' 15

# Load functions without running the interactive entry point.
awk '$0 != "main \"$@\""' "$source_dir/Tailcat_OneShot.sh" > "$test_dir/functions.sh"

(
    . "$test_dir/functions.sh"
    RUNTIME_BASE=$test_dir
    RUNTIME_DIR=$(mktemp -d "$RUNTIME_BASE/tailcat-oneshot.XXXXXXXX")
    printf 'temporary\n' > "$RUNTIME_DIR/runtime.log"
    remove_runtime_directory
    [ ! -e "$RUNTIME_DIR" ]
)
printf '[PASS] Runtime directory and files removed\n'

(
    . "$test_dir/functions.sh"
    RUNTIME_BASE=$test_dir
    RUNTIME_DIR="$test_dir/unrelated"
    mkdir "$RUNTIME_DIR"
    printf 'keep\n' > "$RUNTIME_DIR/keep"
    if remove_runtime_directory; then exit 1; fi
    [ -f "$RUNTIME_DIR/keep" ]
    RUNTIME_DIR=$test_dir
    if remove_runtime_directory; then exit 1; fi
    RUNTIME_BASE="$test_dir/different-parent"
    RUNTIME_DIR="$test_dir/tailcat-oneshot.12345678"
    if remove_runtime_directory; then exit 1; fi
)
printf '[PASS] Unexpected names and parent directories refused\n'

(
    . "$test_dir/functions.sh"
    # POSIX symlinks must not redirect cleanup to another directory.
    RUNTIME_BASE=$test_dir
    RUNTIME_DIR="$test_dir/tailcat-oneshot.linktest"
    ln -s "$test_dir/unrelated" "$RUNTIME_DIR"
    if [ -L "$RUNTIME_DIR" ]; then
        if remove_runtime_directory; then exit 1; fi
        [ -f "$test_dir/unrelated/keep" ]
        printf '[PASS] Redirected runtime directory refused\n'
    else
        printf '[SKIP] This host does not create POSIX symlinks\n'
    fi
)

mkdir "$test_dir/bin" "$test_dir/fixture"
cat > "$test_dir/fixture/tailcat" <<'EOF'
#!/bin/sh
if [ "$1" = parse ]; then
    [ "${2:-}" = tc-test-token ]
    exit $?
fi
[ "$1" = '--key=new' ] || exit 90
if [ -n "${TEST_QR_CAPTURE:-}" ]; then
    printf '%s\n' "$$" > "$TEST_QR_CAPTURE.pid"
fi
if [ "${2:-}" = forward ]; then
    [ "$#" -eq 4 ] || exit 91
    [ "$3" = tc-test-token ] || exit 92
    [ "$4" = 13389:192.168.1.20:3389 ] || exit 93
fi
if [ -n "${TAILCAT_ADDR_FILE:-}" ]; then
    case "${TEST_QR_WRITE:-none}" in
        partial)
            printf 'tc-' > "$TAILCAT_ADDR_FILE"
            sleep 0.2
            printf 'tc-test-token' > "$TAILCAT_ADDR_FILE"
            sleep 0.3
            ;;
        complete)
            printf 'tc-test-token' > "$TAILCAT_ADDR_FILE"
            sleep 0.3
            ;;
        interrupt)
            kill -INT "$PPID"
            sleep 0.3
            ;;
    esac
fi
exit "${TEST_TAILCAT_STATUS:-0}"
EOF
chmod 700 "$test_dir/fixture/tailcat"
archive_name=tailcat_0.6.0_linux_amd64.tar.gz
tar -czf "$test_dir/fixture/$archive_name" -C "$test_dir/fixture" tailcat
archive_hash=$(sha256sum "$test_dir/fixture/$archive_name")
printf '%s  %s\n' "${archive_hash%% *}" "$archive_name" > "$test_dir/fixture/checksums.txt"
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" >> "$TEST_FIXTURE/curl-args"
output=''
url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        *) url=$1; shift ;;
    esac
done
if [ "${TEST_DOWNLOAD_FAILURE:-0}" = 1 ]; then
    printf 'partial download\n' > "$output"
    exit 28
fi
case "$url" in
    */checksums.txt) cp "$TEST_FIXTURE/checksums.txt" "$output" ;;
    *.tar.gz) cp "$TEST_FIXTURE/tailcat_0.6.0_linux_amd64.tar.gz" "$output" ;;
    *) exit 22 ;;
esac
EOF
cat > "$test_dir/bin/uname" <<'EOF'
#!/bin/sh
printf 'x86_64\n'
EOF
chmod 700 "$test_dir/bin/curl" "$test_dir/bin/uname"
export TEST_FIXTURE="$test_dir/fixture"

(
    . "$test_dir/functions.sh"
    TAILCAT_BIN="$test_dir/fixture/tailcat"
    export TEST_TAILCAT_STATUS=7
    result=0
    run_tailcat --key=new || result=$?
    [ "$result" -eq 7 ]
    [ -z "$TAILCAT_PID" ]
)
printf '[PASS] Child exit status preserved and reaped PID forgotten\n'

(
    . "$test_dir/functions.sh"
    sleep 30 &
    TAILCAT_PID=$!
    owned_pid=$TAILCAT_PID
    stop_tailcat
    if kill -0 "$owned_pid" 2>/dev/null; then exit 1; fi
    [ -z "$TAILCAT_PID" ]
)
printf '[PASS] Running child stopped and verified\n'

(
    . "$test_dir/functions.sh"
    # Force the missing-command path regardless of host packages.
    command() { return 1; }
    TAILCAT_BIN="$test_dir/fixture/tailcat"
    RUNTIME_DIR=$test_dir
    run_server > "$test_dir/qr-missing.log" < /dev/null
    awk '/install qrencode/ { found=1 } END { exit !found }' "$test_dir/qr-missing.log"
    [ ! -e "$RUNTIME_DIR/tc.txt" ]
)
printf '[PASS] Missing qrencode suggests installation without requiring it\n'

cat > "$test_dir/bin/qrencode" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$TEST_QR_CAPTURE.args"
cat > "$TEST_QR_CAPTURE.input"
if [ "${TEST_QR_INTERRUPT:-0}" -eq 1 ]; then
    kill -INT "$PPID"
fi
exit "${TEST_QR_STATUS:-0}"
EOF
chmod 700 "$test_dir/bin/qrencode"

(
    . "$test_dir/functions.sh"
    sleep 30 &
    TAILCAT_PID=$!
    trap stop_tailcat 0
    # Exercise the bounded timeout without a 30-second test delay.
    sleep() { :; }
    show_server_qr "$test_dir/no-token.txt" > "$test_dir/qr-timeout.log"
    awk '/not ready within 30 seconds/ { found=1 } END { exit !found }' "$test_dir/qr-timeout.log"
    kill -0 "$TAILCAT_PID"
)
printf '[PASS] QR timeout leaves the server running\n'

for scenario in server client forward qr_yes qr_partial qr_failure qr_decline qr_early_exit qr_interrupt_wait qr_interrupt_display download_failure checksum_failure; do
    case_base="$test_dir/$scenario"
    mkdir "$case_base"
    input='1'
    expected=7
    status=7
    download_failure=0
    qr_write=none
    qr_status=0
    expect_qr=0
    qr_interrupt=0
    case "$scenario" in
        client) input='2\ntc-test-token\n1080'; expected=0; status=0 ;;
        forward) input='3\ntc-test-token\n13389:192.168.1.20:3389'; expected=0; status=0 ;;
        qr_yes|qr_partial|qr_failure)
            input='1\ny'; expected=0; status=0; expect_qr=1; qr_write=complete
            case "$scenario" in
                qr_partial) qr_write=partial ;;
                qr_failure) qr_status=9 ;;
            esac
            ;;
        qr_decline) input='1\nn'; expected=0; status=0 ;;
        qr_early_exit) input='1\ny' ;;
        qr_interrupt_wait) input='1\ny'; expected=130; qr_write=interrupt ;;
        qr_interrupt_display)
            input='1\ny'; expected=130; qr_write=complete; expect_qr=1; qr_interrupt=1
            ;;
        download_failure) expected=1; download_failure=1 ;;
        checksum_failure)
            expected=1
            printf '%064d  %s\n' 0 "$archive_name" > "$TEST_FIXTURE/checksums.txt"
            ;;
    esac
    result=0
    printf '%b\n' "$input" |
        env PATH="$test_dir/bin:$PATH" TMPDIR="$case_base" \
            TEST_TAILCAT_STATUS="$status" TEST_DOWNLOAD_FAILURE="$download_failure" \
            TAILCAT_ADDR_FILE= TEST_QR_WRITE="$qr_write" TEST_QR_STATUS="$qr_status" \
            TEST_QR_CAPTURE="$test_dir/$scenario.qr" TEST_QR_INTERRUPT="$qr_interrupt" \
            sh "$source_dir/Tailcat_OneShot.sh" > "$test_dir/$scenario.log" 2>&1 || result=$?
    if [ "$result" -ne "$expected" ]; then
        cat "$test_dir/$scenario.log"
        printf 'Unexpected exit status for %s: %s\n' "$scenario" "$result" >&2
        exit 1
    fi
    [ -z "$(ls -A "$case_base")" ]
    if [ -f "$test_dir/$scenario.qr.pid" ]; then
        if kill -0 "$(cat "$test_dir/$scenario.qr.pid")" 2>/dev/null; then
            printf 'Tailcat process remains after %s\n' "$scenario" >&2
            exit 1
        fi
    fi
    if [ "$expect_qr" -eq 1 ]; then
        [ "$(cat "$test_dir/$scenario.qr.input")" = tc-test-token ]
        printf '%s\n' -t ANSIUTF8 -l L -m 2 > "$test_dir/expected-qr-args"
        cmp "$test_dir/expected-qr-args" "$test_dir/$scenario.qr.args"
    else
        [ ! -e "$test_dir/$scenario.qr.input" ]
    fi
    if [ "$scenario" = qr_failure ]; then
        awk '/QR could not be displayed/ { found=1 } END { exit !found }' "$test_dir/$scenario.log"
    fi
    printf '[PASS] %s: expected exit status and no runtime files left\n' "$scenario"
done

# Check that even the offline transport received the configured limits.
for option in --connect-timeout --max-time --retry --retry-max-time; do
    awk -v option="$option" '$0 == option { found=1 } END { exit !found }' "$TEST_FIXTURE/curl-args"
done
printf '[PASS] Download limits applied\n'
