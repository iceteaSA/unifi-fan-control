#!/bin/bash
set -e
set -o pipefail

PAYLOAD_FILES=(fan-control.sh uninstall.sh fan-control.service VERSION)
# rc1 is 10,515 B and fan-control.sh is 38,059 B; these retain ample release headroom.
readonly MAX_ARCHIVE_BYTES=$((2 * 1024 * 1024))
readonly MAX_EXPANDED_ARCHIVE_BYTES=$((4 * 1024 * 1024))
readonly MAX_PAYLOAD_FILE_BYTES=$((512 * 1024))
REPO_OWNER="iceteaSA"
REPO_NAME="unifi-fan-control"
INSTALL_DIR="${FAN_CONTROL_INSTALL_DIR:-/data/fan-control}"
SERVICE_FILE="${FAN_CONTROL_SERVICE_FILE:-/etc/systemd/system/fan-control.service}"
SYSTEMCTL="${FAN_CONTROL_SYSTEMCTL:-systemctl}"
RELEASE_BASE_URL="${FAN_CONTROL_RELEASE_BASE_URL:-https://github.com/$REPO_OWNER/$REPO_NAME/releases}"
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR=""
WORK_DIR="$(mktemp -d)"
RESOLVED_VERSION=""
INSTALL_SOURCE=""
SERVICE_WAS_ACTIVE=0
UNVERIFIED_RELEASE=0
DESTINATIONS=()
NEW_FILES=()
BACKUPS=()
HAD_ORIGINAL=()

cleanup_work_dir() {
    rm -rf "$WORK_DIR"
}

trap cleanup_work_dir EXIT

if [[ -f "$SCRIPT_PATH" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
fi

fail() {
    echo "Error: $*" >&2
    exit 1
}

is_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
}

normalize_version() {
    local version="$1"

    version="${version#v}"
    if ! is_semver "$version"; then
        fail "Version must be SemVer, with an optional leading v: $1"
    fi
    printf '%s\n' "$version"
}

payload_destination() {
    case "$1" in
        fan-control.sh | uninstall.sh | VERSION)
            printf '%s/%s\n' "$INSTALL_DIR" "$1"
            ;;
        fan-control.service)
            printf '%s\n' "$SERVICE_FILE"
            ;;
        *)
            fail "Unknown payload file: $1"
            ;;
    esac
}

validate_payload() {
    local payload_dir="$1"
    local expected_version="${2:-}"
    local filename
    local payload_version
    local payload_size

    for filename in "${PAYLOAD_FILES[@]}"; do
        if [[ ! -f "$payload_dir/$filename" ]]; then
            fail "Missing payload file: $filename"
        fi
        payload_size=$(wc -c <"$payload_dir/$filename")
        if ((payload_size > MAX_PAYLOAD_FILE_BYTES)); then
            fail "Payload file exceeds size limit: $filename"
        fi
    done

    if ! bash -n "$payload_dir/fan-control.sh" "$payload_dir/uninstall.sh"; then
        fail "Payload scripts failed syntax validation"
    fi

    payload_version=$(cat "$payload_dir/VERSION")
    if ! is_semver "$payload_version"; then
        fail "Payload VERSION is not SemVer: $payload_version"
    fi
    if [[ -n "$expected_version" && "$payload_version" != "$expected_version" ]]; then
        fail "Payload VERSION does not match requested release: $payload_version"
    fi

    RESOLVED_VERSION="$payload_version"
}

octal_to_decimal() {
    local digits="$1"
    local decimal=0
    local digit

    while [[ -n "$digits" ]]; do
        digit="${digits:0:1}"
        decimal=$((decimal * 8 + digit))
        digits="${digits:1}"
    done
    printf '%s\n' "$decimal"
}

