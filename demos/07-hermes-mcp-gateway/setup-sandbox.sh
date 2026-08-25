#!/bin/bash
# Setup a Hermes agent sandbox with MCP Gateway (Gitea tools) and LiteLLM inference.
# The MCP Gateway provides Gitea tools with RBAC via Keycloak.
#
# Usage:
#   bash setup-sandbox.sh [--user user1|user2]
#
# Defaults to user2 (read-only Gitea access) for safe demos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"
source "$REPO_ROOT/common/mcp-gateway.sh"

SANDBOX_NAME="hermes-mcp-demo"
MCP_USER="user2"

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            MCP_USER="$2"
            shift 2
            ;;
        *)
            SANDBOX_NAME="$1"
            shift
            ;;
    esac
done

if [ ! -f "$REPO_ROOT/.env" ]; then
    error "Missing .env file. Copy .env.example to .env and fill in your credentials."
    exit 1
fi
source "$REPO_ROOT/.env"

if [ -z "${LITELLM_API_KEY:-}" ]; then
    error "LITELLM_API_KEY not set in .env"
    exit 1
fi

export PATH="$HOME/bin:$PATH"

echo "============================================"
echo " Setup: Hermes + MCP Gateway"
echo "============================================"
echo ""
echo " Sandbox: $SANDBOX_NAME"
echo " MCP User: $MCP_USER"
echo ""

# Step 1: Get MCP Gateway token
step "Get MCP Gateway token for $MCP_USER"
MCP_GATEWAY_TOKEN=$(get_mcp_token "$MCP_USER" "$MCP_USER")
if [ -z "$MCP_GATEWAY_TOKEN" ]; then
    error "Failed to get MCP Gateway token for $MCP_USER"
    exit 1
fi
info "MCP token obtained for $MCP_USER"

MCP_GATEWAY_URL=$(_mcp_gateway_url)
info "MCP Gateway URL: $MCP_GATEWAY_URL"

# Step 2: Register gateway (openshell provider)
step "Register LiteLLM provider"
openshell provider delete litellm 2>/dev/null || true
openshell provider create \
    --name litellm \
    --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_API_KEY}" \
    --config "base_url=${LITELLM_BASE_URL}"

# Step 3: Configure inference routing
step "Configure inference routing"
openshell inference set --provider litellm --model "${LITELLM_MODEL:-gemini-2.5-pro}" --no-verify 2>/dev/null \
    && info "User inference route set" \
    || warn "inference set not supported by this gateway version - Hermes uses direct OPENAI_BASE_URL"
openshell inference set --provider litellm --model "${LITELLM_MODEL_SMALL:-llama-scout-17b}" --system --no-verify 2>/dev/null \
    && info "System inference route set" \
    || true

# Step 4: Render network policy
step "Render network policy (MCP Gateway enabled)"
POLICY_TIER="${POLICY_TIER:-standard-mcp}"
POLICY_TEMPLATE="$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml.template"
if [ ! -f "$POLICY_TEMPLATE" ] && [ -f "$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml" ]; then
    POLICY_TEMPLATE="$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml"
fi
RENDERED_POLICY="/tmp/policy-${POLICY_TIER}-rendered.yaml"
if [[ "$POLICY_TEMPLATE" == *.template ]]; then
    render_policy "$POLICY_TEMPLATE" "$RENDERED_POLICY" "$OCP_APPS_DOMAIN"
else
    cp "$POLICY_TEMPLATE" "$RENDERED_POLICY"
fi

# Step 5: Create sandbox
step "Create sandbox: $SANDBOX_NAME"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3
CREATE_ARGS=(--name "$SANDBOX_NAME" --policy "$RENDERED_POLICY" --no-tty)
if [ -n "${SANDBOX_IMAGE:-}" ]; then
    info "Using pre-baked image: $SANDBOX_IMAGE"
    CREATE_ARGS+=(--from "$SANDBOX_IMAGE")
fi
openshell sandbox create "${CREATE_ARGS[@]}" -- echo "sandbox created" 2>&1 || true

step "Wait for sandbox to be ready"
for i in $(seq 1 30); do
    STATUS=$(openshell sandbox list 2>/dev/null | grep "$SANDBOX_NAME" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}')
    if [ "$STATUS" = "Ready" ]; then
        info "Sandbox is Ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        error "Sandbox did not become Ready within 150s"
        exit 1
    fi
    sleep 5
done

# Step 6: Apply network policy
step "Apply network policy (tier: $POLICY_TIER)"
openshell policy set --policy "$RENDERED_POLICY" --wait "$SANDBOX_NAME"

# Step 7: Install Hermes
if [ -z "${SANDBOX_IMAGE:-}" ]; then
    step "Install Hermes agent in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c '
        pip3 install --user --no-cache-dir hermes-agent 2>&1 | tail -5
        export PATH="/sandbox/.local/bin:$PATH"
        hermes --version
    '
else
    step "Verify Hermes agent in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- hermes --version
fi

