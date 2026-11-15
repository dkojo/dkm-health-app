# dkm-health-app: secure CI/CD POC (GitHub Actions → Azure)

A minimal, working proof of concept for a health app that must follow HIPAA and SOC 2:
a small API that registers users and checks their logins (passwords stored as Argon2id hashes in PostgreSQL),
writes an audit trail to Azure Blob Storage, and ships through a pipeline with a security gate at every stage.

> **About this project:** a learning and portfolio project that shows how I'd build a secure delivery pipeline for
> a regulated workload. It isn't a production service and isn't certified against HIPAA or SOC 2. Never put real
> patient data (PHI) into it until the hardening backlog below is done and a compliance owner has signed off.
> See [SECURITY.md](SECURITY.md) to report issues. Licensed under [MIT](LICENSE).

---

## 1. Architecture

```
 Developer ──pre-commit (gitleaks, ruff, tf fmt)──► git push ──► Pull Request
                                                                  │
         ┌──────────────────────── CI  (.github/workflows/ci.yml) ┴────────────────────────┐
         │ 1 secrets-scan  Gitleaks                                                         │
         │ 2 code          ruff (+Bandit rules) · pytest · Semgrep (SAST) · pip-audit (SCA) │
         │ 3 iac           terraform fmt/validate · Checkov                                 │
         │ 4 image         docker build · Trivy (vulns, secrets, misconfig)                 │
         │ 5 plan          terraform plan  (read-only Azure identity via OIDC)              │
         └──────────────────────────────────────────────────────────────────────────────────┘
                                  │  review + all checks green → merge to main
         ┌──────────────────────── CD  (.github/workflows/cd.yml) ─────────────────────────┐
         │ 6 release   build · Trivy gate · SBOM · push to ACR · Cosign sign + attest       │
         │ 7 deploy    ⏸ human approval · Cosign verify · terraform apply · smoke test      │
         │ 8 dast      OWASP ZAP baseline against the live URL                              │
         └──────────────────────────────────────────────────────────────────────────────────┘
                                  │
  Azure  rg-dkm-health-prod ──────▼───────────────────────────────────────────────────────────
         Container App (managed identity) ──Entra token──► PostgreSQL Flexible (users table)
                    │                     ──Entra token──► Blob Storage (audit container)
                    └── logs ──► Log Analytics ◄── DB + Blob diagnostic logs
  Azure  rg-dkm-health-shared: ACR (artifact repository) · Terraform state storage
```

**No secrets exist anywhere.** GitHub signs in to Azure with OIDC (short-lived tokens). The app reaches the
database and storage with its managed identity. Database passwords and storage keys are switched off.

## 2. Key decisions and design notes

| Topic | Decision | Why |
|---|---|---|
| CI/CD tool | **GitHub Actions only** (no Azure DevOps) | You asked for both; running two tools doubles the access to audit and secure. GitHub Actions + Azure OIDC covers everything. |
| Artifact repository | **Azure Container Registry** (the "artifactory") | It's in the same Azure tenant and RBAC, and it's in scope for Microsoft's HIPAA BAA. JFrog Artifactory adds cost and another vendor for a POC. |
| Compute | **Azure Container Apps** | Serverless containers with managed identity and HTTPS built in, without having to run Kubernetes. |
| Database | **PostgreSQL Flexible Server**, Entra ID auth only | No DB passwords; encrypted at rest; 35-day backups (geo-redundant). |
| Passwords | **Argon2id** hashes, 12+ characters, lockout after 5 failures | Current OWASP recommendation. |
| Production identity | **Microsoft Entra External ID** | Best practice is to *not* store passwords yourself. It gives you MFA, password reset, breach detection and session tokens. The POC stores hashes so you can see the database working end to end. |
| IaC | Terraform, state in Entra-only, versioned blob storage | Plan shows up on every PR; changes can be audited. |

