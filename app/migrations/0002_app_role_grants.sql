-- Least privilege for the app: read, register and update login state. No DELETE (the app never deletes
-- accounts), no DDL, no access to the migration history.
GRANT USAGE ON SCHEMA app TO {app_role};
GRANT SELECT, INSERT, UPDATE ON app.users TO {app_role};
