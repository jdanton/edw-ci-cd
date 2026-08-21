# ---------------------------------------------------------------------------
# infra/terraform/envs/prod/backend.hcl
#   terraform init -reconfigure -backend-config=envs/prod/backend.hcl
# ---------------------------------------------------------------------------

resource_group_name  = "rg-edwtaxi-tfstate-eastus2"
storage_account_name = "REPLACE-ME-FROM-BOOTSTRAP"
container_name       = "tfstate"
key                  = "prod.tfstate"
use_azuread_auth     = true
use_oidc             = true
