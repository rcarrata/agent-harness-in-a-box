#!/bin/bash
# Verify Demo 6: Check Keycloak, OpenShell, MCP Gateway, and Gitea integration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"
source "$REPO_ROOT/common/gitea.sh"
source "$REPO_ROOT/common/mcp-gateway.sh"

OPENSHELL_NS="${OPENSHELL_NS:-openshell}"
KC_NAMESPACE="${KC_NAMESPACE:-openshell-keycloak}"
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
echo " Verify Demo 6: OpenCode/Claude + MCP GW"
echo "============================================"
echo ""

# -- Keycloak (OpenShell) --
step "Keycloak checks (OpenShell OIDC)"
check "Keycloak namespace exists" oc get ns "$KC_NAMESPACE"
check "Keycloak pod running" oc -n "$KC_NAMESPACE" wait --for=condition=Ready pod -l app=keycloak --timeout=10s
check "Keycloak route exists" oc -n "$KC_NAMESPACE" get route keycloak

KC_ROUTE=$(oc -n "$KC_NAMESPACE" get route keycloak -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$KC_ROUTE" ]; then
    check "OIDC discovery endpoint" curl -sfk --max-time 5 "https://$KC_ROUTE/realms/openshell/.well-known/openid-configuration"
fi

# -- OpenShell --
step "OpenShell checks"
check "Agent Sandbox CRD exists" oc get crd sandboxes.agents.x-k8s.io
check "OpenShell namespace exists" oc get ns "$OPENSHELL_NS"
check "Gateway pod running" oc -n "$OPENSHELL_NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s
check "Gateway service exists" oc -n "$OPENSHELL_NS" get svc openshell
check "Gateway route exists" oc -n "$OPENSHELL_NS" get route openshell-gw

# -- Gitea --
step "Gitea checks"
check "Gitea namespace exists" oc get ns "$GITEA_NS"
check "Gitea pod running" oc -n "$GITEA_NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=gitea --timeout=10s
check "Gitea route exists" oc -n "$GITEA_NS" get route gitea

GITEA_HOST=$(_gitea_route)
if [ -n "$GITEA_HOST" ]; then
    check "Gitea API reachable" curl -sfk --max-time 5 "https://$GITEA_HOST/api/v1/version"
fi

# -- MCP Gateway --
step "MCP Gateway checks"
check "MCP Gateway namespace exists" oc get ns "$MCP_GW_NS"
check "MCP Gateway route exists" oc -n "$MCP_GW_NS" get route mcp-gateway

MCP_GW_ROUTE=$(_mcp_gateway_route)
if [ -n "$MCP_GW_ROUTE" ]; then
    MCP_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://$MCP_GW_ROUTE/health" 2>/dev/null || echo "000")
    if [ "$MCP_STATUS" = "200" ] || [ "$MCP_STATUS" = "404" ] || [ "$MCP_STATUS" = "401" ]; then
        info "PASS: MCP Gateway reachable (HTTP $MCP_STATUS)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: MCP Gateway not reachable (HTTP $MCP_STATUS)"
        FAILED=$((FAILED + 1))
    fi
fi

# -- MCP Keycloak --
step "MCP Keycloak checks"
KC_MCP_ROUTE=$(_keycloak_mcp_route)
if [ -n "$KC_MCP_ROUTE" ]; then
    check "MCP Keycloak reachable" curl -sfk --max-time 5 "https://$KC_MCP_ROUTE/realms/mcp/.well-known/openid-configuration"

    # Test token acquisition
    TOKEN_RESPONSE=$(curl -sfk --max-time 10 \
        -X POST "https://$KC_MCP_ROUTE/realms/mcp/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=mcp-gateway" \
        -d "username=user1" \
        -d "password=user1" 2>/dev/null || echo "")
    if echo "$TOKEN_RESPONSE" | grep -q "access_token"; then
        info "PASS: MCP token acquisition (user1)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: MCP token acquisition (user1)"
        FAILED=$((FAILED + 1))
    fi
fi

# -- MCP Tools --
step "MCP tools check"
MCP_TOKEN=$(get_mcp_token user1 user1 2>/dev/null || true)
if [ -n "$MCP_TOKEN" ]; then
    MCP_SESSION_ID=$(curl -sk -X POST "https://$MCP_GW_ROUTE/mcp" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $MCP_TOKEN" \
        -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}},"id":1}' \
        -D /tmp/mcp-verify-headers 2>/dev/null >/dev/null \
        && grep -i "mcp-session-id" /tmp/mcp-verify-headers | cut -d: -f2 | tr -d ' \r')
    TOOLS_RESPONSE=$(curl -sk \
        -H "Authorization: Bearer $MCP_TOKEN" \
        -H "Content-Type: application/json" \
        -H "mcp-session-id: $MCP_SESSION_ID" \
        "https://$MCP_GW_ROUTE/mcp" \
        -d '{"jsonrpc":"2.0","method":"tools/list","id":2}' 2>/dev/null || echo "")
    if echo "$TOOLS_RESPONSE" | grep -q "gitea_"; then
        info "PASS: Gitea tools available via MCP Gateway"
        PASSED=$((PASSED + 1))
        TOOL_COUNT=$(echo "$TOOLS_RESPONSE" | grep -o '"name":"' | wc -l | tr -d ' ')
        info "  Tools found: $TOOL_COUNT"
    else
        error "FAIL: Gitea tools not found in MCP Gateway"
        FAILED=$((FAILED + 1))
    fi
else
    error "FAIL: Could not get MCP token to verify tools"
    FAILED=$((FAILED + 1))
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
