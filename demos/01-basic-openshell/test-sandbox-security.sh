#!/bin/bash
# Test OpenShell sandbox security enforcement (strict policy).
# Demonstrates: CONNECT proxy, binary binding, Landlock, process isolation.
#
# Usage:
#   bash test-sandbox-security.sh [sandbox-name]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-basic-sandbox}"

export PATH="$HOME/bin:$PATH"

LITELLM_URL="${LITELLM_URL:-https://maas-rhdp.apps.maas.redhatworkshops.io}"

PASS=0 FAIL=0 TOTAL=0
track() { TOTAL=$((TOTAL + 1)); if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }

echo ""
echo "================================================================"
echo " OpenShell Security Test - STRICT Policy"
echo " Sandbox: $SANDBOX_NAME"
echo "================================================================"

# --- Network: Default-Deny ---
echo ""
step "1. CONNECT Proxy: Default-Deny Network"
echo "   Every outbound connection goes through the CONNECT proxy."
echo "   Only endpoints in the policy are reachable."
echo ""

test_curl "curl https://github.com" "https://github.com" "$SANDBOX_NAME"
track $?

test_curl "curl https://google.com" "https://google.com" "$SANDBOX_NAME"
track $?

test_curl "curl https://api.anthropic.com" "https://api.anthropic.com/v1/models" "$SANDBOX_NAME"
track $?

test_curl "curl https://registry.npmjs.org" "https://registry.npmjs.org/express" "$SANDBOX_NAME"
track $?

# --- Network: Binary Binding ---
echo ""
step "2. CONNECT Proxy: Binary Binding"
echo "   The strict policy only allows python3 and node to reach inference."
echo "   curl is blocked even for allowed endpoints."
echo ""

test_curl "curl \$LITELLM_URL (curl binary)" "${LITELLM_URL}/health" "$SANDBOX_NAME"
track $?

test_python_url "python3 urllib to \$LITELLM_URL" "${LITELLM_URL}/health" "$SANDBOX_NAME"
track $?

# --- Filesystem: Landlock ---
echo ""
step "3. Landlock: Filesystem Enforcement"
echo "   Landlock LSM enforces filesystem access at the kernel level."
echo "   Only paths declared in the policy are accessible."
echo ""

test_file_write "write /workspace/test-$$" "/workspace/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /tmp/test-$$" "/tmp/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /etc/test-$$ (read-only)" "/etc/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /usr/test-$$ (read-only)" "/usr/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /var/test-$$ (not in policy)" "/var/test-$$" "$SANDBOX_NAME"
track $?

test_file_read "read /etc/os-release (read-only path)" "/etc/os-release" "$SANDBOX_NAME"
track $?

test_file_read "read /proc/self/status (read-only path)" "/proc/self/status" "$SANDBOX_NAME"
track $?

# --- Process Isolation ---
echo ""
step "4. Process Isolation"
echo "   The agent runs as the unprivileged 'sandbox' user."
echo ""

test_process "whoami" "whoami" "sandbox" "$SANDBOX_NAME"
track $?

# --- Summary ---
echo ""
echo "================================================================"
echo " Results: $PASS passed, $FAIL unexpected out of $TOTAL tests"
echo ""
echo " Network:    Default-deny + binary binding enforced"
echo " Filesystem: Landlock restricts to declared paths"
echo " Process:    Running as non-root sandbox user"
echo "================================================================"
echo ""
