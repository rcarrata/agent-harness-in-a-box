#!/bin/bash
# Setup an agent sandbox with MCP Gateway integration.
# Requires Demo 6 infrastructure (Keycloak OIDC + Gitea + MCP Gateway) deployed via install.sh.
#
# Usage:
#   bash setup-sandbox.sh [--user user1|user2] [--agent opencode|claude]
#
# Defaults: --user user1 --agent opencode
#
# Environment:
#   SANDBOX_IMAGE  - Pre-baked image URL. When set, creates sandbox with --from
#                    and skips runtime install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"
source "$REPO_ROOT/common/mcp-gateway.sh"

# -- Parse arguments --
MCP_USER="user1"
AGENT="opencode"

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            MCP_USER="$2"
            shift 2
            ;;
        --agent)
            AGENT="$2"
            shift 2
            ;;
        *)
            error "Unknown argument: $1"
            echo "Usage: $0 [--user user1|user2] [--agent opencode|claude]"
            exit 1
            ;;
    esac
done

if [[ "$MCP_USER" != "user1" && "$MCP_USER" != "user2" ]]; then
    error "User must be 'user1' or 'user2'"
    exit 1
fi

if [[ "$AGENT" != "opencode" && "$AGENT" != "claude" ]]; then
    error "Agent must be 'opencode' or 'claude'"
    exit 1
fi

SANDBOX_NAME="${AGENT}-mcp-demo"

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
echo " Setup Sandbox: $SANDBOX_NAME"
echo "============================================"
echo ""
echo " Agent: $AGENT"
echo " MCP User: $MCP_USER"
echo ""

# -- Get MCP Gateway token --

step "Get MCP Gateway token for $MCP_USER"
MCP_GATEWAY_TOKEN=$(get_mcp_token "$MCP_USER" "$MCP_USER")

if [ -z "$MCP_GATEWAY_TOKEN" ]; then
    error "Failed to get MCP Gateway token for $MCP_USER"
    exit 1
fi
info "MCP Gateway token acquired for $MCP_USER"

MCP_GATEWAY_URL=$(_mcp_gateway_url)
KC_MCP_URL="https://$(_keycloak_mcp_route)"
info "MCP Gateway URL: $MCP_GATEWAY_URL"

# -- Register gateway --

step "Register OpenShell gateway"
GW_ROUTE=$(oc -n "${OPENSHELL_NS:-openshell}" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$GW_ROUTE" ]; then
    error "OpenShell gateway route not found"
    exit 1
fi

if [ "${ENABLE_TLS:-false}" = "true" ]; then
    GW_PROTO="https"
    GW_INSECURE_FLAG="--gateway-insecure"
else
    GW_PROTO="http"
    GW_INSECURE_FLAG=""
fi

KC_NAMESPACE="${KC_NAMESPACE:-openshell-keycloak}"
# shellcheck disable=SC2086
openshell gateway add "${GW_PROTO}://${GW_ROUTE}" $GW_INSECURE_FLAG \
    --name openshift \
    --oidc-issuer "http://keycloak.${KC_NAMESPACE}.svc.cluster.local/realms/openshell" \
    --oidc-client-id openshell-cli 2>/dev/null || true

# -- Register LiteLLM provider --

step "Register LiteLLM provider"
openshell provider delete litellm 2>/dev/null || true
openshell provider create \
    --name litellm \
    --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_API_KEY}" \
    --config "base_url=${LITELLM_BASE_URL}"

step "Configure inference routing"
openshell inference set --provider litellm --model "${LITELLM_MODEL:-gemini-2.5-pro}" --no-verify 2>/dev/null \
    && info "User inference route set" \
    || warn "inference set not supported by this gateway version"
openshell inference set --provider litellm --model "${LITELLM_MODEL_SMALL:-llama-scout-17b}" --system --no-verify 2>/dev/null \
    && info "System inference route set" \
    || true

# -- Render policy --

step "Render network policy (MCP-enabled)"
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

# -- Create sandbox --

step "Create sandbox: $SANDBOX_NAME"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3
if [ -n "${SANDBOX_IMAGE:-}" ]; then
    info "Using pre-baked image: $SANDBOX_IMAGE"
    openshell sandbox create --name "$SANDBOX_NAME" --from "$SANDBOX_IMAGE" --policy "$RENDERED_POLICY"
else
    openshell sandbox create --name "$SANDBOX_NAME" --policy "$RENDERED_POLICY"
fi

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

step "Apply network policy (tier: $POLICY_TIER)"
openshell policy set --policy "$RENDERED_POLICY" --wait "$SANDBOX_NAME"

# -- Agent-specific setup --

if [ "$AGENT" = "opencode" ]; then
    if [ -z "${SANDBOX_IMAGE:-}" ]; then
        step "Install OpenCode in sandbox"
        openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c 'mkdir -p /sandbox/.npm-global && export npm_config_prefix=/sandbox/.npm-global && npm install -g opencode-ai 2>&1 | tail -3'
    else
        step "Verify OpenCode in sandbox"
        openshell sandbox exec --name "$SANDBOX_NAME" -- opencode --version
    fi

    step "Upload OpenCode config with MCP Gateway"
    sed -e "s|\${LITELLM_BASE_URL}|${LITELLM_BASE_URL}|g" \
        -e "s|\${MCP_GATEWAY_URL}|${MCP_GATEWAY_URL}|g" \
        -e "s|\${MCP_GATEWAY_TOKEN}|${MCP_GATEWAY_TOKEN}|g" \
        "$SCRIPT_DIR/config/opencode-config.json" > /tmp/opencode.jsonc
    openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /sandbox/.config/opencode
    openshell sandbox upload "$SANDBOX_NAME" /tmp/opencode.jsonc /sandbox/.config/opencode/opencode.jsonc
