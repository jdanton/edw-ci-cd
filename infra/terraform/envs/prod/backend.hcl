# ---------------------------------------------------------------------------
# infra/terraform/envs/prod/backend.hcl
#   terraform init -reconfigure -backend-config=envs/prod/backend.hcl
# ---------------------------------------------------------------------------

resource_group_name  = "rg-edwtaxi-tfstate-eastus"
storage_account_name = "stedwtaxitfstate69gc4"
container_name       = "tfstate"
key                  = "prod.tfstate"
use_azuread_auth     = true
use_oidc             = true
