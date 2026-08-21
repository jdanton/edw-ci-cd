# ---------------------------------------------------------------------------
# infra/terraform/envs/test/backend.hcl
#   terraform init -reconfigure -backend-config=envs/test/backend.hcl
# ---------------------------------------------------------------------------

resource_group_name  = "rg-edwtaxi-tfstate-eastus"
storage_account_name = "stedwtaxitfstate69gc4"
container_name       = "tfstate"
key                  = "test.tfstate"
use_azuread_auth     = true
use_oidc             = true
