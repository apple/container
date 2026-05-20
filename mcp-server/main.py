from fastapi import FastAPI, HTTPException, Body, Depends, Header
from pydantic import BaseModel
from typing import List, Optional, Dict
import uuid
import os
import subprocess
import json

app = FastAPI(title="container MCP", version="0.2.0")


class ContainerInfo(BaseModel):
    id: str
    name: str
    status: str


class StartRequest(BaseModel):
    image: str
    name: Optional[str] = None
    env: Optional[Dict[str, str]] = None


class ExecRequest(BaseModel):
    id: str
    cmd: List[str]


# In-memory store for demonstration and tests. Replace with real backend.
CONTAINERS: Dict[str, Dict] = {
    "abc123": {"id": "abc123", "name": "example", "status": "stopped"}
}


def optional_auth(x_api_key: Optional[str] = Header(None)):
    """Optional API-key enforcement controlled by environment variable.

    Set `MCP_REQUIRE_AUTH=1` and `MCP_API_KEY` to enable.
    """
    if os.getenv("MCP_REQUIRE_AUTH") == "1":
        expected = os.getenv("MCP_API_KEY", "dev-key")
        if x_api_key != expected:
            raise HTTPException(status_code=401, detail="Invalid API key")
    return True


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/containers", response_model=List[ContainerInfo])
def list_containers(_auth: bool = Depends(optional_auth)):
    # Try to call the project's Swift CLI and return JSON output when available.
    try:
        out = run_swift_cli(["container", "list", "--format", "json", "--all"])
        items = json.loads(out)
        # The CLI prints array of PrintableContainer; map to our simplified ContainerInfo
        result = []
        for it in items:
            cfg = it.get("configuration", {})
            cid = cfg.get("id") or it.get("id") or it.get("configuration", {}).get("id")
            name = cfg.get("image", {}).get("reference") if cfg.get("image") else cfg.get("id")
            status = it.get("status") or cfg.get("state") or "unknown"
            result.append(ContainerInfo(id=cid or "", name=name or "", status=status))
        return result
    except Exception:
        return [ContainerInfo(**c) for c in CONTAINERS.values()]


def run_swift_cli(args: List[str]) -> str:
    # args are appended after `swift run`
    cmd = ["swift", "run"] + args
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"cli failed: {proc.stderr.strip()}")
    return proc.stdout


@app.get("/containers/{id}", response_model=ContainerInfo)
def get_container(id: str, _auth: bool = Depends(optional_auth)):
    c = CONTAINERS.get(id)
    if not c:
        raise HTTPException(status_code=404, detail="not found")
    return ContainerInfo(**c)


@app.post("/containers/start", response_model=ContainerInfo)
def start_container(req: StartRequest, _auth: bool = Depends(optional_auth)):
    # Try to create+start via `swift run container run <image>` (detached)
    try:
        cmd = ["container", "run", req.image]
        if req.name:
            cmd += ["--name", req.name]
        # Run detached so we get the container id printed
        cmd += ["--detach"]
        out = run_swift_cli(cmd)
        cid = out.strip().splitlines()[-1]
        info = {"id": cid, "name": req.name or req.image, "status": "running"}
        CONTAINERS[cid] = info
        return ContainerInfo(**info)
    except Exception:
        new_id = str(uuid.uuid4())[:8]
        info = {"id": new_id, "name": req.name or req.image, "status": "running"}
        CONTAINERS[new_id] = info
        return ContainerInfo(**info)


@app.post("/containers/stop", response_model=ContainerInfo)
def stop_container(id: str = Body(..., embed=True), _auth: bool = Depends(optional_auth)):
    try:
        out = run_swift_cli(["container", "stop", id])
        # CLI prints id on success; update in-memory store if present
        c = CONTAINERS.get(id)
        if c:
            c["status"] = "stopped"
            return ContainerInfo(**c)
        return ContainerInfo(id=id, name=id, status="stopped")
    except Exception:
        c = CONTAINERS.get(id)
        if not c:
            raise HTTPException(status_code=404, detail="not found")
        c["status"] = "stopped"
        return ContainerInfo(**c)


@app.post("/containers/exec")
def exec_in_container(req: ExecRequest, _auth: bool = Depends(optional_auth)):
    # Use swift cli `container exec <id> -- <cmd...>` when available
    c = CONTAINERS.get(req.id)
    try:
        cmd = ["container", "exec", req.id, "--"] + req.cmd
        out = run_swift_cli(cmd)
        return {"id": req.id, "output": out, "exit_code": 0}
    except Exception:
        if not c:
            raise HTTPException(status_code=404, detail="not found")
        output = f"ran: {' '.join(req.cmd)}"
        return {"id": req.id, "output": output, "exit_code": 0}
