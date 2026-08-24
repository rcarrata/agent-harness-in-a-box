#!/bin/bash
# Shared functions for agent-harness-in-a-box demos.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }

check_prereqs() {
    local missing=()
    command -v oc &>/dev/null    || missing+=("oc")
    command -v helm &>/dev/null  || missing+=("helm")
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        error "Not logged in to OpenShift. Run 'oc login' first."
        exit 1
    fi
    info "Prerequisites OK ($(oc whoami) @ $(oc whoami --show-server))"
}

detect_apps_domain() {
    oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null
}

wait_for_rollout() {
    local type="$1" name="$2" ns="$3" timeout="${4:-300}"
    info "Waiting for $type/$name in $ns (timeout: ${timeout}s)..."
    oc -n "$ns" rollout status "$type/$name" --timeout="${timeout}s"
}

wait_for_pod_ready() {
    local ns="$1" selector="$2" timeout="${3:-120}"
    info "Waiting for pod ($selector) in $ns..."
    oc -n "$ns" wait --for=condition=Ready pod -l "$selector" --timeout="${timeout}s" 2>/dev/null \
        || warn "Pod not ready yet (may still be pulling image)"
}

_find_openssl() {
    # macOS LibreSSL does not support Ed25519. Use Homebrew OpenSSL if available.
    local brew_ssl
    for p in /opt/homebrew/opt/openssl@3/bin/openssl \
             /opt/homebrew/opt/openssl/bin/openssl \
             /usr/local/opt/openssl@3/bin/openssl \
             /usr/local/opt/openssl/bin/openssl; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    # Fallback: system openssl (works on Linux, may fail on macOS)
    echo "openssl"
}

create_jwt_secret() {
    local ns="$1"
    if oc -n "$ns" get secret openshell-jwt-keys &>/dev/null; then
        info "Secret 'openshell-jwt-keys' already exists, skipping"
        return 0
    fi
    info "Generating Ed25519 JWT signing keypair..."
    local OPENSSL tmpdir kid
    OPENSSL=$(_find_openssl)
    info "Using OpenSSL: $($OPENSSL version)"
    tmpdir=$(mktemp -d)
    $OPENSSL genpkey -algorithm Ed25519 -out "$tmpdir/signing.pem" 2>/dev/null
    $OPENSSL pkey -in "$tmpdir/signing.pem" -pubout -out "$tmpdir/public.pem" 2>/dev/null
    kid=$($OPENSSL pkey -in "$tmpdir/signing.pem" -pubout -outform DER 2>/dev/null \
        | $OPENSSL dgst -sha256 -binary | $OPENSSL base64 -A | tr '+/' '-_' | tr -d '=')
    echo "$kid" > "$tmpdir/kid.txt"
    oc -n "$ns" create secret generic openshell-jwt-keys \
        --from-file=signing.pem="$tmpdir/signing.pem" \
        --from-file=public.pem="$tmpdir/public.pem" \
        --from-file=kid="$tmpdir/kid.txt"
    rm -rf "$tmpdir"
    info "JWT signing secret created"
}

