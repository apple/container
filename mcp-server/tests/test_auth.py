import os
from fastapi.testclient import TestClient
from main import app


client = TestClient(app)


def test_auth_enforcement(monkeypatch):
    # Enable auth and set keys
    monkeypatch.setenv("MCP_REQUIRE_AUTH", "1")
    monkeypatch.setenv("MCP_API_KEYS", "adminkey:admin,userkey:reader")

    # No key => 401
    r = client.get("/containers")
    assert r.status_code == 401

    # reader key works for list
    r = client.get("/containers", headers={"x-api-key": "userkey"})
    assert r.status_code == 200

    # reader cannot start
    r = client.post("/containers/start", json={"image": "busybox"}, headers={"x-api-key": "userkey"})
    assert r.status_code == 403

    # admin can start
    r = client.post("/containers/start", json={"image": "busybox"}, headers={"x-api-key": "adminkey"})
    assert r.status_code == 200
