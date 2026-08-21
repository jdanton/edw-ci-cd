# ---------------------------------------------------------------------------
# modules/network/versions.tf
#
# A module must declare its own provider requirements, even though it inherits
# the CONFIGURED provider from its caller.
#
# Without this block the module works fine when called from infra/terraform
# (it inherits the root's azurerm 4.x) and FAILS when validated on its own -
# `terraform init` in this directory has no constraint to satisfy, so it
# resolves the newest major and the module is then checked against a provider
# it was never written for.
#
# .github/workflows/pr-validate.yml validates every module standalone for
# exactly this reason: it is the only way to catch a module that has silently
# drifted away from the provider version the root pins.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Azure resources. PINNED TO 4.x: azurerm 5.x renamed arguments used
    # throughout this module, so an unpinned module resolves to 5.x when
    # validated standalone and fails with "Unsupported argument".
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