fi

if [ "$AGENT" = "claude" ]; then
    if [ -z "${SANDBOX_IMAGE:-}" ]; then
        step "Install Claude Code in sandbox"
        openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c 'mkdir -p /sandbox/.npm-global && export npm_config_prefix=/sandbox/.npm-global && npm install -g @anthropic-ai/claude-code 2>&1 | tail -3'
    else
        step "Verify Claude Code in sandbox"
        openshell sandbox exec --name "$SANDBOX_NAME" -- claude --version
    fi

    step "Upload Claude Code MCP config"
    sed -e "s|\${MCP_GATEWAY_URL}|${MCP_GATEWAY_URL}|g" \
        -e "s|\${MCP_GATEWAY_TOKEN}|${MCP_GATEWAY_TOKEN}|g" \
        "$SCRIPT_DIR/config/claude-mcp.json" > /tmp/claude-mcp.json
    openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /workspace
    openshell sandbox upload "$SANDBOX_NAME" /tmp/claude-mcp.json /workspace/.mcp.json
fi

# -- Init script --

step "Upload environment init script"
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
export MCP_GATEWAY_TOKEN="$MCP_GATEWAY_TOKEN"
export MCP_GATEWAY_URL="$MCP_GATEWAY_URL"

export npm_config_prefix=/sandbox/.npm-global
export PATH="/sandbox/.npm-global/bin:$PATH"
export NODE_TLS_REJECT_UNAUTHORIZED="0"

echo ""
echo "=== Agent Sandbox with MCP Gateway ==="
echo ""
echo "MCP User: $MCP_USER"
echo "MCP Gateway: $MCP_GATEWAY_URL"
echo ""
echo "Fetching available models..."

MODELS=$(curl -s "${LITELLM_BASE_URL}/models" -H "Authorization: Bearer ${LITELLM_API_KEY}" 2>/dev/null \
  | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//' | sort)

if [ -z "$MODELS" ]; then
    echo "Could not fetch models. Using default: gpt-oss-120b"
    SELECTED="gpt-oss-120b"
else
    i=1
    for m in $MODELS; do
        echo "  $i) $m"
        i=$((i + 1))
    done
    echo ""
    printf "Select model [1]: "
    read choice
    if [ -z "$choice" ]; then choice=1; fi
    i=1
    SELECTED=""
    for m in $MODELS; do
        if [ "$i" = "$choice" ]; then SELECTED="$m"; break; fi
        i=$((i + 1))
    done
    if [ -z "$SELECTED" ]; then
        echo "Invalid selection. Using default: gpt-oss-120b"
        SELECTED="gpt-oss-120b"
    fi
fi

export OPENAI_MODEL="$SELECTED"
echo ""
echo "Model: $SELECTED"
echo "Run: opencode  (or: claude)"
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

# -- Token refresh script --

step "Create token refresh script"
create_token_refresh_script "$SANDBOX_NAME" "$KC_MCP_URL" "$MCP_USER" "$MCP_USER"

# -- Connectivity tests --

step "Test LiteLLM from sandbox"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s -w "\n%{http_code}" -X POST "${LITELLM_BASE_URL}/chat/completions" -H "Authorization: Bearer ${LITELLM_API_KEY}" -H "Content-Type: application/json" -d '{"model":"'"${LITELLM_MODEL:-gpt-oss-120b}"'","messages":[{"role":"user","content":"Say ok"}],"max_tokens":5}' 2>&1 | grep -v "Using sandbox")
HTTP_CODE=$(echo "$RESULT" | tail -1)
if [ "$HTTP_CODE" = "200" ]; then
    info "LiteLLM test: OK (HTTP 200) - model: ${LITELLM_MODEL:-gpt-oss-120b}"
else
    warn "LiteLLM test: HTTP $HTTP_CODE"
fi

step "Test MCP Gateway from sandbox"
MCP_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -sk -o /dev/null -w "%{http_code}" -X POST "${MCP_GATEWAY_URL}/mcp" -H "Authorization: Bearer ${MCP_GATEWAY_TOKEN}" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' 2>&1 | grep -v "Using sandbox" | tail -1)
if [ "$MCP_CODE" = "200" ]; then
    info "MCP Gateway test: OK (HTTP 200)"
else
    warn "MCP Gateway test: HTTP $MCP_CODE"
fi

step "Verify MCP tools available"
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
if [ "$AGENT" = "opencode" ]; then
    echo "   opencode"
else
    echo "   claude"
fi
echo ""
echo " Agent: $AGENT"
echo " MCP User: $MCP_USER (password: $MCP_USER)"
echo " MCP Gateway: $MCP_GATEWAY_URL"
echo " Model: ${LITELLM_MODEL:-gpt-oss-120b}"
echo ""
echo " Refresh MCP token (tokens expire after 5min):"
echo "   source /sandbox/refresh-mcp-token.sh"
echo ""
