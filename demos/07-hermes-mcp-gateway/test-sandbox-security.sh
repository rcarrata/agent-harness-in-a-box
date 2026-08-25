#!/bin/bash
# Test OpenShell sandbox security enforcement (standard-mcp policy) for Hermes + MCP Gateway.
# Demonstrates: MCP Gateway access, Gitea access, Keycloak access, blocked sites, Landlock.
#
# Usage:
#   bash test-sandbox-security.sh [sandbox-name]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"
source "$REPO_ROOT/common/mcp-gateway.sh"

SANDBOX_NAME="${1:-hermes-mcp-demo}"

export PATH="$HOME/bin:$PATH"

if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi

APPS_DOMAIN="${OCP_APPS_DOMAIN:-localhost}"

PASS=0 FAIL=0 TOTAL=0
track() { TOTAL=$((TOTAL + 1)); if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }

echo ""
echo "================================================================"
echo " OpenShell Security Test - STANDARD-MCP Policy (Hermes)"
echo " Sandbox: $SANDBOX_NAME"
echo "================================================================"

# --- Network: MCP Gateway, Gitea, Keycloak ---
echo ""
step "1. MCP Gateway, Gitea, and Keycloak Access"
echo "   MCP Gateway, Gitea, and Keycloak are allowed."
echo "   Arbitrary web access is blocked."
echo ""

MCP_GW_HOST=$(_mcp_gateway_route)
KC_HOST=$(_keycloak_mcp_route)
GITEA_HOST="gitea-gitea.${APPS_DOMAIN}"

test_curl "curl https://${MCP_GW_HOST} (MCP Gateway)" \
    "https://${MCP_GW_HOST}/mcp" "$SANDBOX_NAME"
track $?

test_curl "curl https://${KC_HOST} (Keycloak)" \
    "https://${KC_HOST}/realms/mcp/.well-known/openid-configuration" "$SANDBOX_NAME"
track $?

test_curl "curl https://${GITEA_HOST} (Gitea)" \
    "https://${GITEA_HOST}/api/v1/version" "$SANDBOX_NAME"
track $?

test_curl "curl https://example.com (blocked)" \
    "https://example.com" "$SANDBOX_NAME"
track $?

test_curl "curl https://api.anthropic.com (blocked)" \
    "https://api.anthropic.com/v1/models" "$SANDBOX_NAME"
track $?

test_curl "curl https://api.openai.com (blocked)" \
    "https://api.openai.com/v1/models" "$SANDBOX_NAME"
track $?

# --- Network: LiteLLM ---
echo ""
step "2. LiteLLM Inference Access"
echo "   LiteLLM endpoint is allowed for inference."
echo ""

test_curl "curl LiteLLM /models" \
    "${LITELLM_BASE_URL:-https://maas-rhdp.apps.maas.redhatworkshops.io/v1}/models" "$SANDBOX_NAME"
track $?

# --- Network: PyPI ---
echo ""
step "3. PyPI Access"
echo "   PyPI is allowed for package installs."
echo ""

test_curl "curl https://pypi.org/simple/requests/ (PyPI)" \
    "https://pypi.org/simple/requests/" "$SANDBOX_NAME"
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
echo " Network:    MCP Gateway + Keycloak + Gitea + LiteLLM + PyPI allowed"
echo " Blocked:    example.com, api.anthropic.com, api.openai.com"
echo " Filesystem: Landlock restricts to declared paths"
echo " Process:    Running as non-root sandbox user"
echo "================================================================"
echo ""
