#!/bin/bash
# Shared functions for MCP Gateway integration.
# Source this file after common/functions.sh.

MCP_GW_NS="${MCP_GW_NS:-mcp-gateway}"
MCP_TEST_NS="${MCP_TEST_NS:-mcp-test}"

_mcp_gateway_route() {
    oc -n "$MCP_GW_NS" get route mcp-gateway -o jsonpath='{.spec.host}' 2>/dev/null
}

_mcp_gateway_url() {
    echo "https://$(_mcp_gateway_route)"
}

_keycloak_mcp_route() {
    oc -n "$MCP_TEST_NS" get route keycloak -o jsonpath='{.spec.host}' 2>/dev/null \
        || oc -n "$MCP_TEST_NS" get route keycloak-mcp-test -o jsonpath='{.spec.host}' 2>/dev/null
}

deploy_gitea_mcp_server() {
    step "Deploying Gitea MCP Server"
    local gitea_host="$1"
    local gitea_pat="$2"
    local manifests_dir="${REPO_ROOT}/manifests/mcp-gateway"

    local apps_domain
    apps_domain=$(detect_apps_domain)

    if oc -n "$MCP_TEST_NS" get deployment gitea-mcp-server &>/dev/null; then
        info "Gitea MCP server already deployed, ensuring AuthPolicy..."
        sed "s/__OCP_APPS_DOMAIN__/${apps_domain}/g" \
            "${manifests_dir}/authpolicy-gitea.yaml" \
            | oc apply -f -
        return 0
    fi

    info "Creating Gitea MCP server secret..."
    local gitea_url="$gitea_host"
    if [[ "$gitea_url" != https://* ]] && [[ "$gitea_url" != http://* ]]; then
        gitea_url="https://${gitea_host}"
    fi
    oc -n "$MCP_TEST_NS" create secret generic gitea-mcp-server \
        --from-literal=GITEA_HOST="$gitea_url" \
        --from-literal=GITEA_ACCESS_TOKEN="$gitea_pat" \
        --dry-run=client -o yaml | oc apply -f -

    info "Deploying Gitea MCP server..."
    oc apply -k "${manifests_dir}/gitea-mcp-server/"

    info "Creating HTTPRoute and MCPServerRegistration..."
    oc apply -f "${manifests_dir}/httproute-gitea.yaml"
    oc apply -f "${manifests_dir}/mcpsr-gitea.yaml"

    info "Applying AuthPolicy for Gitea RBAC..."
    sed "s/__OCP_APPS_DOMAIN__/${apps_domain}/g" \
        "${manifests_dir}/authpolicy-gitea.yaml" \
        | oc apply -f -

    wait_for_pod_ready "$MCP_TEST_NS" "app=gitea-mcp-server" 120

    info "Restarting MCP Gateway broker to discover new server..."
    oc -n "$MCP_GW_NS" rollout restart deployment/mcp-gateway 2>/dev/null || true
    oc -n "$MCP_GW_NS" rollout status deployment/mcp-gateway --timeout=60s 2>/dev/null || true

    local retries=0
    while [ $retries -lt 10 ]; do
        if oc get mcpsr -n "$MCP_TEST_NS" gitea-mcp-server -o jsonpath='{.status.ready}' 2>/dev/null | grep -q "True"; then
            info "Gitea MCP server registered and ready"
            return 0
        fi
        retries=$((retries + 1))
        sleep 5
    done
    warn "Gitea MCPServerRegistration may not be ready yet - check with: oc get mcpsr -A"
}

update_keycloak_gitea_realm() {
    step "Updating Keycloak realm with Gitea tool roles"
    local user1_pat="$1"
    local user2_pat="$2"
    local kc_route kc_token

    kc_route=$(_keycloak_mcp_route)
    if [ -z "$kc_route" ]; then
        error "Keycloak route not found in $MCP_TEST_NS"
        return 1
    fi

    info "Getting Keycloak admin token..."
    local kc_admin_user kc_admin_pass
    kc_admin_user=$(oc -n "$MCP_TEST_NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")
    kc_admin_pass=$(oc -n "$MCP_TEST_NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")

    kc_token=$(curl -sk -X POST \
        "https://${kc_route}/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=admin-cli&username=${kc_admin_user}&password=${kc_admin_pass}" \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$kc_token" ]; then
        error "Could not get Keycloak admin token"
        return 1
    fi

    info "Ensuring gitea_pat attribute in User Profile..."
    local profile
    profile=$(curl -sk "https://${kc_route}/admin/realms/mcp/users/profile" \
        -H "Authorization: Bearer $kc_token")
    if ! echo "$profile" | grep -q '"gitea_pat"'; then
        echo "$profile" | python3 -c "
import sys, json
p = json.load(sys.stdin)
p['attributes'].append({
    'name': 'gitea_pat',
    'displayName': 'Gitea Personal Access Token',
    'permissions': {'view': ['admin'], 'edit': ['admin']},
    'multivalued': False
})
print(json.dumps(p))
" | curl -sk -X PUT "https://${kc_route}/admin/realms/mcp/users/profile" \
            -H "Authorization: Bearer $kc_token" \
            -H "Content-Type: application/json" \
            -d @- >/dev/null 2>&1
    fi

    local gitea_tools=(
        "gitea_actions_config_read"
        "gitea_actions_config_write"
        "gitea_actions_run_read"
        "gitea_actions_run_write"
        "gitea_attachment_read"
        "gitea_create_branch"
        "gitea_create_or_update_file"
        "gitea_create_release"
        "gitea_create_repo"
        "gitea_create_tag"
        "gitea_delete_branch"
        "gitea_delete_file"
        "gitea_delete_release"
        "gitea_delete_tag"
        "gitea_fork_repo"
        "gitea_get_commit"
        "gitea_get_dir_contents"
        "gitea_get_file_contents"
        "gitea_get_gitea_mcp_server_version"
        "gitea_get_latest_release"
        "gitea_get_me"
        "gitea_get_release"
        "gitea_get_repository_tree"
        "gitea_get_tag"
        "gitea_get_user_orgs"
        "gitea_issue_read"
        "gitea_issue_write"
        "gitea_label_read"
        "gitea_label_write"
        "gitea_list_branches"
        "gitea_list_commits"
        "gitea_list_issues"
        "gitea_list_my_repos"
        "gitea_list_org_repos"
        "gitea_list_pull_requests"
        "gitea_list_releases"
        "gitea_list_tags"
        "gitea_milestone_read"
        "gitea_milestone_write"
        "gitea_notification_read"
        "gitea_notification_write"
        "gitea_package_read"
        "gitea_package_write"
        "gitea_pull_request_read"
        "gitea_pull_request_review_write"
        "gitea_pull_request_write"
        "gitea_search_issues"
        "gitea_search_org_teams"
        "gitea_search_repos"
        "gitea_search_users"
        "gitea_timetracking_read"
        "gitea_timetracking_write"
        "gitea_wiki_read"
        "gitea_wiki_write"
    )

    local read_only_tools=(
        "gitea_actions_config_read"
        "gitea_actions_run_read"
        "gitea_attachment_read"
        "gitea_get_commit"
        "gitea_get_dir_contents"
        "gitea_get_file_contents"
        "gitea_get_gitea_mcp_server_version"
        "gitea_get_latest_release"
        "gitea_get_me"
        "gitea_get_release"
        "gitea_get_repository_tree"
        "gitea_get_tag"
        "gitea_get_user_orgs"
        "gitea_issue_read"
        "gitea_label_read"
        "gitea_list_branches"
        "gitea_list_commits"
        "gitea_list_issues"
        "gitea_list_my_repos"
        "gitea_list_org_repos"
        "gitea_list_pull_requests"
        "gitea_list_releases"
        "gitea_list_tags"
        "gitea_milestone_read"
        "gitea_notification_read"
        "gitea_package_read"
        "gitea_pull_request_read"
        "gitea_search_issues"
        "gitea_search_org_teams"
        "gitea_search_repos"
        "gitea_search_users"
        "gitea_timetracking_read"
        "gitea_wiki_read"
    )

    info "Creating Gitea resource client in Keycloak..."
    local client_payload="{
        \"clientId\": \"mcp-test/gitea-mcp-server\",
        \"name\": \"Gitea MCP Server Resource\",
        \"enabled\": true,
        \"bearerOnly\": true,
        \"publicClient\": false,
        \"protocol\": \"openid-connect\",
        \"defaultClientScopes\": [\"openid\"]
    }"

    curl -sk -X POST \
        "https://${kc_route}/admin/realms/mcp/clients" \
        -H "Authorization: Bearer $kc_token" \
        -H "Content-Type: application/json" \
        -d "$client_payload" 2>/dev/null || true

    local client_id
    client_id=$(curl -sk \
        "https://${kc_route}/admin/realms/mcp/clients?clientId=mcp-test/gitea-mcp-server" \
        -H "Authorization: Bearer $kc_token" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "$client_id" ]; then
        info "Creating tool roles for Gitea client..."
        for tool in "${gitea_tools[@]}"; do
            curl -sk -X POST \
                "https://${kc_route}/admin/realms/mcp/clients/${client_id}/roles" \
                -H "Authorization: Bearer $kc_token" \
                -H "Content-Type: application/json" \
                -d "{\"name\": \"tool:${tool}\"}" 2>/dev/null || true
        done
    fi

    info "Creating gitea_pat protocol mapper on mcp-gateway client..."
    local gw_client_id
    gw_client_id=$(curl -sk \
        "https://${kc_route}/admin/realms/mcp/clients?clientId=mcp-gateway" \
        -H "Authorization: Bearer $kc_token" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "$gw_client_id" ]; then
        curl -sk -X POST \
            "https://${kc_route}/admin/realms/mcp/clients/${gw_client_id}/protocol-mappers/models" \
            -H "Authorization: Bearer $kc_token" \
            -H "Content-Type: application/json" \
            -d '{
                "name": "gitea_pat",
                "protocol": "openid-connect",
                "protocolMapper": "oidc-usermodel-attribute-mapper",
                "config": {
                    "user.attribute": "gitea_pat",
                    "claim.name": "gitea_pat",
                    "jsonType.label": "String",
                    "id.token.claim": "false",
                    "access.token.claim": "true",
                    "userinfo.token.claim": "true",
                    "multivalued": "false"
                }
            }' 2>/dev/null || true
    fi

    for user in user1 user2; do
        info "Creating Keycloak user '${user}' in mcp realm..."
        local pat_value=""
        [ "$user" = "user1" ] && pat_value="$user1_pat"
        [ "$user" = "user2" ] && pat_value="$user2_pat"

        local existing_user
        existing_user=$(curl -sk \
            "https://${kc_route}/admin/realms/mcp/users?username=${user}&exact=true" \
            -H "Authorization: Bearer $kc_token")

        if echo "$existing_user" | grep -q "\"username\":\"${user}\""; then
            info "User '${user}' already exists in Keycloak mcp realm"
        else
            curl -sk -X POST \
                "https://${kc_route}/admin/realms/mcp/users" \
                -H "Authorization: Bearer $kc_token" \
                -H "Content-Type: application/json" \
                -d "{
                    \"username\": \"${user}\",
                    \"email\": \"${user}@test.com\",
                    \"emailVerified\": true,
                    \"enabled\": true,
                    \"firstName\": \"${user}\",
                    \"lastName\": \"user\",
                    \"groups\": [\"mcp-users\"],
                    \"realmRoles\": [\"mcp-user\"],
                    \"attributes\": {\"gitea_pat\": [\"${pat_value}\"]},
                    \"credentials\": [{\"type\": \"password\", \"value\": \"${user}\", \"temporary\": false}]
                }" 2>/dev/null || true
        fi

        local kc_user_id
        kc_user_id=$(curl -sk \
            "https://${kc_route}/admin/realms/mcp/users?username=${user}&exact=true" \
            -H "Authorization: Bearer $kc_token" \
            | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -n "$kc_user_id" ] && [ -n "$pat_value" ]; then
            curl -sk -X PUT \
                "https://${kc_route}/admin/realms/mcp/users/${kc_user_id}" \
                -H "Authorization: Bearer $kc_token" \
                -H "Content-Type: application/json" \
                -d "{
                    \"email\": \"${user}@test.com\",
                    \"emailVerified\": true,
                    \"firstName\": \"${user}\",
                    \"lastName\": \"user\",
                    \"attributes\": {\"gitea_pat\": [\"${pat_value}\"]}
                }" 2>/dev/null || true
        fi

        if [ -n "$client_id" ]; then
            local tools_to_assign=()
            if [ "$user" = "user1" ]; then
                tools_to_assign=("${gitea_tools[@]}")
            else
                tools_to_assign=("${read_only_tools[@]}")
            fi

            local kc_user_id
            kc_user_id=$(curl -sk \
                "https://${kc_route}/admin/realms/mcp/users?username=${user}&exact=true" \
                -H "Authorization: Bearer $kc_token" \
                | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

            for tool in "${tools_to_assign[@]}"; do
                local role_id
                role_id=$(curl -sk \
                    "https://${kc_route}/admin/realms/mcp/clients/${client_id}/roles/tool:${tool}" \
                    -H "Authorization: Bearer $kc_token" \
                    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

                if [ -n "$role_id" ] && [ -n "$kc_user_id" ]; then
                    curl -sk -X POST \
                        "https://${kc_route}/admin/realms/mcp/users/${kc_user_id}/role-mappings/clients/${client_id}" \
                        -H "Authorization: Bearer $kc_token" \
                        -H "Content-Type: application/json" \
                        -d "[{\"id\": \"${role_id}\", \"name\": \"tool:${tool}\"}]" 2>/dev/null || true
                fi
            done
        fi
    done

    info "Keycloak realm updated with Gitea tool roles"
}

get_mcp_token() {
    local username="${1:-user1}"
    local password="${2:-$username}"
    local kc_route

    kc_route=$(_keycloak_mcp_route)
    if [ -z "$kc_route" ]; then
        error "Keycloak route not found"
        return 1
    fi

    curl -sk -X POST \
        "https://${kc_route}/realms/mcp/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=mcp-gateway" \
        -d "username=${username}" \
        -d "password=${password}" \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

verify_mcp_tools() {
    step "Verifying MCP Gateway tools"
    local token="$1"
    local gw_url
    gw_url=$(_mcp_gateway_url)

    info "Initializing MCP session..."
    local session_id
    session_id=$(curl -sk -X POST "${gw_url}/mcp" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}},"id":1}' \
        -D /tmp/mcp-verify-headers 2>/dev/null >/dev/null \
        && grep -i "mcp-session-id" /tmp/mcp-verify-headers | cut -d: -f2 | tr -d ' \r')

    if [ -z "$session_id" ]; then
        warn "Could not initialize MCP session"
        return 1
    fi

    info "Listing available MCP tools..."
    local response
    response=$(curl -sk -X POST "${gw_url}/mcp" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "mcp-session-id: $session_id" \
        -d '{"jsonrpc":"2.0","method":"tools/list","id":2}')

    if echo "$response" | grep -q "gitea_"; then
        info "Gitea tools found in MCP Gateway"
        echo "$response" | grep -o '"name":"gitea_[^"]*"' | sed 's/"name":"//;s/"//' | head -10 | while read -r tool; do
            echo "  - $tool"
        done
    else
        warn "No Gitea tools found - check MCPServerRegistration status"
    fi

    local tool_count
    tool_count=$(echo "$response" | grep -o '"name":"' | wc -l | tr -d ' ')
    info "Total tools available: $tool_count"
}

