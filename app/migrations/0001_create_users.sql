-- Versioned migrations: one file per change, applied once in name order by app/migrate.py, each in its
-- own transaction. Never edit a file that has been applied; add a new one.
-- Placeholders: {app_role} is the app's database role (quoted identifier).
-- Every new table must GRANT the app only the privileges it actually uses.

CREATE TABLE app.users (
    id            uuid PRIMARY KEY,
    email         text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    failed_logins integer NOT NULL DEFAULT 0,
    locked_until  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);
