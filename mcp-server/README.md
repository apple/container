Minimal MCP server scaffold for the `container` project.

Quick start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

This server provides a small, stubbed Model Context Protocol (MCP) surface that maps to the `container` project's capabilities.
Use it as a starting point to implement concrete handlers that call into the Swift codebase or perform the required operations.

Examples

- List containers:

```bash
curl -s localhost:8000/containers | jq
```

- Start a container:

```bash
curl -s -X POST localhost:8000/containers/start -H "Content-Type: application/json" -d '{"image":"ubuntu:24.04","name":"t1"}' | jq
```

- Exec inside a container (replace <id>):

```bash
curl -s -X POST localhost:8000/containers/exec -H "Content-Type: application/json" -d '{"id":"<id>","cmd":["echo","hi"]}' | jq
```

Auth

To enable API-key enforcement set `MCP_REQUIRE_AUTH=1` and `MCP_API_KEY` in the environment. Tests and local dev run with auth disabled by default.