inject_mcp_config_opencode() {
    local sandbox_name="$1"
    local mcp_gw_url="$2"
    local mcp_token="$3"

    info "Injecting MCP Gateway config into OpenCode..."
    local config
    config=$(cat <<JSONEOF
{
  "mcpServers": {
    "mcp-gateway": {
      "type": "sse",
      "url": "${mcp_gw_url}/mcp",
      "headers": {
        "Authorization": "Bearer ${mcp_token}"
      }
    }
  }
}
JSONEOF
)
    openshell sandbox exec --name "$sandbox_name" -- \
        bash -c "mkdir -p /sandbox/.config/opencode && echo '${config}' > /tmp/mcp-config.json"
}

inject_mcp_config_claude() {
    local sandbox_name="$1"
    local mcp_gw_url="$2"
    local mcp_token="$3"

    info "Injecting MCP Gateway config into Claude Code..."
    local config
    config=$(cat <<JSONEOF
{
  "mcpServers": {
    "mcp-gateway": {
      "type": "url",
      "url": "${mcp_gw_url}/mcp",
      "headers": {
        "Authorization": "Bearer ${mcp_token}"
      }
    }
  }
}
JSONEOF
)
    openshell sandbox exec --name "$sandbox_name" -- \
        bash -c "mkdir -p /workspace/.mcp && echo '${config}' > /workspace/.mcp.json"
}

