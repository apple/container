from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_basic_flow():
    # list initially
    r = client.get("/containers")
    assert r.status_code == 200

    # start a container
    r = client.post("/containers/start", json={"image": "ubuntu:24.04", "name": "t1"})
    assert r.status_code == 200
    body = r.json()
    cid = body["id"] if isinstance(body, list) else body.get("id")
    assert cid

    # exec inside it
    r = client.post("/containers/exec", json={"id": cid, "cmd": ["echo", "hello"]})
    assert r.status_code == 200
    out = r.json()
    assert out["exit_code"] == 0

    # stop
    r = client.post("/containers/stop", json={"id": cid})
    assert r.status_code == 200
