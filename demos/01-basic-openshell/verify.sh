#!/bin/bash
# Verify Demo 1: Check that OpenShell is running correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell}"
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
echo " Verify Demo 1: Basic OpenShell"
echo "============================================"
echo ""

check "Agent Sandbox CRD exists" oc get crd sandboxes.agents.x-k8s.io
check "Namespace exists" oc get ns "$NAMESPACE"
check "Gateway pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s
check "Gateway service exists" oc -n "$NAMESPACE" get svc openshell
check "Route exists" oc -n "$NAMESPACE" get route openshell-gw

GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$GW_ROUTE" ]; then
    TERMINATION=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    if [ "$TERMINATION" = "passthrough" ]; then
        check "Gateway reachable via Route (TLS)" curl -sk --max-time 5 -o /dev/null -w '' "https://$GW_ROUTE"
    else
        check "Gateway reachable via Route" curl -s --max-time 5 -o /dev/null -w '' "http://$GW_ROUTE"
    fi
fi

if command -v openshell &>/dev/null; then
    check "openshell CLI connectivity" openshell status
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