validate_archive_header_types() {
    local archive="$1"
    local raw_archive="$WORK_DIR/archive.raw"
    local header="$WORK_DIR/archive.header"
    local zero_block="$WORK_DIR/zero-block"
    local raw_size
    local block=0
    local type_byte
    local size_field
    local size
    local magic
    local found_end=0

    # ulimit -f kills gzip with SIGXFSZ past the cap. -c 0 because UniFi OS uses a
    # plain core_pattern filename, so the kill would drop a core into the working
    # directory -- writing to disk during the check that exists to protect it.
    if ! (
        ulimit -c 0
        ulimit -f "$((MAX_EXPANDED_ARCHIVE_BYTES / 512 + 1))"
        gzip -dc "$archive" >"$raw_archive"
    ); then
        raw_size=$(wc -c <"$raw_archive")
        if ((raw_size > MAX_EXPANDED_ARCHIVE_BYTES)); then
            fail "Release archive exceeds expanded size limit"
        fi
        fail "Release archive could not be decompressed"
    fi
    dd if=/dev/zero of="$zero_block" bs=512 count=1 status=none
    raw_size=$(wc -c <"$raw_archive")
    if ((raw_size > MAX_EXPANDED_ARCHIVE_BYTES)); then
        fail "Release archive exceeds expanded size limit"
    fi

    while ((block * 512 < raw_size)); do
        dd if="$raw_archive" of="$header" bs=512 skip="$block" count=1 status=none
        if cmp -s "$header" "$zero_block"; then
            if (((block + 1) * 512 >= raw_size)); then
                fail "Release archive has a malformed end marker"
            fi
            dd if="$raw_archive" of="$header" bs=512 skip="$((block + 1))" count=1 status=none
            if ! cmp -s "$header" "$zero_block"; then
                fail "Release archive has a malformed end marker"
            fi
            found_end=1
            break
        fi

        magic=$(dd if="$header" bs=1 skip=257 count=5 status=none | od -An -tx1 | tr -d '[:space:]')
        if [[ "$magic" != 7573746172 ]]; then
            fail "Release archive is not ustar format"
        fi

        type_byte=$(dd if="$header" bs=1 skip=156 count=1 status=none | od -An -tu1 | tr -d '[:space:]')
        if [[ -n "$type_byte" && "$type_byte" != 48 ]]; then
            fail "Release archive contains a non-regular entry"
        fi

        size_field=$(dd if="$header" bs=1 skip=124 count=12 status=none | tr -d '\000 ')
        if [[ -z "$size_field" ]]; then
            fail "Release archive has an invalid entry size"
        elif [[ "$size_field" =~ ^[0-7]+$ ]]; then
            size=$(octal_to_decimal "$size_field")
        else
            fail "Release archive has an invalid entry size"
        fi
        block=$((block + 1 + (size + 511) / 512))
    done

    if ((found_end == 0)); then
        fail "Release archive has no end marker"
    fi
}

copy_local_payload() {
    local filename
    local payload_dir="$WORK_DIR/payload"

    if [[ -z "$SCRIPT_DIR" ]]; then
        return 1
    fi

    for filename in "${PAYLOAD_FILES[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$filename" ]]; then
            return 1
        fi
    done

    mkdir -p "$payload_dir"
    for filename in "${PAYLOAD_FILES[@]}"; do
        cp "$SCRIPT_DIR/$filename" "$payload_dir/$filename"
    done

    validate_payload "$payload_dir"
    INSTALL_SOURCE="local files"
    return 0
}

validate_unverified_consent() {
    local tag="$1"
    local allowed_tag="${FAN_CONTROL_ALLOW_UNVERIFIED:-}"

    if [[ -z "$allowed_tag" ]]; then
        return 0
    fi
    if [[ "$allowed_tag" != v* ]] || ! is_semver "${allowed_tag#v}"; then
        fail "FAN_CONTROL_ALLOW_UNVERIFIED must name a release tag such as $tag"
    fi
    if [[ "$allowed_tag" != "$tag" ]]; then
        fail "FAN_CONTROL_ALLOW_UNVERIFIED must match requested release tag: $tag"
    fi
}

probe_unverified_fallback() {
    local tag="$1"
    local fallback_url="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$tag/VERSION"
    local fallback_error="$WORK_DIR/fallback-curl-error"
    local fallback_status

    if curl -fsSL --connect-timeout 10 --max-time 20 -o /dev/null "$fallback_url" 2>"$fallback_error"; then
        echo "Error: Unverified fallback host raw.githubusercontent.com is reachable for $tag" >&2
        return 0
    else
        fallback_status=$?
    fi

    if ((fallback_status == 22)); then
        echo "Error: Unverified fallback host raw.githubusercontent.com responded, but the VERSION request failed (curl exit 22)" >&2
    else
        echo "Error: Unverified fallback host raw.githubusercontent.com is not reachable for $tag (curl exit $fallback_status)" >&2
    fi
    return 1
}

