#!/bin/bash
# Test sandbox security enforcement with MCP Gateway policy.
# Demonstrates: MCP Gateway access, Gitea access, Keycloak access,
# blocked external sites, Landlock, and process isolation.
#
# Usage:
#   bash test-sandbox-security.sh [sandbox-name]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-opencode-mcp-demo}"

export PATH="$HOME/bin:$PATH"

if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi

APPS_DOMAIN="${OCP_APPS_DOMAIN:-localhost}"

PASS=0 FAIL=0 TOTAL=0
track() { TOTAL=$((TOTAL + 1)); if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }

echo ""
echo "================================================================"
echo " OpenShell Security Test - STANDARD-MCP Policy"
echo " Sandbox: $SANDBOX_NAME"
echo "================================================================"

# --- Network: Allowed endpoints ---
echo ""
step "1. Network Allowlisting - Allowed Endpoints"
echo "   MCP Gateway, Gitea, Keycloak, registries, and GitHub are allowed."
echo "   Direct AI APIs and arbitrary web access are blocked."
echo ""

test_curl "curl MCP Gateway (mcp.${APPS_DOMAIN})" \
    "https://mcp.${APPS_DOMAIN}/health" "$SANDBOX_NAME"
track $?

test_curl "curl Gitea (gitea-gitea.${APPS_DOMAIN})" \
    "https://gitea-gitea.${APPS_DOMAIN}/api/v1/version" "$SANDBOX_NAME"
track $?

test_curl "curl Keycloak MCP (keycloak-mcp-test.${APPS_DOMAIN})" \
    "https://keycloak-mcp-test.${APPS_DOMAIN}/realms/mcp/.well-known/openid-configuration" "$SANDBOX_NAME"
track $?

test_curl "curl https://registry.npmjs.org/express (npm)" \
    "https://registry.npmjs.org/express" "$SANDBOX_NAME"
track $?

test_curl "curl https://pypi.org/simple/requests/ (PyPI)" \
    "https://pypi.org/simple/requests/" "$SANDBOX_NAME"
track $?

# --- Network: Blocked endpoints ---
echo ""
step "2. Network Allowlisting - Blocked Endpoints"
echo "   Direct AI APIs and arbitrary web browsing are blocked."
echo ""

test_curl "curl https://api.anthropic.com (blocked)" \
    "https://api.anthropic.com/v1/models" "$SANDBOX_NAME"
track $?

test_curl "curl https://example.com (blocked)" \
    "https://example.com" "$SANDBOX_NAME"
track $?

test_curl "curl https://opencode.ai (blocked)" \
    "https://opencode.ai" "$SANDBOX_NAME"
track $?

# --- Network: L7 Read-Only ---
echo ""
step "3. L7 Inspection: Read-Only Enforcement"
echo "   GitHub is allowed but restricted to read-only (GET)."
echo ""

test_curl "GET https://api.github.com/repos/NVIDIA/OpenShell" \
    "https://api.github.com/repos/NVIDIA/OpenShell" "$SANDBOX_NAME"
track $?

test_curl_method "POST https://api.github.com/repos/.../issues" \
    "POST" "https://api.github.com/repos/NVIDIA/OpenShell/issues" "$SANDBOX_NAME"
track $?

# --- Filesystem: Landlock ---
echo ""
step "4. Landlock: Filesystem Enforcement"
echo ""

test_file_write "write /workspace/test-$$" "/workspace/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /tmp/test-$$" "/tmp/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /etc/test-$$ (read-only)" "/etc/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /usr/test-$$ (read-only)" "/usr/test-$$" "$SANDBOX_NAME"
track $?

test_file_read "read /etc/os-release (read-only)" "/etc/os-release" "$SANDBOX_NAME"
track $?

# --- Process ---
echo ""
step "5. Process Isolation"
echo ""

test_process "whoami" "whoami" "sandbox" "$SANDBOX_NAME"
track $?

# --- Summary ---
echo ""
echo "================================================================"
echo " Results: $PASS passed, $FAIL unexpected out of $TOTAL tests"
echo ""
echo " Network:    MCP GW + Gitea + KC + Registries + GitHub RO allowed"
echo " L7:         GitHub POST blocked (read-only enforcement)"
echo " Blocked:    AI APIs + arbitrary web blocked"
echo " Filesystem: Landlock restricts to declared paths"
echo " Process:    Running as non-root sandbox user"
echo "================================================================"
echo ""
