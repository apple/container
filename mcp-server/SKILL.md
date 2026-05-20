Skill: container (MCP server)
------------------------------

Short description

Provides an agent-friendly MCP surface for the `container` project. Exposes listing, lifecycle, and exec operations so agents can inspect and control containers.

Triggers

- When asked to list containers, start/stop containers, run commands, or inspect container state.

Capabilities

- `list_containers`: returns `id`, `name`, `status`.
- `start_container(image, name, env)`: starts a container and returns its info.
- `stop_container(id)`: stops the given container.
- `exec_in_container(id, cmd)`: executes a command and returns output + exit code.

Auth & security

This SKILL assumes the MCP server runs in a trusted environment. Production deployments should add authentication (mTLS, API keys) and RBAC checks.

Examples

User: "Start a container for image `ubuntu:24.04` and run `uname -a` inside it."
Agent: calls `start_container`, waits for `running`, then calls `exec_in_container`.

Notes for implementers

- Implement concrete handlers in `mcp-server/main.py` to call the project's Swift APIs or shell out to the `container` CLI.
- The scaffold uses an in-memory store; replace `CONTAINERS` with a backend bridge (gRPC, Swift bindings, or CLI calls).
- Add robust error codes, streaming exec output support, timeouts, and RBAC checks for production.
