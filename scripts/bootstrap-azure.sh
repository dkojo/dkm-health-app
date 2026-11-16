#!/usr/bin/env bash
# One-time Azure foundation for dkm-health-app. Run from the repo root in Git Bash (Windows),
# any Linux/macOS shell, or Azure Cloud Shell (Bash), after `az login`:
#   GITHUB_REPO=<owner>/<repo> bash scripts/bootstrap-azure.sh
# Optional: LOCATION=<azure-region> (default eastus2), YES=1 to skip the confirmation prompt,
#           OIDC_PREFIX=<sub_claim_prefix> to override the GitHub OIDC subject prefix.
#
# Creates:
#   rg-dkm-health-shared : Terraform state storage + Azure Container Registry (artifact repository)
#   rg-dkm-health-prod   : empty; Terraform fills it
#   Two Entra app registrations that GitHub Actions log in as via OIDC (no secrets):
#     dkm-health-github-ci : read-only, used for PR plans
#     dkm-health-github-cd : deploys; only from main branch / "production" environment
# Safe to re-run.
set -euo pipefail

# --- Git Bash (Windows) compatibility ---------------------------------------------------------
# 1. Stop MSYS from rewriting arguments like "/subscriptions/..." into Windows paths.
# 2. The Windows Azure CLI ends every output line with CRLF; strip the CR so captured IDs are clean.
export MSYS_NO_PATHCONV=1
type -P az >/dev/null || { echo "Azure CLI not found. Install it, then run 'az login'." >&2; exit 1; }
az() { command az "$@" | tr -d '\r'; }

# Temp files are always removed, even if a command fails midway (set -e).
CLEANUP=()
trap 'rm -f "${CLEANUP[@]}"' EXIT

: "${GITHUB_REPO:?set GITHUB_REPO=<owner>/<repo>}"

# OIDC subject prefix that Azure must trust. GitHub can issue tokens whose subject embeds the
# immutable owner/repo IDs (repo:owner@123/name@456:...), so a deleted-and-recreated or
# squatted repo of the same name can't inherit access. Ask GitHub for the exact prefix.
if [ -z "${OIDC_PREFIX:-}" ] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  OIDC_PREFIX=$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>/dev/null | tr -d '\r') || true
fi
if [ -z "${OIDC_PREFIX:-}" ]; then
  echo "WARNING: couldn't read the OIDC subject prefix from GitHub (gh not logged in?). Falling back to" >&2
  echo "         repo:$GITHUB_REPO. If Azure login later fails with AADSTS700213, re-run with" >&2
  echo "         OIDC_PREFIX set to the 'sub_claim_prefix' of: gh api repos/$GITHUB_REPO/actions/oidc/customization/sub" >&2
  OIDC_PREFIX="repo:$GITHUB_REPO"
fi
LOCATION="${LOCATION:-eastus2}"
SHARED_RG=rg-dkm-health-shared
APP_RG=rg-dkm-health-prod
TAGS="app=dkm-health-app compliance=hipaa-soc2 managed_by=bootstrap"

SUB_ID=$(az account show --query id -o tsv 2>/dev/null) || true
[ -n "$SUB_ID" ] || { echo "Not logged in to Azure. Run 'az login' first." >&2; exit 1; }
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUFFIX=$(echo -n "$SUB_ID" | sha256sum | cut -c1-6)
TFSTATE_SA="sttfdkmhealth${SUFFIX}"
ACR_NAME="acrdkmhealth${SUFFIX}"

cat <<EOF
==> About to create the dkm-health-app foundation:
    Subscription : $SUB_NAME ($SUB_ID)
    Region       : $LOCATION
    GitHub repo  : $GITHUB_REPO (OIDC subject prefix: $OIDC_PREFIX)
    Creates      : $SHARED_RG, $APP_RG, storage $TFSTATE_SA, registry $ACR_NAME,
                   Entra apps dkm-health-github-ci / dkm-health-github-cd (+ role assignments)
