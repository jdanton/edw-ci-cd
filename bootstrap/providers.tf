# ---------------------------------------------------------------------------
# bootstrap/providers.tf
#
# The bootstrap layer is the ONE piece of this repository that is applied by a
# human, from a workstation, using local state. Everything it creates is what
# makes the *unattended* layers possible:
#
#   * the Azure Storage account that holds Terraform state for dev/test/prod
#   * the Entra ID application registrations that GitHub Actions federates into
#   * the Entra ID groups used as Azure SQL / Synapse administrators
#
# It is deliberately NOT wired into CI. A pipeline that can mint its own
# credentials is a pipeline that can escalate its own privileges.
#
# Local state is committed nowhere (see .gitignore). Back it up, or - better -
# re-run `terraform import` from the documented resource IDs if you lose it.
# See docs/02-bootstrap.md for the full runbook.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Intentionally local. See the header comment.
  # backend "local" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # REQUIRED. The state account sets shared_access_key_enabled = false, so
  # there is no account key for the provider to fall back on. Without this,
  # creating azurerm_storage_container fails with
  # "KeyBasedAuthenticationNotPermitted" - the provider tries to list keys
  # before it tries a token.
  storage_use_azuread = true

  features {
    resource_group {
      # Bootstrap resources are long-lived; refuse to delete a state RG that
      # still contains anything we did not expect.
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}
