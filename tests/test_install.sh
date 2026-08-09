#!/bin/bash
###############################################################################
# Installer download failure regression test.
###############################################################################
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(dirname "$0")/lib/harness.sh"

setup_sandbox
trap teardown_sandbox EXIT

cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
while (($# > 0)); do
    if [[ "$1" == -*f* ]]; then
        fail_on_http_error=1
    fi
    if [[ "$1" == "-o" ]]; then
        shift
        output_file="$1"
    fi
    shift
done
printf '404: Not Found\n' > "$output_file"
if [[ "${fail_on_http_error:-0}" == 1 ]]; then
    exit 22
fi
exit 0
STUB
chmod +x "$SANDBOX/bin/curl"

function_file="$SANDBOX/get_file.sh"
awk '
    /^get_file\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
' "$REPO_ROOT/install.sh" > "$function_file"

SCRIPT_DIR="$SANDBOX/local"
export BASE_URL="https://example.invalid/missing-branch"
mkdir -p "$SCRIPT_DIR"
# shellcheck source=/dev/null
source "$function_file"

destination="$SANDBOX/downloaded.sh"
if (get_file "fan-control.sh" "$destination"); then
    fail "get_file accepted an HTTP 404 response"
fi

assert_eq "$(cat "$destination" 2>/dev/null || true)" "404: Not Found" \
    "fake curl should reproduce the HTTP 404 body: "
if [[ -x "$destination" ]]; then
    fail "failed download was made executable"
fi

echo "PASS: get_file rejects a curl 404 response before installation"