diagnose_release_download_failure() {
    local tag="$1"
    local curl_status="$2"
    local curl_error="$3"
    local failed_host
    local http_status

    if ((curl_status == 6)); then
        failed_host=$(sed -n 's/.*Could not resolve host: \([^[:space:]]*\).*/\1/p' "$curl_error")
        if [[ "$failed_host" == "release-assets.githubusercontent.com" ]]; then
            echo "Error: DNS lookup failed for release-assets.githubusercontent.com while downloading release $tag" >&2
            echo "Error: GitHub redirects release downloads to release-assets.githubusercontent.com" >&2
            echo "Error: This is a resolver problem, not a fault in the installer or release" >&2
        elif [[ -n "$failed_host" ]]; then
            echo "Error: DNS lookup failed for $failed_host while downloading release $tag" >&2
            echo "Error: This is a resolver problem, not a fault in the installer or release" >&2
        else
            echo "Error: DNS lookup failed while downloading release $tag (curl exit 6)" >&2
            echo "Error: curl did not identify the host, so the installer cannot name it" >&2
        fi
    else
        case "$curl_status" in
            22)
                http_status=$(sed -n 's/.*error: \([0-9][0-9][0-9]\).*/\1/p' "$curl_error")
                if [[ -n "$http_status" ]]; then
                    echo "Error: HTTP error $http_status while downloading release $tag" >&2
                else
                    echo "Error: HTTP error while downloading release $tag (curl exit 22)" >&2
                fi
                ;;
            28)
                echo "Error: Connection timed out while downloading release $tag (curl exit 28)" >&2
                ;;
            35 | 51 | 58 | 59 | 60 | 77)
                echo "Error: TLS error while downloading release $tag (curl exit $curl_status)" >&2
                ;;
            *)
                echo "Error: Network failure while downloading release $tag (curl exit $curl_status)" >&2
                ;;
        esac
        echo "Error: This is not a DNS resolution failure" >&2
    fi

    probe_unverified_fallback "$tag" || true
}

download_unverified_payload() {
    local ref="$1"
    local source="$2"
    local expected_version="${3:-}"
    local filename
    local payload_dir="$WORK_DIR/payload"
    local base_url="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$ref"

    mkdir -p "$payload_dir"
    for filename in "${PAYLOAD_FILES[@]}"; do
        if ! curl -fsSL "$base_url/$filename" -o "$payload_dir/$filename"; then
            fail "Failed to download $filename from $source"
        fi
    done

    validate_payload "$payload_dir" "$expected_version"
    INSTALL_SOURCE="$source"
}

download_unverified_release() {
    local tag="$1"

    echo "WARNING: SHA256 verification will be skipped for release $tag" >&2
    download_unverified_payload "$tag" "unverified release $tag" "${tag#v}"
    UNVERIFIED_RELEASE=1
}

handle_verified_download_failure() {
    local tag="$1"
    local curl_status="$2"
    local curl_error="$3"

    diagnose_release_download_failure "$tag" "$curl_status" "$curl_error"
    if [[ -z "${FAN_CONTROL_ALLOW_UNVERIFIED:-}" ]]; then
        echo "Error: The verified download failed. To install $tag without SHA256 verification, run:" >&2
        echo "curl -fsSL https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$tag/install.sh | sudo FAN_CONTROL_ALLOW_UNVERIFIED=$tag bash" >&2
        exit 1
    fi
    download_unverified_release "$tag"
}