# Step 8: Upload Hermes config
step "Upload Hermes config"
sed -e "s|\${LITELLM_BASE_URL}|${LITELLM_BASE_URL}|g" \
    -e "s|\${LITELLM_API_KEY}|${LITELLM_API_KEY}|g" \
    -e "s|\${LITELLM_MODEL}|${LITELLM_MODEL:-gemini-2.5-pro}|g" \
    -e "s|\${MCP_GATEWAY_URL}|${MCP_GATEWAY_URL}|g" \
    -e "s|\${MCP_GATEWAY_TOKEN}|${MCP_GATEWAY_TOKEN}|g" \
    "$SCRIPT_DIR/config/hermes-config.yaml.template" > /tmp/hermes-config.yaml
openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /sandbox/.hermes
openshell sandbox upload "$SANDBOX_NAME" /tmp/hermes-config.yaml /sandbox/.hermes/config.yaml

# Step 9: Inject MCP config (appends mcp_servers to config.yaml)
step "Inject MCP Gateway config into Hermes"
inject_mcp_config_hermes "$SANDBOX_NAME" "$MCP_GATEWAY_URL" "$MCP_GATEWAY_TOKEN"

# Step 10: Upload environment init script
step "Upload environment init script"
KC_URL="https://$(_keycloak_mcp_route)"
cat > /tmp/sandbox-init.sh << INITHEADER
#!/bin/sh
LITELLM_API_KEY="${LITELLM_API_KEY}"
LITELLM_BASE_URL="${LITELLM_BASE_URL}"
MCP_GATEWAY_TOKEN="${MCP_GATEWAY_TOKEN}"
MCP_GATEWAY_URL="${MCP_GATEWAY_URL}"
MCP_USER="${MCP_USER}"
INITHEADER
cat >> /tmp/sandbox-init.sh << 'INITBODY'

export OPENAI_API_KEY="$LITELLM_API_KEY"
export OPENAI_BASE_URL="$LITELLM_BASE_URL"
export HERMES_HOME="/sandbox/.hermes"
export PATH="/sandbox/.local/bin:$PATH"
export MCP_GATEWAY_TOKEN="$MCP_GATEWAY_TOKEN"
export MCP_GATEWAY_URL="$MCP_GATEWAY_URL"

echo ""
echo "=== Hermes + MCP Gateway ==="
echo ""
echo "MCP User:    $MCP_USER"
echo "MCP Gateway: $MCP_GATEWAY_URL"
echo ""
echo "Run: hermes"
echo ""
INITBODY
openshell sandbox upload "$SANDBOX_NAME" /tmp/sandbox-init.sh /sandbox/.sandbox-init.sh

step "Auto-source environment on login"
openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c '
    grep -q "sandbox-init.sh" /sandbox/.profile 2>/dev/null || \
    cat >> /sandbox/.profile << '"'"'PROFILE'"'"'

# Auto-load sandbox credentials
if [ -f /sandbox/.sandbox-init.sh ] && [ -z "$SANDBOX_ENV_LOADED" ]; then
    . /sandbox/.sandbox-init.sh
    export SANDBOX_ENV_LOADED=1
fi
PROFILE
'

# Step 11: Create token refresh script
step "Create token refresh script"
create_token_refresh_script "$SANDBOX_NAME" "$KC_URL" "$MCP_USER" "$MCP_USER"

info "NOTE: Network policy is enforced via the CONNECT proxy when using openshell CLI tools."
info "Direct pod access (oc exec / OCP console) bypasses the sandbox security model."

# Step 12: Connectivity tests
step "Test LiteLLM from sandbox"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X POST "${LITELLM_BASE_URL}/chat/completions" -H "Authorization: Bearer ${LITELLM_API_KEY}" -H "Content-Type: application/json" -d '{"model":"'"${LITELLM_MODEL:-gemini-2.5-pro}"'","messages":[{"role":"user","content":"Say ok"}],"max_tokens":5}' 2>&1 | grep -v "Using sandbox")
HTTP_CODE=$(echo "$RESULT" | tail -1)
if [ "$HTTP_CODE" = "200" ]; then
    info "LiteLLM test: OK (HTTP 200) - model: ${LITELLM_MODEL:-gemini-2.5-pro}"
else
    warn "LiteLLM test: HTTP $HTTP_CODE"
fi

step "Test MCP Gateway from sandbox"
MCP_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${MCP_GATEWAY_TOKEN}" "${MCP_GATEWAY_URL}/mcp" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' 2>&1 | grep -v "Using sandbox" || echo "000")
if [ "$MCP_CODE" = "200" ]; then
    info "MCP Gateway test: OK (HTTP 200)"
else
    warn "MCP Gateway test: HTTP $MCP_CODE"
fi

step "Verify MCP tools"
verify_mcp_tools "$MCP_GATEWAY_TOKEN"

echo ""
echo "============================================"
echo " Sandbox '$SANDBOX_NAME' ready!"
echo "============================================"
echo ""
echo " Connect with:"
echo "   openshell sandbox connect $SANDBOX_NAME"
echo ""
echo " Inside the sandbox (credentials auto-loaded):"
echo "   hermes                    # interactive CLI"
echo "   hermes gateway run        # gateway mode (port 8787)"
echo ""
echo " MCP User: $MCP_USER"
echo " MCP Gateway: $MCP_GATEWAY_URL"
echo " Model: ${LITELLM_MODEL:-gemini-2.5-pro}"
echo ""
echo " Token refresh (if token expires):"
echo "   source /sandbox/refresh-mcp-token.sh"
echo ""
