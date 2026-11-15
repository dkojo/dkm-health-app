"""dkm-health-app: minimal POC API.

Security posture (POC):
- No secrets anywhere: Postgres and Blob are reached with the container's
  managed identity (Entra ID tokens), never passwords or connection strings.
- Passwords are stored only as Argon2id hashes.
- Audit events go to Blob Storage and contain no PHI/PII (no email, no IP).
- Responses avoid user enumeration (same answer for new/existing emails,
  same error for unknown user / wrong password).
"""

import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta

import psycopg
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from fastapi import FastAPI, HTTPException, Request, status
from pydantic import BaseModel, EmailStr, Field

log = logging.getLogger("dkm-health-app")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

PG_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
MAX_FAILED_LOGINS = 5
LOCKOUT = timedelta(minutes=15)

hasher = PasswordHasher()  # Argon2id with library-recommended parameters
_DUMMY_HASH = hasher.hash("dummy-password-for-timing")

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS users (
    id            uuid PRIMARY KEY,
    email         text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    failed_logins integer NOT NULL DEFAULT 0,
    locked_until  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);
"""

_credential = None
_blob_container = None


def _azure_configured() -> bool:
    return bool(os.getenv("PGHOST"))


def _cred():
    global _credential
    if _credential is None:
        from azure.identity import DefaultAzureCredential

        # AZURE_CLIENT_ID selects the user-assigned managed identity.
        _credential = DefaultAzureCredential()
    return _credential


def db():
    token = _cred().get_token(PG_SCOPE).token
    return psycopg.connect(
        host=os.environ["PGHOST"],
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=token,
        sslmode="require",
        connect_timeout=10,
    )


def audit_container():
    global _blob_container
    if _blob_container is None:
        from azure.storage.blob import BlobServiceClient

        svc = BlobServiceClient(os.environ["STORAGE_ACCOUNT_URL"], credential=_cred())
        _blob_container = svc.get_container_client(os.environ["AUDIT_CONTAINER"])
    return _blob_container


def audit(event: str, outcome: str, request_id: str, user_id: str | None = None) -> None:
    """Write one audit record. Never include email, password or other PII/PHI."""
    now = datetime.now(UTC)
    record = {
        "ts": now.isoformat(),
        "event": event,
        "outcome": outcome,
        "user_id": user_id,
        "request_id": request_id,
    }
    if not _azure_configured():
        log.info("audit %s", json.dumps(record))
        return
    name = f"{now:%Y/%m/%d}/{now:%H%M%S}-{request_id}.json"
    audit_container().upload_blob(name, json.dumps(record), overwrite=False)


@asynccontextmanager
async def lifespan(_: FastAPI):
    if _azure_configured():
        # POC: idempotent schema bootstrap. Replace with versioned migrations
        # (e.g. Alembic) run as a pipeline step before go-live.
        with db() as conn:
            conn.execute(SCHEMA_SQL)
        log.info("schema ready")
    yield


app = FastAPI(title="dkm-health-app", lifespan=lifespan, docs_url=None, redoc_url=None)


class Credentials(BaseModel):
    email: EmailStr
    password: str = Field(min_length=12, max_length=128)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    request.state.request_id = str(uuid.uuid4())
    response = await call_next(request)
    response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Request-ID"] = request.state.request_id
    return response


@app.get("/health")
def health():
    """Liveness: the process is up. Touches no dependencies."""
    return {"status": "ok"}


@app.get("/ready")
def ready():
    """Readiness: proves database and blob storage connectivity."""
    if not _azure_configured():
        return {"status": "ok", "mode": "local"}
    try:
        with db() as conn:
            conn.execute("SELECT 1")
        audit_container().get_container_properties()
    except Exception:
        log.exception("readiness check failed")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "dependency unavailable") from None
    return {"status": "ok"}


@app.post("/register", status_code=status.HTTP_202_ACCEPTED)
def register(body: Credentials, request: Request):
    rid = request.state.request_id
    email = body.email.lower()
    user_id = str(uuid.uuid4())
    pw_hash = hasher.hash(body.password)
    outcome = "created"
    if _azure_configured():
        with db() as conn:
            cur = conn.execute(
                "INSERT INTO users (id, email, password_hash) VALUES (%s, %s, %s) "
                "ON CONFLICT (email) DO NOTHING",
                (user_id, email, pw_hash),
            )
            if cur.rowcount == 0:
                outcome, user_id = "duplicate", None
    audit("user.register", outcome, rid, user_id)
    # Identical response either way, so the endpoint can't be used to discover accounts.
    return {"message": "If the address is eligible, the account has been registered."}


@app.post("/login")
def login(body: Credentials, request: Request):
    rid = request.state.request_id
    email = body.email.lower()
    generic = HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    if not _azure_configured():
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "database not configured")

    with db() as conn:
        row = conn.execute(
            "SELECT id, password_hash, failed_logins, locked_until FROM users WHERE email = %s",
            (email,),
        ).fetchone()

        if row is None:
            try:  # equalise timing with the real path
                hasher.verify(_DUMMY_HASH, body.password)
            except VerificationError:
                pass
            audit("user.login", "unknown_user", rid)
            raise generic

        user_id, pw_hash, failed, locked_until = row
        now = datetime.now(UTC)
        if locked_until and locked_until > now:
            audit("user.login", "locked", rid, str(user_id))
            raise generic

        try:
            password_ok = hasher.verify(pw_hash, body.password)
        except (VerifyMismatchError, InvalidHashError):
            password_ok = False

        if not password_ok:
            failed += 1
            lock = now + LOCKOUT if failed >= MAX_FAILED_LOGINS else None
            conn.execute(
                "UPDATE users SET failed_logins = %s, locked_until = %s WHERE id = %s",
                (0 if lock else failed, lock, user_id),
            )
            conn.commit()  # persist the lockout counter before raising (raise => rollback)
            audit("user.login", "bad_password", rid, str(user_id))
            raise generic

        if hasher.check_needs_rehash(pw_hash):
            conn.execute(
                "UPDATE users SET password_hash = %s WHERE id = %s",
                (hasher.hash(body.password), user_id),
            )
        conn.execute(
            "UPDATE users SET failed_logins = 0, locked_until = NULL WHERE id = %s", (user_id,)
        )

    audit("user.login", "success", rid, str(user_id))
    # POC stops here. Production: issue a session via Microsoft Entra External ID (see README).
    return {"message": "Login successful"}
