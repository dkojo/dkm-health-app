#!/usr/bin/env bash
# Start the migration job and wait for it. Called by terraform_data.migrate during `terraform apply`
# (CD runner, already signed in to Azure). Fails the apply, and so the deploy, if migrations fail.
# Env: JOB (job name), RG (resource group).
set -euo pipefail

az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

exe=$(az containerapp job start --name "$JOB" --resource-group "$RG" --query name -o tsv --only-show-errors)
echo "migration job execution: $exe"

for _ in $(seq 1 60); do # up to 10 minutes
  status=$(az containerapp job execution show --name "$JOB" --resource-group "$RG" \
    --job-execution-name "$exe" --query properties.status -o tsv --only-show-errors)
  case "$status" in
    Succeeded) echo "migrations succeeded"; exit 0 ;;
    Failed | Stopped | Degraded)
      echo "::error::migration job $exe ended with status $status"
      echo "Logs: Log Analytics > ContainerAppConsoleLogs_CL | where ContainerJobName_s == '$JOB'"
      exit 1 ;;
  esac
  sleep 10
done
echo "::error::migration job $exe did not finish within 10 minutes"
exit 1
