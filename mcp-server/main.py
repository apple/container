from fastapi import FastAPI, HTTPException, Body, Depends, Header
from pydantic import BaseModel
from typing import List, Optional, Dict
import uuid
import os

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
    return [ContainerInfo(**c) for c in CONTAINERS.values()]


@app.get("/containers/{id}", response_model=ContainerInfo)
def get_container(id: str, _auth: bool = Depends(optional_auth)):
    c = CONTAINERS.get(id)
    if not c:
        raise HTTPException(status_code=404, detail="not found")
    return ContainerInfo(**c)


@app.post("/containers/start", response_model=ContainerInfo)
def start_container(req: StartRequest, _auth: bool = Depends(optional_auth)):
    new_id = str(uuid.uuid4())[:8]
    info = {"id": new_id, "name": req.name or req.image, "status": "running"}
    CONTAINERS[new_id] = info
    return ContainerInfo(**info)


@app.post("/containers/stop", response_model=ContainerInfo)
def stop_container(id: str = Body(..., embed=True), _auth: bool = Depends(optional_auth)):
    c = CONTAINERS.get(id)
    if not c:
        raise HTTPException(status_code=404, detail="not found")
    c["status"] = "stopped"
    return ContainerInfo(**c)


@app.post("/containers/exec")
def exec_in_container(req: ExecRequest, _auth: bool = Depends(optional_auth)):
    c = CONTAINERS.get(req.id)
    if not c:
        raise HTTPException(status_code=404, detail="not found")
    # Stubbed execution: in real implementation, proxy to runtime or CLI
    output = f"ran: {' '.join(req.cmd)}"
    return {"id": req.id, "output": output, "exit_code": 0}
