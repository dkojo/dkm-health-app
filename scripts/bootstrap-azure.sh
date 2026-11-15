#!/usr/bin/env bash
# One-time Azure foundation for dkm-health-app. Run in Azure Cloud Shell (Bash):
#   GITHUB_REPO=<owner>/<repo> bash bootstrap-azure.sh
#
# Creates:
#   rg-dkm-health-shared : Terraform state storage + Azure Container Registry (artifact repository)
#   rg-dkm-health-prod   : empty; Terraform fills it
#   Two Entra app registrations that GitHub Actions log in as via OIDC (no secrets):
#     dkm-health-github-ci : read-only, used for PR plans
#     dkm-health-github-cd : deploys; only from main branch / "production" environment
# Safe to re-run.
set -euo pipefail

: "${GITHUB_REPO:?set GITHUB_REPO=<owner>/<repo>}"
LOCATION="${LOCATION:-eastus2}"
SHARED_RG=rg-dkm-health-shared
APP_RG=rg-dkm-health-prod
TAGS="app=dkm-health-app compliance=hipaa-soc2 managed_by=bootstrap"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUFFIX=$(echo -n "$SUB_ID" | sha256sum | cut -c1-6)
TFSTATE_SA="sttfdkmhealth${SUFFIX}"
ACR_NAME="acrdkmhealth${SUFFIX}"

echo "==> Subscription $SUB_ID, region $LOCATION"

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

federate() { # app_id cred_name subject
  az ad app federated-credential list --id "$1" --query "[?name=='$2']" -o tsv | grep -q . && return
  az ad app federated-credential create --id "$1" -o none --parameters "{
    \"name\": \"$2\", \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$3\", \"audiences\": [\"api://AzureADTokenExchange\"]}"
}

grant() { # sp_object_id role scope
  for _ in 1 2 3 4 5; do
    az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
      --role "$2" --scope "$3" -o none 2>/dev/null && return
    sleep 10  # new service principals take a moment to replicate
  done
  echo "FAILED: $2 on $3" >&2; exit 1
}

echo "==> CI identity (read-only, pull requests)"
read -r CI_APP CI_SP <<<"$(ensure_sp dkm-health-github-ci)"
federate "$CI_APP" github-pr "repo:${GITHUB_REPO}:pull_request"
grant "$CI_SP" Reader "$APP_RG_ID"
grant "$CI_SP" Reader "$SHARED_RG_ID"
grant "$CI_SP" "Storage Blob Data Reader" "$TFSTATE_SCOPE"

echo "==> CD identity (main branch + production environment only)"
read -r CD_APP CD_SP <<<"$(ensure_sp dkm-health-github-cd)"
federate "$CD_APP" github-main "repo:${GITHUB_REPO}:ref:refs/heads/main"
federate "$CD_APP" github-production "repo:${GITHUB_REPO}:environment:production"
grant "$CD_SP" Contributor "$APP_RG_ID"
grant "$CD_SP" "Role Based Access Control Administrator" "$APP_RG_ID"
grant "$CD_SP" Reader "$SHARED_RG_ID"
grant "$CD_SP" AcrPush "$ACR_ID"
grant "$CD_SP" "Role Based Access Control Administrator" "$ACR_ID"  # to give the app AcrPull
grant "$CD_SP" "Storage Blob Data Contributor" "$TFSTATE_SCOPE"

cat <<EOF

==> Done. Set these as GitHub repository *variables* (not secrets: none of them are sensitive).
    From a machine with the GitHub CLI, in your repo folder:

gh variable set AZURE_TENANT_ID       --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --body "$SUB_ID"
gh variable set AZURE_CI_CLIENT_ID    --body "$CI_APP"
gh variable set AZURE_CD_CLIENT_ID    --body "$CD_APP"
gh variable set ACR_NAME              --body "$ACR_NAME"
gh variable set TFSTATE_ACCOUNT       --body "$TFSTATE_SA"
EOF
