"""Apply versioned SQL migrations (app/migrations/*.sql).

Runs as the migrate Container Apps job under the *migrator* managed identity, the database's
Entra admin. The API never runs this and holds no DDL rights. Usage: python -m app.migrate

Environment:
  PGHOST, PGDATABASE, PGUSER   database and migrator role (Entra token auth, like the app)
  APP_DB_ROLE                  the app's database role; created if missing, granted by migrations
  DATABASE_URL                 tests/local only: connect with this URL instead of an Entra token
  LOCAL_APP_ROLE_PASSWORD      tests/local only: create APP_DB_ROLE as a password role (no Entra)
"""

import logging
import os
import sys
from pathlib import Path

import psycopg
from psycopg import sql

log = logging.getLogger("dkm-health-migrate")

MIGRATIONS_DIR = Path(__file__).parent / "migrations"
PG_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
LOCK_KEY = 7_243_001  # pg_advisory_lock key: one migration run at a time


def connect() -> psycopg.Connection:
    url = os.getenv("DATABASE_URL")
    if url:
        return psycopg.connect(url)
    from azure.identity import DefaultAzureCredential  # AZURE_CLIENT_ID selects the identity

    token = DefaultAzureCredential().get_token(PG_SCOPE).token
    return psycopg.connect(
        host=os.environ["PGHOST"],
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=token,
        sslmode="require",
        connect_timeout=10,
    )


def ensure_app_role(conn: psycopg.Connection, role: str) -> None:
    """Create the app's login role if it doesn't exist yet. It is never an admin."""
    if conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone():
        return
    local_password = os.getenv("LOCAL_APP_ROLE_PASSWORD")
    if local_password:
        conn.execute(
            sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(
                sql.Identifier(role), sql.Literal(local_password)
            )
        )
    else:
        # Azure: map the role to the managed identity of that name (is_admin=false, is_mfa=false).
        conn.execute("SELECT * FROM pgaadauth_create_principal(%s, false, false)", (role,))
    log.info("created app role %s", role)


def verify_least_privilege(conn: psycopg.Connection, role: str) -> None:
    """Fail the deploy if the app role has admin-level rights (e.g. left over from an old setup)."""
    row = conn.execute(
        "SELECT rolsuper, rolcreaterole, rolcreatedb, rolbypassrls,"
        " CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'azure_pg_admin')"
        "   THEN pg_has_role(%s, 'azure_pg_admin', 'MEMBER') ELSE false END"
        " FROM pg_roles WHERE rolname = %s",
        (role, role),
    ).fetchone()
    if row is None or any(row):
        raise RuntimeError(
            f"app role {role!r} is not least-privilege "
            f"(superuser, createrole, createdb, bypassrls, azure_pg_admin): {row}"
        )


def pending(applied: set[str]) -> list[Path]:
    return [p for p in sorted(MIGRATIONS_DIR.glob("*.sql")) if p.stem not in applied]


def migrate(conn: psycopg.Connection, app_role: str) -> list[str]:
    """Apply pending migrations; return the versions applied. Safe to run repeatedly."""
    conn.autocommit = True
    conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))
    try:
        conn.execute("CREATE SCHEMA IF NOT EXISTS app")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS app.schema_migrations ("
            " version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
        )
        ensure_app_role(conn, app_role)
        verify_least_privilege(conn, app_role)
        applied = {r[0] for r in conn.execute("SELECT version FROM app.schema_migrations")}
        done = []
        for path in pending(applied):
            statement = sql.SQL(path.read_text(encoding="utf-8")).format(
                app_role=sql.Identifier(app_role)
            )
            with conn.transaction():
                conn.execute(statement)
                conn.execute(
                    "INSERT INTO app.schema_migrations (version) VALUES (%s)", (path.stem,)
                )
            log.info("applied %s", path.stem)
            done.append(path.stem)
        return done
    finally:
        conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_KEY,))


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    with connect() as conn:
        done = migrate(conn, os.environ["APP_DB_ROLE"])
    log.info("migrations complete: %s", ", ".join(done) or "nothing pending")
    return 0


if __name__ == "__main__":
    sys.exit(main())
