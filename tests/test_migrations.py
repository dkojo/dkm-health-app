"""Migrations and least privilege, against a real PostgreSQL.

Skipped unless TEST_DATABASE_URL points at a superuser connection (CI starts a postgres:16 service).
Mirrors Azure: a non-superuser *migrator* with CREATEROLE owns the database and runs the migrations;
the app connects as its own role and may only SELECT/INSERT/UPDATE app.users.
"""

import os
import uuid

import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg import errors, sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from app import main, migrate

SUPER_URL = os.getenv("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not SUPER_URL, reason="TEST_DATABASE_URL not set")

APP_ROLE = "app_under_test"
APP_PASSWORD = "app-test-only"  # throwaway role in a disposable CI database


def _url(user: str, password: str, dbname: str) -> str:
    base = conninfo_to_dict(SUPER_URL)
    base.update(user=user, password=password, dbname=dbname)
    return make_conninfo(**base)


@pytest.fixture(scope="module")
def database():
    name = f"t_{uuid.uuid4().hex[:8]}"
    migrator = f"migrator_{name}"
    with psycopg.connect(SUPER_URL, autocommit=True) as su:
        su.execute(
            sql.SQL("CREATE ROLE {} LOGIN CREATEROLE PASSWORD 'm'").format(sql.Identifier(migrator))
        )
        su.execute(
            sql.SQL("CREATE DATABASE {} OWNER {}").format(
                sql.Identifier(name), sql.Identifier(migrator)
            )
        )
        su.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(APP_ROLE)))
    yield {"name": name, "migrator_url": _url(migrator, "m", name)}
    with psycopg.connect(SUPER_URL, autocommit=True) as su:
        su.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(name)))
        su.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(APP_ROLE)))
        su.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(migrator)))


@pytest.fixture(scope="module")
def migrated(database):
    os.environ["LOCAL_APP_ROLE_PASSWORD"] = APP_PASSWORD
    try:
        # Like Azure: the role is created over a separate connection to the "postgres" database.
        roles_url = database["migrator_url"].replace(
            f"dbname={database['name']}", "dbname=postgres"
        )
        assert roles_url != database["migrator_url"]
        with (
            psycopg.connect(database["migrator_url"]) as conn,
            psycopg.connect(roles_url) as roles_conn,
        ):
            first = migrate.migrate(conn, APP_ROLE, roles_conn)
        with psycopg.connect(database["migrator_url"]) as conn:
            second = migrate.migrate(conn, APP_ROLE)
    finally:
        del os.environ["LOCAL_APP_ROLE_PASSWORD"]
    return {**database, "first": first, "second": second}


def _app_conn(db):
    return psycopg.connect(_url(APP_ROLE, APP_PASSWORD, db["name"]))


def test_all_migrations_apply_once_and_rerun_is_a_no_op(migrated):
    expected = sorted(p.stem for p in migrate.MIGRATIONS_DIR.glob("*.sql"))
    assert migrated["first"] == expected
    assert migrated["second"] == []


def test_app_role_is_not_privileged(migrated):
    with _app_conn(migrated) as conn:
        row = conn.execute(
            "SELECT rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname = current_user"
        ).fetchone()
    assert row == (False, False, False)


def test_app_role_can_read_write_its_table(migrated):
    uid = uuid.uuid4()
    with _app_conn(migrated) as conn:
        conn.execute(
            "INSERT INTO app.users (id, email, password_hash) VALUES (%s, %s, 'h')",
            (uid, f"{uid}@example.com"),
        )
        conn.execute("UPDATE app.users SET failed_logins = 1 WHERE id = %s", (uid,))
        assert conn.execute("SELECT failed_logins FROM app.users WHERE id = %s", (uid,)).fetchone()


@pytest.mark.parametrize(
    "statement",
    [
        "DELETE FROM app.users",
        "DROP TABLE app.users",
        "ALTER TABLE app.users ADD COLUMN x int",
        "TRUNCATE app.users",
        "CREATE TABLE app.sneaky (id int)",
        "CREATE TABLE public.sneaky (id int)",
        "SELECT * FROM app.schema_migrations",
        "CREATE ROLE sneaky",
    ],
)
def test_app_role_is_denied_everything_else(migrated, statement):
    with _app_conn(migrated) as conn, pytest.raises(errors.InsufficientPrivilege):
        conn.execute(statement)


def test_register_and_login_work_as_the_app_role(migrated, monkeypatch):
    monkeypatch.setenv("PGHOST", "test")  # take the "Azure configured" code paths
    monkeypatch.setattr(main, "db", lambda: _app_conn(migrated))
    events = []
    monkeypatch.setattr(main, "audit", lambda event, outcome, *_: events.append((event, outcome)))
    client = TestClient(main.app)
    creds = {"email": "flow@example.com", "password": "a-long-enough-password"}

    assert client.post("/register", json=creds).status_code == 202
    assert client.post("/register", json=creds).status_code == 202
    assert client.post("/login", json=creds).status_code == 200
    bad = {**creds, "password": "the-wrong-password!"}
    assert client.post("/login", json=bad).status_code == 401
    assert events == [
        ("user.register", "created"),
        ("user.register", "duplicate"),
        ("user.login", "success"),
        ("user.login", "bad_password"),
    ]
