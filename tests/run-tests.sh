#!/bin/bash
###############################################################################
# Test runner — executes every tests/test_*.sh in a subprocess and reports.
###############################################################################
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

cd "$REPO_ROOT"

declare -a passed=()
declare -a failed=()
declare -i total=0

echo "=== fan-control test suite ==="
echo "Script under test: ${FAN_CONTROL_SCRIPT:-$REPO_ROOT/fan-control.sh}"
echo

for test_file in "$TEST_DIR"/test_*.sh; do
    [[ -f "$test_file" ]] || continue
    test_name=$(basename "$test_file")
    total=$((total + 1))
    printf "  %-50s ... " "$test_name"

    # Run each test in a clean subprocess with inherited env
    if bash "$test_file" 2>&1; then
        echo "PASS"
        passed+=("$test_name")
    else
        rc=$?
        echo "FAIL (exit $rc)"
        failed+=("$test_name")
    fi
done

echo
echo "──────────────────────────────────────────────────────"
echo "Results: ${#passed[@]} passed, ${#failed[@]} failed, $total total"
echo "──────────────────────────────────────────────────────"

if ((${#passed[@]} > 0)); then
    echo "PASSED:"
    for t in "${passed[@]}"; do
        echo "  ✓ $t"
    done
fi

if ((${#failed[@]} > 0)); then
    echo "FAILED:"
    for t in "${failed[@]}"; do
        echo "  ✗ $t"
    done
    exit 1
fi

exit 0
