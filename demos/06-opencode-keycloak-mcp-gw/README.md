# Demo 6: OpenCode/Claude Code + Keycloak OIDC + MCP Gateway

Runs OpenCode or Claude Code agents inside OpenShell sandboxes, connected to a Gitea MCP server through the MCP Gateway. Keycloak handles authentication for both the OpenShell gateway (OIDC) and the MCP Gateway (token-based RBAC).

Two users with different permission levels show how the MCP Gateway enforces tool-level RBAC - user1 gets full access to all Gitea tools, user2 gets read-only.

## Architecture

```
+------------------+     +-------------------+     +------------------+
|  OpenCode /      |     |   MCP Gateway     |     |  Gitea MCP       |
|  Claude Code     |---->|   (edge TLS)      |---->|  Server          |
|  (sandbox)       |     |                   |     |                  |
+------------------+     +-------------------+     +------------------+
        |                         |                        |
        |                         |                        v
        v                         v                 +------------------+
+------------------+     +-------------------+     |  Gitea           |
|  LiteLLM         |     |  Keycloak (MCP)   |     |  (git repos)     |
|  (inference)     |     |  realm: mcp       |     +------------------+
+------------------+     +-------------------+
        
+------------------+
|  Keycloak (OIDC) |  <-- OpenShell gateway auth
|  realm: openshell|      (separate instance)
+------------------+
```

Two Keycloaks:
- **OpenShell Keycloak** (`openshell-keycloak` namespace) - gateway OIDC auth
- **MCP Keycloak** (`mcp-test` namespace) - MCP Gateway token auth with tool-level RBAC

## RBAC Model

| User  | MCP Gitea Tools | Description |
|-------|-----------------|-------------|
| user1 | All tools       | Create repos, issues, PRs, branches, read files |
| user2 | Read-only tools | List repos, get files, list issues (no writes)   |

## Prerequisites

- OpenShift cluster with admin access
- MCP Gateway already deployed (namespace: `mcp-gateway`)
- MCP Keycloak already deployed (namespace: `mcp-test`, realm: `mcp`)
- `.env` file with LiteLLM credentials (copy from `.env.example`)
- `oc`, `helm`, `openshell` CLI tools installed

## Quick Start

1. Deploy everything:

```bash
bash install.sh
```

2. Start Keycloak port-forward (needed for CLI login):

```bash
oc -n openshell-keycloak port-forward svc/keycloak 9090:80
```

3. Setup a sandbox with MCP Gateway access:

```bash
# OpenCode agent as user1 (full access)
bash setup-sandbox.sh --user user1 --agent opencode

# Claude Code agent as user2 (read-only)
bash setup-sandbox.sh --user user2 --agent claude
```

4. Connect to the sandbox:

```bash
openshell sandbox connect opencode-mcp-demo
# Inside sandbox, credentials auto-load:
opencode
```

5. Verify the deployment:

```bash
bash verify.sh
```

6. Test sandbox security:

```bash
bash test-sandbox-security.sh opencode-mcp-demo
```

## MCP Token Refresh

MCP Gateway tokens expire after 5 minutes. Inside the sandbox, refresh with:

```bash
source /sandbox/refresh-mcp-token.sh
```

## Teardown

```bash
# Remove OpenShell + Keycloak + MCP server (keep Gitea)
bash teardown.sh

# Also remove Gitea
bash teardown.sh --gitea

# Also remove Agent Sandbox operator CRDs
bash teardown.sh --gitea --crd
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENSHELL_NS` | `openshell` | OpenShell namespace |
| `KC_NAMESPACE` | `openshell-keycloak` | Keycloak namespace |
| `GITEA_NS` | `gitea` | Gitea namespace |
| `ENABLE_TLS` | `false` | Enable passthrough TLS on gateway |
| `POLICY_TIER` | `standard-mcp` | Network policy tier |
| `SANDBOX_IMAGE` | (none) | Pre-baked sandbox image URL |
