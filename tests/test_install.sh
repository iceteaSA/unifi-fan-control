#!/bin/bash
###############################################################################
# Verified installer behavior tests.
###############################################################################
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(dirname "$0")/lib/harness.sh"

setup_sandbox
trap teardown_sandbox EXIT

INSTALLER="$REPO_ROOT/install.sh"
PAYLOAD_FILES=(fan-control.sh uninstall.sh fan-control.service VERSION)

cat >"$SANDBOX/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
STUB
chmod +x "$SANDBOX/bin/id"

cat >"$SANDBOX/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
if [[ "$1" == "is-active" ]]; then
    if [[ "${MOCK_SYSTEMCTL_ACTIVE:-0}" == 1 ]]; then
        exit 0
    fi
    if [[ "${MOCK_SYSTEMCTL_ACTIVE:-}" == after-manage ]] && \
        grep -Eq '^(enable|restart)' "$SYSTEMCTL_LOG"; then
        exit 0
    fi
    exit 1
fi
if [[ "${MOCK_SYSTEMCTL_FAIL:-}" == "$1" ]]; then
    exit 1
fi
STUB
chmod +x "$SANDBOX/bin/systemctl"

cat >"$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$CURL_LOG"
output_file=""
write_format=""
url=""
while (($# > 0)); do
    case "$1" in
        -o)
            output_file="$2"
            shift 2
            ;;
        -w)
            write_format="$2"
            shift 2
            ;;
        --max-filesize)
            shift 2
            ;;
        -*)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

if [[ "${MOCK_CURL_FAIL:-0}" == 1 ]]; then
    exit 22
fi

if [[ -n "$write_format" ]]; then
    printf '%s' "${MOCK_LATEST_URL:?missing latest redirect URL}"
    exit 0
fi

case "$url" in
    */SHA256SUMS)
        cp "${MOCK_SUMS:?missing checksum fixture}" "$output_file"
        ;;
    *.tar.gz)
        cp "${MOCK_ARCHIVE:?missing archive fixture}" "$output_file"
        ;;
    */fan-control.sh|*/uninstall.sh|*/fan-control.service|*/VERSION)
        cp "${MOCK_BRANCH_DIR:?missing branch fixture}/${url##*/}" "$output_file"
        ;;
    *)
        echo "unexpected curl URL: $url" >&2
        exit 2
        ;;
esac
STUB
chmod +x "$SANDBOX/bin/curl"

make_payload_dir() {
    local directory="$1"
    local version="$2"

    mkdir -p "$directory"
    cp "$REPO_ROOT/fan-control.sh" "$directory/fan-control.sh"
    cp "$REPO_ROOT/uninstall.sh" "$directory/uninstall.sh"
    cp "$REPO_ROOT/fan-control.service" "$directory/fan-control.service"
    printf '%s\n' "$version" >"$directory/VERSION"
}

make_release_fixture() {
    local case_dir="$1"
    local version="$2"
    local payload_dir="$case_dir/payload"
    local archive_name="unifi-fan-control-v${version}.tar.gz"
    local archive="$case_dir/$archive_name"
    local checksum

    make_payload_dir "$payload_dir" "$version"
    tar -czf "$archive" -C "$payload_dir" "${PAYLOAD_FILES[@]}"
    checksum=$(sha256sum "$archive" | awk '{print $1}')
    {
        printf '%s  unrelated.tar.gz\n' "$(printf '0%.0s' {1..64})"
        printf '%s  %s\n' "$checksum" "$archive_name"
    } >"$case_dir/SHA256SUMS"
}

rebuild_release_fixture() {
    local archive_name="unifi-fan-control-v${MOCK_VERSION}.tar.gz"
    local archive="$CASE_DIR/$archive_name"
    local checksum

    tar -czf "$archive" -C "$CASE_DIR/payload" "${PAYLOAD_FILES[@]}"
    checksum=$(sha256sum "$archive" | awk '{print $1}')
    printf '%s  %s\n' "$checksum" "$archive_name" >"$CASE_DIR/SHA256SUMS"
}

