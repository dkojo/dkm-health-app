# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub: **Security** tab → **Report a vulnerability**
(private vulnerability reporting is enabled on this repository). You can expect an
acknowledgement within 7 days.

Useful details: affected file/workflow, steps to reproduce, and impact.

## Scope

This is a learning and portfolio project that demonstrates secure CI/CD practices for a
regulated (healthcare) workload. It is **not** a production service, holds no real patient
data, and is not certified against HIPAA or SOC 2.

In scope: application code (`app/`), infrastructure as code (`infra/`), GitHub Actions
workflows (`.github/workflows/`), and the bootstrap script (`scripts/`).

## Supported versions

Only the `main` branch is maintained.
