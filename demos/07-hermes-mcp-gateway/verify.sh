#!/bin/bash
# Verify Demo 7: Check OpenShell gateway, MCP Gateway, and Hermes sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"
source "$REPO_ROOT/common/mcp-gateway.sh"

NAMESPACE="${NAMESPACE:-openshell-demo-hermes-mcp}"
SANDBOX_NAME="${1:-hermes-mcp-demo}"
PASSED=0
FAILED=0

check() {
    local name="$1"
    shift
    if "$@" &>/dev/null; then
        info "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: $name"
        FAILED=$((FAILED + 1))
    fi
}

echo "============================================"
echo " Verify Demo 7: Hermes + MCP Gateway"
echo "============================================"
echo ""

step "OpenShell infrastructure checks"
check "Agent Sandbox CRD exists" oc get crd sandboxes.agents.x-k8s.io
check "OpenShell namespace exists" oc get ns "$NAMESPACE"
check "Gateway pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s
check "Gateway service exists" oc -n "$NAMESPACE" get svc openshell
check "Gateway route exists" oc -n "$NAMESPACE" get route openshell-gw

step "MCP Gateway checks"
MCP_GW_ROUTE=$(_mcp_gateway_route)
if [ -n "$MCP_GW_ROUTE" ]; then
    info "PASS: MCP Gateway route: $MCP_GW_ROUTE"
    PASSED=$((PASSED + 1))

    MCP_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://$MCP_GW_ROUTE/health" 2>/dev/null || echo "000")
    if [ "$MCP_STATUS" = "200" ] || [ "$MCP_STATUS" = "404" ] || [ "$MCP_STATUS" = "401" ]; then
        info "PASS: MCP Gateway reachable (HTTP $MCP_STATUS)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: MCP Gateway not reachable (HTTP $MCP_STATUS)"
        FAILED=$((FAILED + 1))
    fi
else
    error "FAIL: MCP Gateway route not found"
    FAILED=$((FAILED + 1))
fi

check "Gitea MCP server registration" oc get mcpsr -n "$MCP_TEST_NS" gitea-mcp-server

step "MCP tools verification"
if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi
MCP_TOKEN=$(get_mcp_token user1 user1 2>/dev/null || echo "")
if [ -n "$MCP_TOKEN" ]; then
    MCP_GW_URL=$(_mcp_gateway_url)
    MCP_SESSION_ID=$(curl -sk -X POST "${MCP_GW_URL}/mcp" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $MCP_TOKEN" \
        -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}},"id":1}' \
        -D /tmp/mcp-verify-headers 2>/dev/null >/dev/null \
        && grep -i "mcp-session-id" /tmp/mcp-verify-headers | cut -d: -f2 | tr -d ' \r')
    TOOLS_RESPONSE=$(curl -sk \
        -H "Authorization: Bearer $MCP_TOKEN" \
        -H "Content-Type: application/json" \
        -H "mcp-session-id: $MCP_SESSION_ID" \
        "${MCP_GW_URL}/mcp" \
        -d '{"jsonrpc":"2.0","method":"tools/list","id":2}' 2>/dev/null)
    if echo "$TOOLS_RESPONSE" | grep -q "gitea_"; then
        TOOL_COUNT=$(echo "$TOOLS_RESPONSE" | grep -o '"name":"gitea_[^"]*"' | wc -l | tr -d ' ')
        info "PASS: Gitea tools available ($TOOL_COUNT tools)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: No Gitea tools found in MCP Gateway"
        FAILED=$((FAILED + 1))
    fi
else
    info "SKIP: Could not get MCP token for tool verification"
fi

step "Sandbox checks"
export PATH="$HOME/bin:$PATH"

SANDBOX_STATUS=$(openshell sandbox list 2>/dev/null | grep "$SANDBOX_NAME" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}' || echo "")
if [ "$SANDBOX_STATUS" = "Ready" ]; then
    info "PASS: Sandbox '$SANDBOX_NAME' is Ready"
    PASSED=$((PASSED + 1))

    HERMES_VER=$(openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c 'export PATH="/sandbox/.local/bin:$PATH" && hermes --version' 2>&1 | grep -v "Using sandbox" || echo "")
    if [ -n "$HERMES_VER" ]; then
        info "PASS: Hermes version: $HERMES_VER"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: Hermes not found in sandbox"
        FAILED=$((FAILED + 1))
    fi

    if [ -f "$REPO_ROOT/.env" ]; then
        LLM_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s -o /dev/null -w "%{http_code}" -X POST "${LITELLM_BASE_URL}/chat/completions" -H "Authorization: Bearer ${LITELLM_API_KEY}" -H "Content-Type: application/json" -d '{"model":"'"${LITELLM_MODEL:-gemini-2.5-pro}"'","messages":[{"role":"user","content":"Say ok"}],"max_tokens":5}' 2>&1 | grep -v "Using sandbox")
        if [ "$LLM_CODE" = "200" ]; then
            info "PASS: LiteLLM API (HTTP 200)"
            PASSED=$((PASSED + 1))
        else
            error "FAIL: LiteLLM API (HTTP $LLM_CODE)"
            FAILED=$((FAILED + 1))
        fi
    fi
elif [ -n "$SANDBOX_STATUS" ]; then
    error "FAIL: Sandbox '$SANDBOX_NAME' status: $SANDBOX_STATUS (expected Ready)"
    FAILED=$((FAILED + 1))
else
    info "SKIP: Sandbox '$SANDBOX_NAME' not found (run setup-sandbox.sh first)"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
