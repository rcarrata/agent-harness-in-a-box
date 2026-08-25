#!/bin/bash
# Shared functions for Gitea deployment on OpenShift.
# Source this file after common/functions.sh.

GITEA_NS="${GITEA_NS:-gitea}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-gitea-admin}"

_gitea_user_pass() {
    case "$1" in
        user1) echo "User1Pass123!" ;;
        user2) echo "User2Pass123!" ;;
        *) echo "$1" ;;
    esac
}

_gitea_route() {
    oc -n "$GITEA_NS" get route gitea -o jsonpath='{.spec.host}' 2>/dev/null
}

_gitea_url() {
    echo "https://$(_gitea_route)"
}

_gitea_api() {
    local method="$1" path="$2"
    shift 2
    curl -sk -X "$method" \
        -H "Content-Type: application/json" \
        -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
        "$(_gitea_url)/api/v1${path}" "$@"
}

deploy_gitea() {
    step "Deploying Gitea"
    local apps_domain
    apps_domain=$(detect_apps_domain)

    if helm status gitea -n "$GITEA_NS" &>/dev/null; then
        info "Gitea Helm release exists, ensuring route..."
        if ! oc -n "$GITEA_NS" get route gitea &>/dev/null; then
            oc -n "$GITEA_NS" create route edge gitea \
                --service=gitea-http --port=http \
                --hostname="gitea-${GITEA_NS}.${apps_domain}"
        fi
        wait_for_pod_ready "$GITEA_NS" "app.kubernetes.io/name=gitea" 180
        return 0
    fi

    info "Adding Gitea Helm repo..."
    helm repo add gitea-charts https://dl.gitea.com/charts/ 2>/dev/null
    helm repo update gitea-charts 2>/dev/null

    info "Installing Gitea via Helm..."
    helm install gitea gitea-charts/gitea \
        --namespace "$GITEA_NS" --create-namespace \
        --set gitea.admin.username="$GITEA_ADMIN_USER" \
        --set gitea.admin.password="$GITEA_ADMIN_PASS" \
        --set gitea.admin.email="admin@gitea.local" \
        --set postgresql-ha.enabled=false \
        --set postgresql.enabled=true \
        --set valkey-cluster.enabled=false \
        --set valkey.enabled=true \
        --set persistence.size=1Gi \
        --set "gitea.config.server.ROOT_URL=https://gitea-${GITEA_NS}.${apps_domain}" \
        --set "gitea.config.server.DOMAIN=gitea-${GITEA_NS}.${apps_domain}" \
        --set gitea.config.server.PROTOCOL=http \
        --set gitea.config.service.DISABLE_REGISTRATION=true \
        --set gitea.config.security.MIN_PASSWORD_LENGTH=4 \
        --set image.rootless=true \
        --set podSecurityContext.fsGroup=null \
        --set containerSecurityContext.runAsUser=null \
        --timeout 300s \
        --wait

    info "Creating OpenShift Route for Gitea..."
    if ! oc -n "$GITEA_NS" get route gitea &>/dev/null; then
        oc -n "$GITEA_NS" create route edge gitea \
            --service=gitea-http --port=http \
            --hostname="gitea-${GITEA_NS}.${apps_domain}"
    fi

    info "Waiting for Gitea to be ready..."
    wait_for_pod_ready "$GITEA_NS" "app.kubernetes.io/name=gitea" 180

    local gitea_url
    gitea_url=$(_gitea_url)
    local retries=0
    while [ $retries -lt 30 ]; do
        if curl -sk "${gitea_url}/api/v1/version" | grep -q version; then
            info "Gitea API is responding at $gitea_url"
            return 0
        fi
        retries=$((retries + 1))
        sleep 5
    done
    error "Gitea API did not become ready"
    return 1
}

create_gitea_users() {
    step "Creating Gitea users"

    for user in user1 user2; do
        if _gitea_api GET "/users/${user}" 2>/dev/null | grep -q "\"login\":\"${user}\""; then
            info "User '${user}' already exists"
            continue
        fi

        local is_admin=false
        [ "$user" = "user1" ] && is_admin=true

        local user_pass="$(_gitea_user_pass "$user")"
        info "Creating user '${user}'..."
        _gitea_api POST "/admin/users" \
            -d "{
                \"username\": \"${user}\",
                \"password\": \"${user_pass}\",
                \"email\": \"${user}@gitea.local\",
                \"must_change_password\": false,
                \"login_name\": \"${user}\",
                \"source_id\": 0,
                \"visibility\": \"public\"
            }" >/dev/null
    done

    info "Gitea users created: user1 (owner), user2 (reader)"
}