write_comment_payload() {
    local destination="$1"
    local bytes="$2"

    dd if=/dev/zero bs=1 count="$bytes" status=none | tr '\000' '#' >"$destination"
    printf '\n' >>"$destination"
}

append_tar_entry() {
    local archive="$1"
    local name="$2"
    local type="$3"
    local header="$archive.header"
    local body="${4:-payload}"
    local checksum
    local padding

    if [[ "$type" != 0 ]]; then
        body=""
    fi
    dd if=/dev/zero of="$header" bs=512 count=1 status=none
    printf '%s' "$name" | dd of="$header" bs=1 seek=0 conv=notrunc status=none
    printf '0000644\0' | dd of="$header" bs=1 seek=100 conv=notrunc status=none
    printf '0000000\0' | dd of="$header" bs=1 seek=108 conv=notrunc status=none
    printf '0000000\0' | dd of="$header" bs=1 seek=116 conv=notrunc status=none
    printf '%011o\0' "${#body}" | dd of="$header" bs=1 seek=124 conv=notrunc status=none
    printf '%011o\0' 0 | dd of="$header" bs=1 seek=136 conv=notrunc status=none
    printf '        ' | dd of="$header" bs=1 seek=148 conv=notrunc status=none
    printf '%s' "$type" | dd of="$header" bs=1 seek=156 conv=notrunc status=none
    if [[ "$type" == 1 || "$type" == 2 ]]; then
        printf 'uninstall.sh' | dd of="$header" bs=1 seek=157 conv=notrunc status=none
    fi
    if [[ "$type" == 3 ]]; then
        printf '0000000\0' | dd of="$header" bs=1 seek=329 conv=notrunc status=none
        printf '0000000\0' | dd of="$header" bs=1 seek=337 conv=notrunc status=none
    fi
    printf 'ustar\0' | dd of="$header" bs=1 seek=257 conv=notrunc status=none
    printf '00' | dd of="$header" bs=1 seek=263 conv=notrunc status=none
    checksum=$(od -An -v -tu1 "$header" | awk '{ for (i = 1; i <= NF; i++) sum += $i } END { print sum }')
    printf '%06o\0 ' "$checksum" | dd of="$header" bs=1 seek=148 conv=notrunc status=none
    padding=$(((512 - (${#body} % 512)) % 512))
    {
        cat "$header"
        printf '%s' "$body"
        dd if=/dev/zero bs=1 count="$padding" status=none
    } >>"$archive"
    rm -f "$header"
}

make_hostile_archive() {
    local archive="$1"
    local name="$2"
    local type="$3"
    local raw_archive="$archive.raw"

    : >"$raw_archive"
    if [[ "$name" == fan-control.sh && "$type" != 0 ]]; then
        append_tar_entry "$raw_archive" "$name" "$type"
    else
        append_tar_entry "$raw_archive" fan-control.sh 0 $'#!/bin/bash\n'
    fi
    append_tar_entry "$raw_archive" uninstall.sh 0 $'#!/bin/bash\n'
    append_tar_entry "$raw_archive" fan-control.service 0 $'[Unit]\n'
    append_tar_entry "$raw_archive" VERSION 0 "$MOCK_VERSION"
    if [[ "$name" != fan-control.sh || "$type" == 0 ]]; then
        append_tar_entry "$raw_archive" "$name" "$type"
    fi
    dd if=/dev/zero bs=512 count=2 status=none >>"$raw_archive"
    gzip -c "$raw_archive" >"$archive"
    rm -f "$raw_archive"
}

prepare_case() {
    local name="$1"
    CASE_DIR="$SANDBOX/$name"
    INSTALLER_DIR="$CASE_DIR/installer"
    INSTALL_DIR="$CASE_DIR/data/fan-control"
    SERVICE_FILE="$CASE_DIR/etc/systemd/system/fan-control.service"
    CURL_LOG="$CASE_DIR/curl.log"
    SYSTEMCTL_LOG="$CASE_DIR/systemctl.log"

    mkdir -p "$INSTALLER_DIR" "$INSTALL_DIR" "$(dirname "$SERVICE_FILE")"
    cp "$INSTALLER" "$INSTALLER_DIR/install.sh"
    : >"$CURL_LOG"
    : >"$SYSTEMCTL_LOG"
    export CURL_LOG SYSTEMCTL_LOG
}

install_environment() {
    env \
        FAN_CONTROL_INSTALL_DIR="$INSTALL_DIR" \
        FAN_CONTROL_SERVICE_FILE="$SERVICE_FILE" \
        FAN_CONTROL_SYSTEMCTL=systemctl \
        FAN_CONTROL_RELEASE_BASE_URL="https://releases.example.invalid/project/releases" \
        CURL_LOG="$CURL_LOG" \
        SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        MOCK_ARCHIVE="$CASE_DIR/unifi-fan-control-v${MOCK_VERSION}.tar.gz" \
        MOCK_SUMS="$CASE_DIR/SHA256SUMS" \
        MOCK_BRANCH_DIR="$CASE_DIR/branch" \
        MOCK_LATEST_URL="https://releases.example.invalid/project/releases/tag/v${MOCK_VERSION}" \
        MOCK_SYSTEMCTL_ACTIVE="${MOCK_SYSTEMCTL_ACTIVE:-after-manage}" \
        "$@" \
        bash "$INSTALLER_DIR/install.sh"
}

install_piped_environment() {
    (
        cd "$INSTALLER_DIR"
        # The cat is deliberate: it makes stdin a PIPE, reproducing the documented
        # `curl -fsSL ... | sudo bash` install. `bash < install.sh` would make stdin a
        # regular file instead -- a scenario no user hits -- so the linter's suggested
        # rewrite would silently weaken what this test covers.
        # shellcheck disable=SC2002
        cat install.sh | env \
            FAN_CONTROL_INSTALL_DIR="$INSTALL_DIR" \
            FAN_CONTROL_SERVICE_FILE="$SERVICE_FILE" \
            FAN_CONTROL_SYSTEMCTL=systemctl \
            FAN_CONTROL_RELEASE_BASE_URL="https://releases.example.invalid/project/releases" \
            CURL_LOG="$CURL_LOG" \
            SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
            MOCK_ARCHIVE="$CASE_DIR/unifi-fan-control-v${MOCK_VERSION}.tar.gz" \
            MOCK_SUMS="$CASE_DIR/SHA256SUMS" \
            MOCK_BRANCH_DIR="$CASE_DIR/branch" \
            MOCK_LATEST_URL="https://releases.example.invalid/project/releases/tag/v${MOCK_VERSION}" \
            MOCK_SYSTEMCTL_ACTIVE="${MOCK_SYSTEMCTL_ACTIVE:-after-manage}" \
            "$@" \
            bash
    )
}

seed_old_install() {
    printf 'old daemon\n' >"$INSTALL_DIR/fan-control.sh"
    printf 'old uninstall\n' >"$INSTALL_DIR/uninstall.sh"
    printf 'old version\n' >"$INSTALL_DIR/VERSION"
    printf 'old service\n' >"$SERVICE_FILE"
}

assert_old_files() {
    assert_eq "$(cat "$INSTALL_DIR/fan-control.sh")" "old daemon" "daemon changed before validation: "
    assert_eq "$(cat "$INSTALL_DIR/uninstall.sh")" "old uninstall" "uninstall changed before validation: "
    assert_eq "$(cat "$INSTALL_DIR/VERSION")" "old version" "version changed before validation: "
    assert_eq "$(cat "$SERVICE_FILE")" "old service" "service changed before validation: "
}

assert_old_install() {
    assert_old_files
    assert_eq "$(cat "$SYSTEMCTL_LOG")" "" "systemctl ran before validation: "
}

assert_failed_install_keeps_destination() {
    if install_environment "$@"; then
        fail "installer accepted invalid input"
    fi
    assert_old_install
}

assert_file_set() {
    local file

    for file in "${PAYLOAD_FILES[@]}"; do
        if [[ "$file" == fan-control.service ]]; then
            if [[ ! -f "$SERVICE_FILE" ]]; then
                fail "missing installed payload file: $file"
            fi
        elif [[ ! -f "$INSTALL_DIR/$file" ]]; then
            fail "missing installed payload file: $file"
        fi
    done
}

test_local_payload_wins_without_curl() {
    prepare_case local
    MOCK_VERSION=1.2.3
    make_payload_dir "$INSTALLER_DIR" "$MOCK_VERSION"

    install_environment

    assert_file_set
    assert_eq "$(cat "$INSTALL_DIR/VERSION")" "$MOCK_VERSION" "local version: "
    assert_eq "$(cat "$CURL_LOG")" "" "local payload made a network call: "
}

test_exact_version_uses_verified_release_urls() {
    prepare_case version
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"

    install_environment FAN_CONTROL_VERSION="$MOCK_VERSION"

    assert_file_set
    assert_contains "$(cat "$CURL_LOG")" "/download/v1.2.3/unifi-fan-control-v1.2.3.tar.gz" "version archive URL: "
    assert_contains "$(cat "$CURL_LOG")" "/download/v1.2.3/SHA256SUMS" "version checksum URL: "
    assert_contains "$(cat "$CURL_LOG")" "max-filesize 2097152" "archive size cap: "
}

test_piped_installer_ignores_cwd_payload() {
    prepare_case piped
    MOCK_VERSION=1.2.3
    make_payload_dir "$INSTALLER_DIR" 9.9.9
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"

    install_piped_environment FAN_CONTROL_VERSION="$MOCK_VERSION"

    assert_eq "$(cat "$INSTALL_DIR/VERSION")" "$MOCK_VERSION" "piped installer version: "
    assert_contains "$(cat "$CURL_LOG")" "/download/v1.2.3/unifi-fan-control-v1.2.3.tar.gz" "piped release URL: "
}

test_latest_resolves_a_concrete_verified_release() {
    prepare_case latest
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"

    install_environment

    assert_file_set
    assert_contains "$(cat "$CURL_LOG")" "/latest" "latest resolver URL: "
    assert_contains "$(cat "$CURL_LOG")" "/download/v1.2.3/SHA256SUMS" "latest checksum URL: "
}

test_branch_install_is_unverified() {
    prepare_case branch
    MOCK_VERSION=0.0.0
    make_payload_dir "$CASE_DIR/branch" "$MOCK_VERSION"

    branch_output=$(install_environment FAN_CONTROL_BRANCH=feature/test)

    assert_file_set
    assert_contains "$branch_output" "WARNING: branch install is unverified: feature/test" "branch warning: "
    if [[ "$(cat "$CURL_LOG")" != *"-fsSL"* ]]; then
        fail "branch install did not use curl -fsSL"
    fi
}

test_version_and_branch_fail_before_network() {
    prepare_case conflict
    MOCK_VERSION=1.2.3
    seed_old_install

    assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3 FAN_CONTROL_BRANCH=feature/test
    assert_eq "$(cat "$CURL_LOG")" "" "version/branch conflict made a network call: "
}

test_curl_failure_keeps_destination() {
    prepare_case curl-failure
    MOCK_VERSION=1.2.3
    seed_old_install

    assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3 MOCK_CURL_FAIL=1
}

test_checksum_mismatch_keeps_destination() {
    prepare_case checksum-mismatch
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"
    printf '%s  unifi-fan-control-v1.2.3.tar.gz\n' "$(printf 'f%.0s' {1..64})" >"$CASE_DIR/SHA256SUMS"
    seed_old_install

    assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3
}

test_unrelated_checksum_cannot_pass_vacuously() {
    prepare_case checksum-unrelated
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"
    printf '%s  another-asset.tar.gz\n' "$(printf '0%.0s' {1..64})" >"$CASE_DIR/SHA256SUMS"
    seed_old_install

    assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3
}

test_hostile_archives_keep_destination() {
    local shape
    local name
    local type

    for shape in absolute traversal symlink hardlink device directory extra; do
        prepare_case "hostile-$shape"
        MOCK_VERSION=1.2.3
        case "$shape" in
            absolute)
                name=/fan-control.sh
                type=0
                ;;
            traversal)
                name=../fan-control.sh
                type=0
                ;;
            symlink)
                name=fan-control.sh
                type=2
                ;;
            hardlink)
                name=fan-control.sh
                type=1
                ;;
            device)
                name=fan-control.sh
                type=3
                ;;
            directory)
                name=fan-control.sh
                type=5
                ;;
            extra)
                name=surprise.sh
                type=0
                ;;
        esac
        make_hostile_archive "$CASE_DIR/unifi-fan-control-v${MOCK_VERSION}.tar.gz" "$name" "$type"
        checksum=$(sha256sum "$CASE_DIR/unifi-fan-control-v${MOCK_VERSION}.tar.gz" | awk '{print $1}')
        printf '%s  unifi-fan-control-v%s.tar.gz\n' "$checksum" "$MOCK_VERSION" >"$CASE_DIR/SHA256SUMS"
        seed_old_install

        assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3
    done
}

