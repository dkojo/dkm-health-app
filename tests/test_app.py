from fastapi.testclient import TestClient

from app.main import app, hasher

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_security_headers_present():
    r = client.get("/health")
    for h in ("Strict-Transport-Security", "X-Content-Type-Options", "Content-Security-Policy"):
        assert h in r.headers


def test_password_policy_rejects_short_password():
    r = client.post("/register", json={"email": "a@example.com", "password": "short"})
    assert r.status_code == 422


def test_register_response_does_not_leak_existence():
    body = {"email": "a@example.com", "password": "a-long-enough-password"}
    first = client.post("/register", json=body)
    second = client.post("/register", json=body)
    assert first.status_code == second.status_code == 202
    assert first.json() == second.json()


def test_passwords_are_argon2id_hashed():
    h = hasher.hash("a-long-enough-password")
    assert h.startswith("$argon2id$")
    assert hasher.verify(h, "a-long-enough-password")


def test_api_docs_disabled():
    assert client.get("/docs").status_code == 404