install_agent_sandbox_operator() {
    step "Install Red Hat Agent Sandbox operator"

    if oc get crd sandboxes.agents.x-k8s.io &>/dev/null; then
        info "Agent Sandbox CRD already present"
        return 0
    fi

    cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: agent-sandbox-operator
  namespace: openshift-operators
spec:
  channel: preview-0.9
  installPlanApproval: Automatic
  name: agent-sandbox-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    info "Waiting for operator CSV to succeed..."
    local csv=""
    for i in $(seq 1 30); do
        csv=$(oc -n openshift-operators get subscription agent-sandbox-operator \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [ -n "$csv" ]; then
            break
        fi
        sleep 5
    done

    if [ -z "$csv" ]; then
        error "Agent Sandbox operator CSV not found after 150s"
        exit 1
    fi

    info "Waiting for $csv..."
    oc -n openshift-operators wait --for=jsonpath='{.status.phase}'=Succeeded \
        csv/"$csv" --timeout=300s
    info "Agent Sandbox operator installed ($csv)"
}

create_openshell_namespace() {
    local ns="$1"
    step "Create namespace $ns"
    oc create ns "$ns" --dry-run=client -o yaml | oc apply -f -
}

grant_privileged_scc() {
    local ns="$1"
    step "Grant privileged SCC to openshell-sandbox SA"
    oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "$ns"
}

adopt_cluster_scoped_resources() {
    local ns="$1"
    local current_ns
    current_ns=$(oc get clusterrole openshell-node-reader \
        -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)
    if [ -n "$current_ns" ] && [ "$current_ns" != "$ns" ]; then
        info "Re-annotating cluster-scoped Helm resources from $current_ns to $ns"
        for res in clusterrole/openshell-node-reader clusterrolebinding/openshell-node-reader; do
            oc annotate "$res" \
                meta.helm.sh/release-name=openshell \
                meta.helm.sh/release-namespace="$ns" --overwrite 2>/dev/null || true
            oc label "$res" \
                app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
        done
    fi
}

install_cert_manager() {
    if oc get crd certificates.cert-manager.io &>/dev/null; then
        info "cert-manager CRDs already available"
        return 0
    fi

    step "Install cert-manager Operator for Red Hat OpenShift"

    cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
    - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    info "Waiting for cert-manager operator CSV to succeed..."
    local csv=""
    for i in $(seq 1 30); do
        csv=$(oc -n cert-manager-operator get csv -o name 2>/dev/null | grep cert-manager | head -1)
        if [ -n "$csv" ]; then
            local phase
            phase=$(oc -n cert-manager-operator get "$csv" -o jsonpath='{.status.phase}' 2>/dev/null)
            if [ "$phase" = "Succeeded" ]; then
                info "cert-manager operator installed: $csv"
                break
            fi
        fi
        sleep 10
    done

    info "Waiting for cert-manager pods..."
    oc -n cert-manager wait --for=condition=Available deployment/cert-manager --timeout=120s 2>/dev/null || true
    oc -n cert-manager wait --for=condition=Available deployment/cert-manager-webhook --timeout=120s 2>/dev/null || true

    if ! oc get crd certificates.cert-manager.io &>/dev/null; then
        error "cert-manager CRDs still not available after install. Check operator status."
        return 1
    fi
    info "cert-manager ready"
}

setup_gateway_tls() {
    local ns="$1" apps_domain="$2"
    local route_host="openshell-gw-${ns}.${apps_domain}"

    install_cert_manager

    step "Ensure auth-delegator RBAC for SA token verification"
    if ! oc get clusterrolebinding openshell-auth-delegator &>/dev/null; then
        oc create clusterrolebinding openshell-auth-delegator \
            --clusterrole=system:auth-delegator \
            --serviceaccount="${ns}:openshell"
    else
        local already
        already=$(oc get clusterrolebinding openshell-auth-delegator -o json \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if any(s.get('namespace')=='$ns' and s.get('name')=='openshell' for s in d.get('subjects',[])) else 'no')" 2>/dev/null || echo "no")
        if [ "$already" = "no" ]; then
            oc patch clusterrolebinding openshell-auth-delegator --type='json' \
                -p="[{\"op\":\"add\",\"path\":\"/subjects/-\",\"value\":{\"kind\":\"ServiceAccount\",\"name\":\"openshell\",\"namespace\":\"$ns\"}}]"
        fi
    fi

    step "Create cert-manager CA chain for gateway TLS"

    cat <<EOF | oc -n "$ns" apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: openshell-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openshell-ca
spec:
  isCA: true
  commonName: openshell-ca
  secretName: openshell-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: openshell-selfsigned
    kind: Issuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: openshell-ca-issuer
spec:
  ca:
    secretName: openshell-ca-secret
EOF

    info "Waiting for CA certificate..."
    oc -n "$ns" wait --for=condition=Ready certificate/openshell-ca --timeout=60s

    cat <<EOF | oc -n "$ns" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openshell-server-tls
spec:
  secretName: openshell-tls
  duration: 8760h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
  dnsNames:
    - "${route_host}"
    - "openshell.${ns}.svc.cluster.local"
    - "openshell.${ns}.svc"
    - "openshell"
  issuerRef:
    name: openshell-ca-issuer
    kind: Issuer
EOF

    info "Waiting for server certificate..."
    oc -n "$ns" wait --for=condition=Ready certificate/openshell-server-tls --timeout=60s

    step "Create client TLS certificate for sandbox supervisor"
    cat <<EOF | oc -n "$ns" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openshell-client-tls
spec:
  secretName: openshell-client-ca
  duration: 8760h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - client auth
    - digital signature
  dnsNames:
    - "openshell-sandbox.${ns}.svc.cluster.local"
    - "*.${ns}.svc.cluster.local"
  issuerRef:
    name: openshell-ca-issuer
    kind: Issuer
EOF
    info "Waiting for client certificate..."
    oc -n "$ns" wait --for=condition=Ready certificate/openshell-client-tls --timeout=60s

    step "Update gateway config for TLS"
    local oidc_block=""
    local current_config
    current_config=$(oc -n "$ns" get configmap openshell-config -o jsonpath='{.data.gateway\.toml}' 2>/dev/null || true)
    if echo "$current_config" | grep -q '\[openshell.gateway.oidc\]'; then
        oidc_block=$(echo "$current_config" | sed -n '/\[openshell\.gateway\.oidc\]/,/^\[/{ /^\[openshell\.gateway\.oidc\]/p; /^\[/!p; }')
    fi

    local auth_line="allow_unauthenticated_users = true"
    if [ -n "$oidc_block" ]; then
        auth_line="allow_unauthenticated_users = true"
    fi

    cat > /tmp/gateway-tls-${ns}.toml <<EOF
[openshell]
version = 1

[openshell.gateway]
bind_address          = "0.0.0.0:8080"
health_bind_address   = "0.0.0.0:8081"
metrics_bind_address  = "0.0.0.0:9090"
log_level             = "info"
sandbox_namespace     = "${ns}"
default_image         = "ghcr.io/nvidia/openshell-community/sandboxes/base:latest"
disable_tls           = false
enable_loopback_service_http = true
client_tls_secret_name = "openshell-client-ca"

[openshell.gateway.tls]
cert_path = "/etc/openshell-tls/tls.crt"
key_path  = "/etc/openshell-tls/tls.key"

[openshell.gateway.auth]
${auth_line}

${oidc_block}

[openshell.gateway.gateway_jwt]
signing_key_path = "/etc/openshell-jwt/signing.pem"
public_key_path  = "/etc/openshell-jwt/public.pem"
kid_path         = "/etc/openshell-jwt/kid"
gateway_id       = "openshell"
ttl_secs         = 3600

[openshell.drivers.kubernetes]
grpc_endpoint                = "https://openshell.${ns}.svc.cluster.local:8080"
service_account_name         = "openshell-sandbox"
supervisor_sideload_method   = "init-container"
topology                     = "combined"
sa_token_ttl_secs            = 3600
app_armor_profile            = "Unconfined"
EOF

    oc create configmap openshell-config \
        --from-file=gateway.toml="/tmp/gateway-tls-${ns}.toml" \
        -n "$ns" --dry-run=client -o yaml | oc apply -f -

    step "Mount TLS secret into gateway pod"
    local has_tls_vol
    has_tls_vol=$(oc -n "$ns" get statefulset openshell -o json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if any(v['name']=='openshell-tls' for v in d['spec']['template']['spec'].get('volumes',[])) else 'no')" 2>/dev/null || echo "no")

    if [ "$has_tls_vol" = "no" ]; then
        oc patch statefulset openshell -n "$ns" --type='json' -p='[
          {"op":"add","path":"/spec/template/spec/volumes/-",
           "value":{"name":"openshell-tls","secret":{"secretName":"openshell-tls","defaultMode":256}}},
          {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-",
           "value":{"name":"openshell-tls","mountPath":"/etc/openshell-tls","readOnly":true}}
        ]'
    fi

    step "Set HOME to writable PVC path"
    oc -n "$ns" set env statefulset/openshell HOME=/var/openshell

    step "Restart gateway with TLS"
    oc delete pod openshell-0 -n "$ns"
    oc rollout status statefulset/openshell -n "$ns" --timeout=120s

    step "Replace route with passthrough TLS"
    oc -n "$ns" delete route openshell-gw 2>/dev/null || true
    oc create route passthrough openshell-gw \
        --service=openshell --port=8080 \
        --hostname="$route_host" -n "$ns"

    info "Gateway TLS enabled at https://$route_host"
    info "CLI: openshell gateway add --gateway-insecure https://$route_host --local --name $ns"
    rm -f "/tmp/gateway-tls-${ns}.toml"
}