download_verified_release() {
    local tag="$1"
    local archive_name="unifi-fan-control-${tag}.tar.gz"
    local archive="$WORK_DIR/$archive_name"
    local checksum_file="$WORK_DIR/SHA256SUMS"
    local payload_dir="$WORK_DIR/payload"
    local expected_checksum
    local actual_checksum
    local filename
    local curl_error="$WORK_DIR/release-curl-error"
    local curl_status

    validate_unverified_consent "$tag"

    if curl -fsSL --max-filesize "$MAX_ARCHIVE_BYTES" "$RELEASE_BASE_URL/download/$tag/$archive_name" -o "$archive" 2>"$curl_error"; then
        :
    else
        curl_status=$?
        handle_verified_download_failure "$tag" "$curl_status" "$curl_error"
        return 0
    fi
    if curl -fsSL "$RELEASE_BASE_URL/download/$tag/SHA256SUMS" -o "$checksum_file" 2>"$curl_error"; then
        :
    else
        curl_status=$?
        handle_verified_download_failure "$tag" "$curl_status" "$curl_error"
        return 0
    fi

    if ! expected_checksum=$(awk -v filename="$archive_name" '
        length($1) == 64 && $1 ~ /^[0-9A-Fa-f]+$/ && $2 == filename && NF == 2 {
            print $1
            count++
        }
        END { exit count == 1 ? 0 : 1 }
    ' "$checksum_file"); then
        fail "SHA256SUMS must contain exactly one checksum for $archive_name"
    fi

    actual_checksum=$(sha256sum "$archive" | awk '{print $1}')
    if [[ "${actual_checksum,,}" != "${expected_checksum,,}" ]]; then
        fail "Checksum mismatch for $archive_name"
    fi

    # GNU tar 1.34 on device preserves traversal paths and flags hardlinks; BusyBox
    # tar in CI strips paths and misreports hardlinks. Raw-header validation keeps
    # these checks independent of which tar is present.
    if ! tar -tzf "$archive" >"$WORK_DIR/archive-files"; then
        fail "Release archive could not be listed"
    fi
    LC_ALL=C sort "$WORK_DIR/archive-files" -o "$WORK_DIR/archive-files.sorted"
    printf '%s\n' "${PAYLOAD_FILES[@]}" | LC_ALL=C sort >"$WORK_DIR/expected-files"
    if ! diff -u "$WORK_DIR/expected-files" "$WORK_DIR/archive-files.sorted"; then
        fail "Release archive contains unexpected paths"
    fi

    validate_archive_header_types "$archive"

    mkdir -p "$payload_dir"
    if ! tar -xzf "$archive" -C "$payload_dir"; then
        fail "Release archive could not be extracted"
    fi
    validate_payload "$payload_dir" "${tag#v}"
    INSTALL_SOURCE="verified release $tag"
}

download_branch_payload() {
    local branch="$1"

    echo "WARNING: branch install is unverified: $branch"
    download_unverified_payload "$branch" "unverified branch $branch"
}

resolve_latest_release() {
    local resolved_url
    local tag

    if ! resolved_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASE_BASE_URL/latest"); then
        fail "Failed to resolve the latest release"
    fi
    tag="${resolved_url##*/}"
    RESOLVED_VERSION=$(normalize_version "$tag")
    download_verified_release "v$RESOLVED_VERSION"
}

cleanup_destination_temps() {
    local index

    for index in "${!NEW_FILES[@]}"; do
        rm -f "${NEW_FILES[$index]}" "${BACKUPS[$index]}"
    done
}

stage_destination_files() {
    local filename
    local destination
    local new_file

    mkdir -p "$INSTALL_DIR" "$(dirname "$SERVICE_FILE")" || return 1

    for filename in "${PAYLOAD_FILES[@]}"; do
        destination=$(payload_destination "$filename")
        new_file="${destination}.new.$$"
        if ! cp "$WORK_DIR/payload/$filename" "$new_file"; then
            return 1
        fi
        if [[ "$filename" == "fan-control.sh" || "$filename" == "uninstall.sh" ]]; then
            chmod 0755 "$new_file" || return 1
            if ! bash -n "$new_file"; then
                return 1
            fi
        else
            chmod 0644 "$new_file" || return 1
        fi
        DESTINATIONS+=("$destination")
        NEW_FILES+=("$new_file")
        BACKUPS+=("${destination}.rollback.$$")
        HAD_ORIGINAL+=(0)
    done
}

restore_previous_payload() {
    local index

    for ((index = ${#DESTINATIONS[@]} - 1; index >= 0; index--)); do
        rm -f "${DESTINATIONS[$index]}" "${NEW_FILES[$index]}"
        if [[ "${HAD_ORIGINAL[$index]}" == 1 ]]; then
            mv "${BACKUPS[$index]}" "${DESTINATIONS[$index]}" || true
        fi
    done
}

replace_destination_files() {
    local index

    for index in "${!DESTINATIONS[@]}"; do
        if [[ -e "${DESTINATIONS[$index]}" || -L "${DESTINATIONS[$index]}" ]]; then
            if ! mv "${DESTINATIONS[$index]}" "${BACKUPS[$index]}"; then
                restore_previous_payload
                return 1
            fi
            HAD_ORIGINAL[index]=1
        fi
        if ! mv "${NEW_FILES[$index]}" "${DESTINATIONS[$index]}"; then
            restore_previous_payload
            return 1
        fi
    done
}

enforce_install_permissions() {
    if [[ "${FAN_CONTROL_ALLOW_CHOWN_FAILURE:-0}" == 1 ]]; then
        chown root:root "$INSTALL_DIR" 2>/dev/null || true
    elif ! chown root:root "$INSTALL_DIR"; then
        return 1
    fi
    if ! chmod 0700 "$INSTALL_DIR"; then
        return 1
    fi
    if [[ -f "$INSTALL_DIR/config" ]]; then
        if [[ "${FAN_CONTROL_ALLOW_CHOWN_FAILURE:-0}" == 1 ]]; then
            chown root:root "$INSTALL_DIR/config" 2>/dev/null || true
        elif ! chown root:root "$INSTALL_DIR/config"; then
            return 1
        fi
        chmod 0600 "$INSTALL_DIR/config" || return 1
    fi
}

rollback_install() {
    restore_previous_payload
    "$SYSTEMCTL" daemon-reload >/dev/null 2>&1 || true
    if ((SERVICE_WAS_ACTIVE)); then
        "$SYSTEMCTL" restart fan-control.service >/dev/null 2>&1 || true
    fi
    cleanup_destination_temps
}

install_validated_payload() {
    if ! stage_destination_files; then
        cleanup_destination_temps
        fail "Failed to stage installation files"
    fi

    if "$SYSTEMCTL" is-active --quiet fan-control.service; then
        SERVICE_WAS_ACTIVE=1
    fi

    if ! replace_destination_files; then
        cleanup_destination_temps
        fail "Failed to replace installation files"
    fi

    if ! enforce_install_permissions; then
        rollback_install
        fail "Failed to enforce installation permissions"
    fi

    if ! "$SYSTEMCTL" daemon-reload; then
        rollback_install
        fail "Failed to reload systemd configuration"
    fi

    if ((SERVICE_WAS_ACTIVE)); then
        echo "Service already running - performing hot update"
        if ! "$SYSTEMCTL" restart fan-control.service; then
            rollback_install
            fail "Failed to restart service"
        fi
    else
        echo "Performing fresh installation"
        if ! "$SYSTEMCTL" enable --now fan-control.service; then
            rollback_install
            fail "Failed to enable and start service"
        fi
    fi

    if [[ "$(cat "$INSTALL_DIR/VERSION")" != "$RESOLVED_VERSION" ]]; then
        rollback_install
        fail "Installed VERSION readback failed"
    fi
    if ! bash -n "$INSTALL_DIR/fan-control.sh" "$INSTALL_DIR/uninstall.sh"; then
        rollback_install
        fail "Installed scripts failed syntax readback"
    fi
    if ! "$SYSTEMCTL" is-active --quiet fan-control.service; then
        rollback_install
        fail "Service did not become active"
    fi

    cleanup_destination_temps
}

if [[ "$(id -u)" -ne 0 ]]; then
    fail "This script must be run as root (sudo)"
fi
if ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    fail "systemd is required but not found"
fi
if ! command -v curl >/dev/null 2>&1; then
    fail "curl is required but not found"
fi
if ! command -v gzip >/dev/null 2>&1; then
    fail "gzip is required but not found"
fi

VERSION_INPUT="${FAN_CONTROL_VERSION:-}"
BRANCH="${FAN_CONTROL_BRANCH:-}"
if [[ -n "$VERSION_INPUT" && -n "$BRANCH" ]]; then
    fail "FAN_CONTROL_VERSION and FAN_CONTROL_BRANCH cannot both be set"
fi

if copy_local_payload; then
    :
elif [[ -n "$VERSION_INPUT" ]]; then
    RESOLVED_VERSION=$(normalize_version "$VERSION_INPUT")
    download_verified_release "v$RESOLVED_VERSION"
elif [[ -n "$BRANCH" ]]; then
    download_branch_payload "$BRANCH"
else
    resolve_latest_release
fi

echo "Installing fan-control v$RESOLVED_VERSION from $INSTALL_SOURCE"
install_validated_payload

echo "Installation successful!"
if ((UNVERIFIED_RELEASE)); then
    echo "WARNING: Installed v$RESOLVED_VERSION without SHA256 verification"
fi
echo "Configuration: nano $INSTALL_DIR/config"
echo "Status check: journalctl -u fan-control.service -f"