create_gitea_pats() {
    step "Creating Gitea Personal Access Tokens"

    local pats_file="${1:-.gitea-pats}"

    for user in user1 user2; do
        local existing
        existing=$(curl -sk -u "${user}:$(_gitea_user_pass "$user")" \
            "$(_gitea_url)/api/v1/users/${user}/tokens" 2>/dev/null \
            | grep -o '"name":"mcp-gateway"' || true)

        if [ -n "$existing" ]; then
            warn "PAT 'mcp-gateway' already exists for ${user} - delete and recreate if needed"
            continue
        fi

        local scopes='["read:user","write:user","read:repository","read:organization","read:issue"]'
        [ "$user" = "user1" ] && scopes='["all"]'

        info "Creating PAT for ${user}..."
        local token
        token=$(curl -sk -u "${user}:$(_gitea_user_pass "$user")" \
            -X POST \
            -H "Content-Type: application/json" \
            "$(_gitea_url)/api/v1/users/${user}/tokens" \
            -d "{\"name\": \"mcp-gateway\", \"scopes\": ${scopes}}" \
            | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)

        if [ -z "$token" ]; then
            error "Failed to create PAT for ${user}"
            return 1
        fi

        echo "${user}=${token}" >> "$pats_file"
        info "PAT created for ${user}"
    done

    info "PATs saved to $pats_file"
}

create_demo_repos() {
    step "Creating demo repositories"

    local repos=("agent-workspace" "team-docs")
    local gitea_url
    gitea_url=$(_gitea_url)

    for repo in "${repos[@]}"; do
        if curl -sk -u "user1:$(_gitea_user_pass user1)" \
            "${gitea_url}/api/v1/repos/user1/${repo}" 2>/dev/null \
            | grep -q "\"name\":\"${repo}\""; then
            info "Repo 'user1/${repo}' already exists"
            continue
        fi

        local desc="Demo repository for OpenShell MCP Gateway integration"
        [ "$repo" = "agent-workspace" ] && desc="Python project for agent coding tasks"
        [ "$repo" = "team-docs" ] && desc="Team documentation and notes"

        info "Creating repo 'user1/${repo}'..."
        curl -sk -u "user1:$(_gitea_user_pass user1)" \
            -X POST \
            -H "Content-Type: application/json" \
            "${gitea_url}/api/v1/user/repos" \
            -d "{
                \"name\": \"${repo}\",
                \"description\": \"${desc}\",
                \"auto_init\": true,
                \"default_branch\": \"main\",
                \"private\": false
            }" >/dev/null

        info "Adding user2 as read-only collaborator on ${repo}..."
        curl -sk -u "user1:$(_gitea_user_pass user1)" \
            -X PUT \
            -H "Content-Type: application/json" \
            "${gitea_url}/api/v1/repos/user1/${repo}/collaborators/user2" \
            -d '{"permission": "read"}' >/dev/null
    done

    if [ "agent-workspace" = "${repos[0]}" ]; then
        info "Adding sample files to agent-workspace..."
        local content
        content=$(echo -e "# Agent Workspace\n\nA Python project for testing MCP Gateway integration.\n" | base64)
        curl -sk -u "user1:$(_gitea_user_pass user1)" \
            -X POST \
            -H "Content-Type: application/json" \
            "${gitea_url}/api/v1/repos/user1/agent-workspace/contents/README.md" \
            -d "{
                \"content\": \"${content}\",
                \"message\": \"Add README\"
            }" >/dev/null 2>&1 || true

        local py_content
        py_content=$(echo -e 'def hello():\n    return "Hello from OpenShell sandbox"\n\nif __name__ == "__main__":\n    print(hello())' | base64)
        curl -sk -u "user1:$(_gitea_user_pass user1)" \
            -X POST \
            -H "Content-Type: application/json" \
            "${gitea_url}/api/v1/repos/user1/agent-workspace/contents/main.py" \
            -d "{
                \"content\": \"${py_content}\",
                \"message\": \"Add main.py\"
            }" >/dev/null 2>&1 || true
    fi

    info "Demo repos created: user1/agent-workspace, user1/team-docs"
}

teardown_gitea() {
    step "Removing Gitea"
    helm uninstall gitea --namespace "$GITEA_NS" 2>/dev/null || true
    oc delete ns "$GITEA_NS" --wait=false 2>/dev/null || true
    info "Gitea removed"
}