**Design note 1: user registrations don't go through CI/CD.** A new user signing up is *data*. It is written to
the database while the app runs, in milliseconds, and never touches the pipeline. CI/CD carries *changes to code
and infrastructure*: a new feature, a schema change (for example, adding a column to `users`), a dependency
bump, a firewall rule. Every one of those goes through PR → scans → plan → approval → deploy. What you *can*
track is registrations: each one writes an audit record to Blob Storage and Log Analytics.

**Design note 2: an Azure account alone doesn't make you "HIPAA compliant".** Microsoft's BAA is included
automatically in its Product Terms for in-scope services (all the services used here are in scope). Compliance
also needs your own policies, risk assessment, access reviews, training and incident response. This repo gives
you the technical controls and the evidence trail.

## 3. Step-by-step setup

### Step 0: Create the Azure account (about 15 min)
1. Go to <https://azure.microsoft.com/free> and sign up. This needs a phone number and a card; the free offer
   includes trial credit, so check the current terms.
2. **Turn on MFA** for your account right away (Entra ID → Security → Authentication methods, or the Microsoft
   Authenticator app).
3. **Set a budget alert:** Cost Management → Budgets → create one (for example $100/month, with alerts at 50/80/100%).
4. Upgrade to **Pay-As-You-Go** before the trial ends, or resources get disabled.
5. Optional but recommended: Microsoft Defender for Cloud → turn on the free CSPM tier for posture recommendations.

### Step 1: Put the code on GitHub
```bash
cd azure-cicd
git init -b main && git add . && git commit -m "dkm-health-app POC"
gh repo create dkm-health-app --private --source . --push
```
Then in GitHub → **Settings**:
- **Branches → add a ruleset for `main`:** require a pull request, at least 1 approval, these status checks
  (`secrets-scan`, `code`, `iac`, `image`, `plan`), and no force pushes.
- **Environments → New → `production`:** add yourself (or a second person, for separation of duties) as a
  *required reviewer*, and limit deployment branches to `main`.
- **Code security:** turn on Dependabot alerts, secret scanning and push protection.

### Step 2: Bootstrap Azure (one time, about 5 min)
Open **Azure Cloud Shell** (the `>_` icon in the portal, then choose Bash), upload `scripts/bootstrap-azure.sh`, then run:
```bash
GITHUB_REPO=<your-github-user>/dkm-health-app bash bootstrap-azure.sh
```
It creates two resource groups, the Terraform state storage, ACR, and two least-privilege identities for
GitHub (CI is read-only; CD can deploy only from `main`/`production`). It finishes by printing six
`gh variable set ...` commands.

### Step 3: Connect GitHub to Azure
Run the six printed `gh variable set` commands in your repo folder. They are **variables, not secrets**:
client IDs aren't sensitive, because OIDC trust is tied to your repo and branch.

### Step 4: First run
```bash
git checkout -b feat/first-change
# make any small change, e.g. edit this README
git commit -am "test pipeline" && git push -u origin feat/first-change
gh pr create --fill
```
1. CI runs all five gates and adds the Terraform plan to the run summary.
2. Review and merge → CD builds, scans, signs and pushes the image to ACR.
3. Approve the **production** deployment in the Actions tab → Terraform creates or updates Azure and the
   smoke test hits `/health` and `/ready`. The first apply takes about 10–15 minutes (the Postgres server is
   the slow part).
4. Try it:
   ```bash
   URL=<app_url from the deploy job>
   curl -X POST $URL/register -H 'content-type: application/json' -d '{"email":"me@example.com","password":"a-long-test-password"}'
   curl -X POST $URL/login    -H 'content-type: application/json' -d '{"email":"me@example.com","password":"a-long-test-password"}'
   ```
   Then look in the Storage account → `audit` container for the audit records.

### Run locally (no Azure needed)
```bash
pip install -r requirements-dev.txt && pytest
docker build -t dkm-health-app . && docker run -p 8000:8000 dkm-health-app   # GET :8000/health
```

## 4. Pipeline stages and security controls

