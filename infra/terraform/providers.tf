# ---------------------------------------------------------------------------
# infra/terraform/providers.tf
#
# ONE root module, THREE environments. The environment is selected entirely by
# the two files you pass on the command line:
#
#   terraform init  -backend-config=envs/dev/backend.hcl
#   terraform plan  -var-file=envs/dev/dev.tfvars
#
# There is no `terraform workspace` here on purpose. Workspaces share a single
# backend key and a single provider configuration, which makes it far too easy
# to apply a dev change to prod. Separate state keys and separate tfvars make
# the blast radius explicit in the command itself.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Partial backend configuration. The rest comes from envs/<env>/backend.hcl.
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Terraform authenticates via the GitHub Actions OIDC token. Locally, `az
  # login` is picked up automatically and these are ignored.
  use_oidc = var.use_oidc

  # Storage account keys are disabled on the lake, so every data-plane
  # operation (filesystems, directories) must use the caller's Entra token.
  storage_use_azuread = true

  features {
    key_vault {
      # Recover a soft-deleted vault instead of failing. Essential when you
      # tear down and rebuild dev repeatedly with the same name.
      recover_soft_deleted_key_vaults = true

      # Never purge on destroy: purge is irreversible and there is no undo.
      purge_soft_delete_on_destroy       = false
      purge_soft_deleted_keys_on_destroy = false
    }

    resource_group {
      prevent_deletion_if_contains_resources = var.environment == "prod"
    }

    log_analytics_workspace {
      permanently_delete_on_destroy = false
    }
  }
}