test_syntax_failure_keeps_destination() {
    prepare_case syntax-failure
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"
    printf 'if then\n' >"$CASE_DIR/payload/fan-control.sh"
    tar -czf "$CASE_DIR/unifi-fan-control-v${MOCK_VERSION}.tar.gz" -C "$CASE_DIR/payload" "${PAYLOAD_FILES[@]}"
    checksum=$(sha256sum "$CASE_DIR/unifi-fan-control-v${MOCK_VERSION}.tar.gz" | awk '{print $1}')
    printf '%s  unifi-fan-control-v%s.tar.gz\n' "$checksum" "$MOCK_VERSION" >"$CASE_DIR/SHA256SUMS"
    seed_old_install

    assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3
}

test_oversized_payload_keeps_destination() {
    prepare_case oversized-payload
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"
    write_comment_payload "$CASE_DIR/payload/fan-control.sh" $((512 * 1024 + 1))
    rebuild_release_fixture
    seed_old_install

    assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3
}

test_oversized_expansion_keeps_destination() {
    prepare_case oversized-expansion
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"
    write_comment_payload "$CASE_DIR/payload/fan-control.sh" $((4 * 1024 * 1024 + 1))
    rebuild_release_fixture
    seed_old_install

    assert_failed_install_keeps_destination FAN_CONTROL_VERSION=1.2.3
}