| # | Stage | Tools | Blocks on | Control (SOC 2 / HIPAA) |
|---|---|---|---|---|
| 0 | Commit | pre-commit: Gitleaks, ruff, terraform fmt | secrets, lint | CC8.1 change mgmt |
| 1 | Secrets | Gitleaks | any secret found | CC6.1 / 164.312(a) |
| 2 | Code | ruff + Bandit rules, pytest, Semgrep, pip-audit | lint/test fail, SAST finding, known-vulnerable dependency | CC7.1, CC8.1 |
| 3 | IaC | terraform validate, Checkov | misconfig not in `.checkov.yaml` risk register | CC7.1 |
| 4 | Image | Trivy image + config | HIGH/CRITICAL fixable CVE | CC7.1 |
| 5 | Plan | terraform plan (read-only identity) | plan error | CC8.1 (change visible before approval) |
| 6 | Release | Trivy, CycloneDX SBOM, ACR, Cosign | CVE or signing failure | CC8.1, supply-chain integrity |
| 7 | Deploy | required reviewer, Cosign verify, terraform apply, smoke test | unsigned image, failed health check | CC8.1 approval, 164.312(c) integrity |
| 8 | DAST | OWASP ZAP baseline | report only (triage into backlog) | CC7.1 |

Running across all stages: Dependabot (weekly), GitHub secret scanning with push protection, and audit logs in Log Analytics.

## 5. Agile delivery plan (2-week sprints)

| Sprint | Goal | Done when |
|---|---|---|
| **0: Foundation** *(this repo)* | Account, repo, bootstrap, CI/CD green | A PR merged by someone else deploys a signed image to Azure with approval |
| **1: Identity** | Replace self-managed passwords with **Entra External ID** (OIDC sign-in, MFA, reset) | `users` table holds no password hashes; API validates tokens |
| **2: Data lifecycle** | Versioned migrations (Alembic) as a pipeline step; staging environment before prod | Schema changes are reviewed in PRs and tested in staging first |
| **3: Private networking** | VNet, private endpoints for Postgres/Blob/ACR, remove public access; delete the matching `.checkov.yaml` skips | Checkov passes with no network exceptions |
| **4: Operate** | Alerts (failed logins, 5xx, lockouts), Defender for Cloud, immutable (WORM) audit container, 6-year log archive, DR test | Runbook + restore drill evidence |
| **5: Audit readiness** | Pin actions to commit SHAs, access reviews, policies (Azure Policy HIPAA/HITRUST initiative), pen test | Evidence package for the SOC 2 Type I auditor |

## 6. Known POC gaps (tracked, not hidden)
- Postgres and Storage have public endpoints (they only accept Entra ID auth, over TLS). Fixed in Sprint 3.
- The app identity is the Postgres Entra admin, which avoids a manual SQL step. Least-privilege role comes in Sprint 1/2.
- `/login` checks credentials but doesn't issue a session. That comes with Entra External ID in Sprint 1.
- No rate limiting at the edge yet. Add Azure Front Door + WAF in Sprint 3.
- Schema is created when the app starts. Replaced by migrations in Sprint 2.
- Cosign keyless signing records the repo name and image digest in the public Sigstore transparency log
  (no code or data). Use a Key Vault key instead if that isn't acceptable.
- Tool versions in workflows (Trivy, Gitleaks) are pinned by hand. Review them monthly, and pin actions to SHAs in Sprint 5.

## 7. Rough cost (POC, idle)
About **$50–80/month**: Container App with 1 always-on replica, Postgres B1ms, GZRS storage, ACR Basic, Log Analytics.
To save money between demos, run `az containerapp update -n ca-dkm-health-app -g rg-dkm-health-prod --min-replicas 0` and stop the Postgres server.

## Repo map
```
app/main.py                 API: /health /ready /register /login
tests/                      unit tests
Dockerfile                  multi-stage, non-root, slim
infra/*.tf                  Azure resources (Terraform)
scripts/bootstrap-azure.sh  one-time Azure + GitHub OIDC setup
.github/workflows/ci.yml    PR gates 1–5
.github/workflows/cd.yml    release, deploy, DAST (6–8)
.checkov.yaml               IaC risk register (documented exceptions)
.pre-commit-config.yaml     developer-side checks
.github/dependabot.yml      dependency updates
```
