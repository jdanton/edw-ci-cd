# ---------------------------------------------------------------------------
# infra/terraform/envs/dev/backend.hcl
#
# Partial backend configuration. Use with:
#   terraform init -reconfigure -backend-config=envs/dev/backend.hcl
#
# Values come from `cd bootstrap && terraform output backend_config`.
#
# use_azuread_auth = true is REQUIRED: the state account has
# shared_access_key_enabled = false, so there is no account key to fall back on.
# use_oidc = true lets the GitHub Actions federated token authenticate; it is
# ignored (harmlessly) when you run locally with `az login`.
# ---------------------------------------------------------------------------

resource_group_name  = "rg-edwtaxi-tfstate-eastus2"
storage_account_name = "REPLACE-ME-FROM-BOOTSTRAP"
container_name       = "tfstate"
key                  = "dev.tfstate"
use_azuread_auth     = true
use_oidc             = true