EOF
if [ "${YES:-}" != 1 ]; then
  read -rp "Proceed? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo "==> Registering resource providers"
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL \
          Microsoft.OperationalInsights Microsoft.Storage Microsoft.ManagedIdentity Microsoft.Insights; do
  az provider register --namespace "$ns" -o none
done

echo "==> Resource groups"
az group create -n "$SHARED_RG" -l "$LOCATION" --tags $TAGS -o none
az group create -n "$APP_RG" -l "$LOCATION" --tags $TAGS env=prod -o none

echo "==> Terraform state storage (Entra-only, versioned)"
az storage account create -n "$TFSTATE_SA" -g "$SHARED_RG" -l "$LOCATION" \
  --sku Standard_ZRS --kind StorageV2 --min-tls-version TLS1_2 --https-only true \
  --allow-shared-key-access false --allow-blob-public-access false --tags $TAGS -o none
az storage account blob-service-properties update -n "$TFSTATE_SA" -g "$SHARED_RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 -o none
az storage container-rm create --storage-account "$TFSTATE_SA" -g "$SHARED_RG" -n tfstate -o none
TFSTATE_SA_ID=$(az storage account show -n "$TFSTATE_SA" -g "$SHARED_RG" --query id -o tsv)
TFSTATE_SCOPE="$TFSTATE_SA_ID/blobServices/default/containers/tfstate"

echo "==> Container registry (artifact repository)"
az acr create -n "$ACR_NAME" -g "$SHARED_RG" -l "$LOCATION" --sku Basic \
  --admin-enabled false --tags $TAGS -o none
ACR_ID=$(az acr show -n "$ACR_NAME" --query id -o tsv)
SHARED_RG_ID=$(az group show -n "$SHARED_RG" --query id -o tsv)
APP_RG_ID=$(az group show -n "$APP_RG" --query id -o tsv)

# Creates (or reuses) an app registration + service principal; echoes "appId objectId".
ensure_sp() {
  local name=$1 app_id sp_oid
  app_id=$(az ad app list --display-name "$name" --query "[0].appId" -o tsv)
  [ -z "$app_id" ] && app_id=$(az ad app create --display-name "$name" --query appId -o tsv)
  sp_oid=$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)
  [ -z "$sp_oid" ] && sp_oid=$(az ad sp create --id "$app_id" --query id -o tsv)
  echo "$app_id $sp_oid"
}

federate() { # app_id cred_name subject  (creates, or replaces if the subject changed)
  local existing; existing=$(az ad app federated-credential list --id "$1" --query "[?name=='$2'].[id,subject]" -o tsv)
  if [ -n "$existing" ]; then
    [ "${existing#*$'\t'}" = "$3" ] && return
    echo "    replacing $2 (subject changed)"
    az ad app federated-credential delete --id "$1" --federated-credential-id "${existing%%$'\t'*}" -o none
  fi
  # JSON goes via a file (relative path) so Windows argument quoting can't mangle it.
  local f; f=$(mktemp fedcred.XXXXXX)
  CLEANUP+=("$f")
  printf '{"name":"%s","issuer":"https://token.actions.githubusercontent.com","subject":"%s","audiences":["api://AzureADTokenExchange"]}' \
    "$2" "$3" > "$f"
  az ad app federated-credential create --id "$1" -o none --parameters "@$f"; rm -f "$f"
}

grant() { # sp_object_id role scope
  for _ in 1 2 3 4 5; do
    az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
      --role "$2" --scope "$3" -o none 2>/dev/null && return
    sleep 10  # new service principals take a moment to replicate
  done
  echo "FAILED: $2 on $3" >&2; exit 1
}