test_verified_release_installs_and_preserves_config() {
    prepare_case success
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"
    printf 'MIN_TEMP=48\n' >"$INSTALL_DIR/config"

    install_environment FAN_CONTROL_VERSION=1.2.3

    assert_file_set
    assert_eq "$(cat "$INSTALL_DIR/VERSION")" "$MOCK_VERSION" "installed release version: "
    assert_eq "$(cat "$INSTALL_DIR/config")" "MIN_TEMP=48" "config preservation: "
    assert_eq "$(cat "$SYSTEMCTL_LOG")" $'is-active --quiet fan-control.service\ndaemon-reload\nenable --now fan-control.service\nis-active --quiet fan-control.service' "systemctl order: "
}

test_restart_failure_restores_prior_payload() {
    prepare_case restart-failure
    MOCK_VERSION=1.2.3
    make_release_fixture "$CASE_DIR" "$MOCK_VERSION"
    seed_old_install
    printf 'MIN_TEMP=48\n' >"$INSTALL_DIR/config"

    if install_environment FAN_CONTROL_VERSION=1.2.3 MOCK_SYSTEMCTL_ACTIVE=1 MOCK_SYSTEMCTL_FAIL=restart; then
        fail "installer accepted a failed service restart"
    fi

    assert_old_files
    assert_eq "$(cat "$INSTALL_DIR/config")" "MIN_TEMP=48" "config changed during rollback: "
}

test_local_payload_wins_without_curl
test_exact_version_uses_verified_release_urls
test_piped_installer_ignores_cwd_payload
test_latest_resolves_a_concrete_verified_release
test_branch_install_is_unverified
test_version_and_branch_fail_before_network
test_curl_failure_keeps_destination
test_checksum_mismatch_keeps_destination
test_unrelated_checksum_cannot_pass_vacuously
test_hostile_archives_keep_destination
test_syntax_failure_keeps_destination
test_oversized_payload_keeps_destination
test_oversized_expansion_keeps_destination
test_verified_release_installs_and_preserves_config
test_restart_failure_restores_prior_payload

echo "PASS: verified installer behavior"