inject_mcp_config_hermes() {
    local sandbox_name="$1"
    local mcp_gw_url="$2"
    local mcp_token="$3"

    info "Injecting MCP Gateway config into Hermes..."
    openshell sandbox exec --name "$sandbox_name" -- \
        bash -c "cat >> /sandbox/.hermes/config.yaml <<EOF

mcp_servers:
  mcp-gateway:
    url: ${mcp_gw_url}/mcp
    transport: streamable_http
    headers:
      Authorization: \"Bearer ${mcp_token}\"
EOF"
}

create_token_refresh_script() {
    local sandbox_name="$1"
    local kc_url="$2"
    local username="$3"
    local password="$4"

    info "Creating token refresh script in sandbox..."
    openshell sandbox exec --name "$sandbox_name" -- \
        bash -c "cat > /sandbox/refresh-mcp-token.sh <<'SCRIPTEOF'
#!/bin/bash
TOKEN=\$(curl -sk -X POST \\
    \"${kc_url}/realms/mcp/protocol/openid-connect/token\" \\
    -d \"grant_type=password\" \\
    -d \"client_id=mcp-gateway\" \\
    -d \"username=${username}\" \\
    -d \"password=${password}\" \\
    | grep -o '\"access_token\":\"[^\"]*\"' | cut -d'\"' -f4)
export MCP_GATEWAY_TOKEN=\"\$TOKEN\"
echo \"Token refreshed for ${username}\"
SCRIPTEOF
chmod +x /sandbox/refresh-mcp-token.sh"
}

teardown_gitea_mcp_server() {
    step "Removing Gitea MCP Server"
    oc delete mcpsr gitea-mcp-server -n "$MCP_TEST_NS" 2>/dev/null || true
    oc delete httproute gitea-mcp-server-route -n "$MCP_TEST_NS" 2>/dev/null || true
    oc delete -k manifests/mcp-gateway/gitea-mcp-server/ 2>/dev/null || true
    oc delete secret gitea-mcp-server -n "$MCP_TEST_NS" 2>/dev/null || true
    info "Gitea MCP server removed"
}