render_policy() {
    local template="$1" output="$2" domain="$3"
    if [ ! -f "$template" ]; then
        error "Policy template not found: $template"
        exit 1
    fi
    if [ -z "$domain" ]; then
        error "OCP_APPS_DOMAIN required to render policy"
        exit 1
    fi
    sed "s/__OCP_APPS_DOMAIN__/${domain}/g" "$template" > "$output"
    info "Policy rendered from $(basename "$template") (domain: $domain)"
}

# --- Security test helpers ---

_sandbox_exec() {
    local sandbox="$1"; shift
    openshell sandbox exec --name "$sandbox" -- "$@" 2>&1 | grep -v "Using sandbox"
}

test_curl() {
    local label="$1" url="$2" sandbox="$3"
    local raw code connect_code
    raw=$(_sandbox_exec "$sandbox" curl -s -o /dev/null -w '%{http_code}:%{http_connect}' --max-time 10 "$url" | tail -1)
    code="${raw%%:*}"
    connect_code="${raw##*:}"
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> HTTP %s\n" "$label" "$code"
        return 0
    elif [ "$connect_code" = "403" ]; then
        printf "  ${RED}[BLOCKED]${NC} %-55s -> CONNECT 403 (proxy denied)\n" "$label"
        return 1
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> HTTP %s\n" "$label" "${code:-ERR}"
        return 1
    fi
}