# Reader can't call listSecrets, but azurerm calls it when refreshing a Container App or a Container
# Apps job during plan, so PR plans fail once those exist. This custom role adds only those two
# read actions (no writes). Re-running the script updates the role if its actions changed.
PLAN_ROLE="dkm-health Container App plan reader"
PLAN_ROLE_ACTIONS='"Microsoft.App/containerApps/listSecrets/action","Microsoft.App/jobs/listSecrets/action"'
ensure_plan_role() {
  local existing f
  existing=$(az role definition list --custom-role-only true --name "$PLAN_ROLE" --query "[0].name" -o tsv)
  f=$(mktemp planrole.XXXXXX)
  CLEANUP+=("$f")
  printf '{%s"Name":"%s","Description":"Lets the read-only CI identity refresh Container Apps and jobs in terraform plan (azurerm calls listSecrets). No write actions.","Actions":[%s],"NotActions":[],"DataActions":[],"NotDataActions":[],"AssignableScopes":["%s"]}'     "${existing:+\"id\":\"$existing\",}" "$PLAN_ROLE" "$PLAN_ROLE_ACTIONS" "$APP_RG_ID" > "$f"
  if [ -n "$existing" ]; then
    az role definition update --role-definition "@$f" -o none
  else
    az role definition create --role-definition "@$f" -o none
  fi
  rm -f "$f"
}

echo "==> CI identity (read-only, pull requests)"
read -r CI_APP CI_SP <<<"$(ensure_sp dkm-health-github-ci)"
federate "$CI_APP" github-pr "${OIDC_PREFIX}:pull_request"
grant "$CI_SP" Reader "$APP_RG_ID"
ensure_plan_role
grant "$CI_SP" "$PLAN_ROLE" "$APP_RG_ID" # grant() retries while the new role replicates
grant "$CI_SP" Reader "$SHARED_RG_ID"
grant "$CI_SP" "Storage Blob Data Reader" "$TFSTATE_SCOPE"

echo "==> CD identity (main branch + production environment only)"
read -r CD_APP CD_SP <<<"$(ensure_sp dkm-health-github-cd)"
federate "$CD_APP" github-main "${OIDC_PREFIX}:ref:refs/heads/main"
federate "$CD_APP" github-production "${OIDC_PREFIX}:environment:production"
grant "$CD_SP" Contributor "$APP_RG_ID"
grant "$CD_SP" "Role Based Access Control Administrator" "$APP_RG_ID"
grant "$CD_SP" Reader "$SHARED_RG_ID"
grant "$CD_SP" AcrPush "$ACR_ID"
grant "$CD_SP" "Role Based Access Control Administrator" "$ACR_ID"  # to give the app AcrPull
grant "$CD_SP" "Storage Blob Data Contributor" "$TFSTATE_SCOPE"

# GitHub repository *variables* (not secrets: none of these values are sensitive).
VARS=(
  "AZURE_TENANT_ID=$TENANT_ID"
  "AZURE_SUBSCRIPTION_ID=$SUB_ID"
  "AZURE_CI_CLIENT_ID=$CI_APP"
  "AZURE_CD_CLIENT_ID=$CD_APP"
  "ACR_NAME=$ACR_NAME"
  "TFSTATE_ACCOUNT=$TFSTATE_SA"
  "DEPLOYMENT_PROFILE=sandbox" # cost-optimised; see infra/profiles.tf
)
echo
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  echo "==> Setting GitHub repository variables on $GITHUB_REPO"
  for kv in "${VARS[@]}"; do
    gh variable set "${kv%%=*}" --repo "$GITHUB_REPO" --body "${kv#*=}" && echo "    set ${kv%%=*}"
  done
  echo "==> Done. Re-run the latest 'cd' workflow on main (or merge any PR) to deploy."
else
  echo "==> Done. GitHub CLI not available/logged in here; run these where it is:"
  for kv in "${VARS[@]}"; do printf 'gh variable set %-22s --repo %s --body "%s"\n' "${kv%%=*}" "$GITHUB_REPO" "${kv#*=}"; done
fi
