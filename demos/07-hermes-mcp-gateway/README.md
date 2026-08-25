# Demo 7: Hermes Agent with MCP Gateway (Gitea Tools)

Run the [Hermes AI agent](https://github.com/NousResearch/hermes-agent) inside an OpenShell sandbox on OpenShift, connected to an MCP Gateway that provides Gitea tools with RBAC via Keycloak.

By default the sandbox uses **user2** (read-only Gitea access). You can switch to **user1** for full access.

## Architecture

```
openshell CLI
    |
    v
OpenShell Gateway (Helm, StatefulSet)
    |
    v
Sandbox Pod
  +--------------------------------------+
  | Hermes Agent                         |
  |   OPENAI_BASE_URL ----------------->|---> LiteLLM MaaS (inference)
  |   HERMES_HOME                        |
  |   /sandbox/.hermes/                  |
  |     config.yaml (MCP config inside)  |
  |                                      |
  |   MCP Gateway ---------------------->|---> MCP Gateway (edge TLS)
  |     - list_user_repos                |       |
  |     - get_file_content               |       v
  |     - create_issue                   |     Keycloak (RBAC)
  |     - ...                            |       |
  |                                      |       v
  |                                      |     Gitea MCP Server
  |                                      |       |
  |                                      |       v
  |                                      |     Gitea (git repos)
  +--------------------------------------+
```

## Prerequisites

- OpenShift 4.19+ cluster with `oc` CLI logged in
- Helm 3.x
- `openshell` CLI installed
- `.env` file at repo root with LiteLLM credentials (copy from `.env.example`)
- MCP Gateway deployed on the cluster (see `manifests/mcp-gateway/`)
- Keycloak deployed with `mcp` realm

## Quick Start

```bash
# 1. Deploy everything (Gitea, MCP server, OpenShell gateway)
bash install.sh

# 2. Register gateway
openshell gateway add http://$(oc -n openshell-demo-hermes-mcp get route openshell-gw -o jsonpath='{.spec.host}') --local --name openshift

# 3. Create Hermes sandbox (read-only by default)
bash setup-sandbox.sh --user user2

# 4. Or with full Gitea access
bash setup-sandbox.sh --user user1

# 5. Connect
openshell sandbox connect hermes-mcp-demo
# Inside sandbox: hermes
```

## RBAC - User Permissions

| User | Gitea Access | MCP Tools |
|------|-------------|-----------|
| user1 | Full (owner) | All tools: list repos, get files, create issues, create PRs, create repos, fork, branch management |
| user2 | Read-only | Read tools only: list repos, get files, list issues, list PRs, list topics |

The RBAC is enforced at the Keycloak level. When user2 tries to call a write tool (like `create_issue`), the MCP Gateway rejects the request.

## Token Refresh

MCP Gateway tokens expire (Keycloak JWT). Inside the sandbox, refresh with:

```bash
source /sandbox/refresh-mcp-token.sh
```

## Network Policy

Standard-MCP tier allows:
- LiteLLM MaaS (inference)
- PyPI (Hermes skill/plugin installs)
- GitHub (read-only)
- NousResearch (model catalog)
- MCP Gateway (Gitea tools via streamable HTTP)
- Keycloak (token refresh)
- Gitea (git operations)

Blocks: direct AI APIs, arbitrary web access, GitHub write operations.

Test with: `bash test-sandbox-security.sh`

## Teardown

```bash
bash teardown.sh              # remove gateway + namespace + MCP server
bash teardown.sh --gitea      # also remove Gitea
bash teardown.sh --crd        # also remove Agent Sandbox operator
bash teardown.sh --gitea --crd  # remove everything
```