test_curl_method() {
    local label="$1" method="$2" url="$3" sandbox="$4"
    local code
    code=$(_sandbox_exec "$sandbox" curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" "$url" | tail -1)
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "404" ] || [ "$code" = "422" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> HTTP %s\n" "$label" "$code"
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> HTTP %s\n" "$label" "${code:-ERR}"
        return 1
    fi
}

test_python_url() {
    local label="$1" url="$2" sandbox="$3"
    local result
    result=$(_sandbox_exec "$sandbox" python3 -c "
import urllib.request, ssl
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    r = urllib.request.urlopen('$url', timeout=10, context=ctx)
    print(r.status)
except Exception as e:
    print('ERR: ' + str(e)[:60])
" | tail -1)
    if echo "$result" | grep -qE '^(200|301|302|401)$'; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> HTTP %s\n" "$label" "$result"
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> %s\n" "$label" "${result:-ERR}"
        return 1
    fi
}

test_file_write() {
    local label="$1" path="$2" sandbox="$3"
    local result
    result=$(_sandbox_exec "$sandbox" sh -c "touch ${path} 2>&1 && echo WRITE_OK || echo WRITE_FAIL" | tail -1)
    if [ "$result" = "WRITE_OK" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> OK\n" "$label"
        _sandbox_exec "$sandbox" rm -f "$path" >/dev/null 2>&1 || true
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> Permission denied\n" "$label"
        return 1
    fi
}

test_file_read() {
    local label="$1" path="$2" sandbox="$3"
    local result
    result=$(_sandbox_exec "$sandbox" sh -c "cat ${path} > /dev/null 2>&1 && echo READ_OK || echo READ_FAIL" | tail -1)
    if [ "$result" = "READ_OK" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> OK\n" "$label"
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> Permission denied\n" "$label"
        return 1
    fi
}

test_process() {
    local label="$1" cmd="$2" expect="$3" sandbox="$4"
    local actual
    actual=$(_sandbox_exec "$sandbox" sh -c "$cmd" | tail -1)
    if [ "$actual" = "$expect" ]; then
        printf "  ${GREEN}[VERIFY]${NC}  %-55s -> %s\n" "$label" "$actual"
        return 0
    else
        printf "  ${YELLOW}[CHECK]${NC}  %-55s -> %s (expected: %s)\n" "$label" "$actual" "$expect"
        return 1
    fi
}
