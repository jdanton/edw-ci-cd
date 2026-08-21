# ---------------------------------------------------------------------------
# bootstrap/main.tf
#
# Creates, once per tenant/subscription:
#   1. Terraform remote state (storage account + container, Entra-auth only)
#   2. One Entra application per environment for GitHub Actions *deployments*
#   3. One Entra application for read-only CI (PR `terraform plan`, drift checks)
#   4. Entra groups used as Azure SQL and Synapse administrators
#   5. The RBAC that ties all of the above together
#
# Read docs/02-bootstrap.md before running this.
# ---------------------------------------------------------------------------

locals {
  # Deterministic-ish suffix. Kept in state; if you lose state and re-create,
  # the suffix changes and you must update the backend config in every env.
  suffix = random_string.suffix.result

  state_resource_group_name = "rg-${var.project}-tfstate-${var.location}"
  state_storage_account_name = substr(
    lower(replace("st${var.project}tfstate${local.suffix}", "-", "")),
    0, 24
  )
  state_container_name = "tfstate"

  # Scope each environment's deployment identity.
  env_scopes = {
    for name, cfg in var.environments : name => (
      cfg.deploy_scope == "subscription"
      ? "/subscriptions/${var.subscription_id}"
      : "/subscriptions/${var.subscription_id}/resourceGroups/${cfg.existing_resource_group_name}"
    )
  }

  # OIDC subject claims. GitHub mints these; Entra matches them exactly.
  #
  #   repo:<owner>/<repo>:environment:<env>   <- job with `environment: <env>`
  #   repo:<owner>/<repo>:ref:refs/heads/main <- job on a branch, no environment
  #   repo:<owner>/<repo>:pull_request        <- job triggered by pull_request
  #
  # Deployment identities use the `environment:` subject so that GitHub
  # Environment protection rules (required reviewers, wait timers, branch
  # restrictions) are actually load-bearing rather than decorative.
  #
  # The slug itself is either name-based (legacy) or ID-based (immutable) - see
  # the long comment on var.use_immutable_subject_claim. Every subject below is
  # built from this local, so switching forms is a one-line change here.
  repo_slug = var.use_immutable_subject_claim ? format(
    "%s@%d/%s@%d",
    var.github_owner, var.github_owner_id,
    var.github_repository, var.github_repository_id,
  ) : "${var.github_owner}/${var.github_repository}"

  tags = merge(var.tags, {
    "terraform-module" = "bootstrap"
  })
}

resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# ---------------------------------------------------------------------------
# 1. Terraform remote state
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "tfstate" {
  name     = local.state_resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                = local.state_storage_account_name
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_tier             = "Standard"
  account_replication_type = var.state_storage_replication
  account_kind             = "StorageV2"

  # State is accessed with Entra tokens only. This removes the "someone
  # exfiltrated the account key" failure mode entirely, and is why the backend
  # blocks in infra/terraform/envs/*/backend.tf all set use_azuread_auth = true.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true

  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  infrastructure_encryption_enabled = true

  blob_properties {
    # Versioning is the single most valuable setting here: it turns a
    # catastrophic `terraform state rm` into a two-minute restore.
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  network_rules {
    default_action = length(var.state_storage_allowed_ips) > 0 ? "Deny" : "Allow"
    bypass         = ["AzureServices"]
    ip_rules       = var.state_storage_allowed_ips
  }

  tags = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# The operator running bootstrap needs DATA-PLANE access to create the
# container below.
#
# This is the "Contributor does not grant blob access" trap, hitting the very
# first thing this repository does. Being subscription OWNER is not enough:
# Owner confers management-plane rights, and blobs are a separate permission
# surface. Combined with shared_access_key_enabled = false - so there is no key
# to fall back on - creating the container fails with
# AuthorizationPermissionMismatch unless this assignment exists.
#
# Same trap, same fix, three more times later:
#   infra/terraform/rbac.tf     deployer_lake_contributor
#   infra/terraform/secrets.tf  deployer_keyvault_secrets_officer
#   docs/12-troubleshooting.md#storage-403
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "operator_state_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_client_config.current.object_id

  description = "The human (or SP) running bootstrap - required to create the state container and, later, to run terraform against this backend from a workstation."
}

# Entra role assignments take up to a couple of minutes to reach the storage
# data plane. Without this pause the container creation below races the grant
# and fails on a first apply roughly half the time.
resource "time_sleep" "wait_for_state_blob_rbac" {
  depends_on      = [azurerm_role_assignment.operator_state_blob]
  create_duration = "60s"
}

resource "azurerm_storage_container" "tfstate" {
  name                  = local.state_container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"

  depends_on = [time_sleep.wait_for_state_blob_rbac]
}

# ---------------------------------------------------------------------------
# 2. Deployment identities - one Entra app per environment
# ---------------------------------------------------------------------------

data "azuread_client_config" "current" {}

resource "azuread_application" "deploy" {
  for_each = var.environments

  display_name = "sp-${var.project}-github-deploy-${each.key}"
  owners       = [data.azuread_client_config.current.object_id]

  description = "GitHub Actions deployment identity for the ${each.key} environment of ${local.repo_slug}. Managed by bootstrap/ Terraform. Credential-free: authenticates via OIDC federation only."

  # No password / certificate is ever created for these apps. If you find one,
  # someone added it by hand and you should delete it.
  feature_tags {
    enterprise = true
  }
}

resource "azuread_service_principal" "deploy" {
  for_each = var.environments

  client_id                    = azuread_application.deploy[each.key].client_id
  app_role_assignment_required = false
  owners                       = [data.azuread_client_config.current.object_id]

  description = "Deployment identity for ${each.key}."
  tags        = ["edw-platform", "github-actions", each.key]
}

# Subject: repo:<owner>/<repo>:environment:<env>
resource "azuread_application_federated_identity_credential" "deploy_environment" {
  for_each = var.environments

  application_id = azuread_application.deploy[each.key].id
  display_name   = "github-environment-${each.key}"
  description    = "GitHub Actions jobs running against the '${each.key}' GitHub Environment."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.repo_slug}:environment:${each.key}"

  # Catches the immutable-subject misconfiguration HERE, with a message that
  # names the fix - rather than letting format() interpolate a null into every
  # subject and surfacing hours later as AADSTS700213 in a workflow run.
  lifecycle {
    precondition {
      condition     = !var.use_immutable_subject_claim || (var.github_owner_id != null && var.github_repository_id != null)
      error_message = "use_immutable_subject_claim = true requires github_owner_id and github_repository_id. Get them with: gh api repos/${var.github_owner}/${var.github_repository} --jq '{owner_id: .owner.id, repo_id: .id}'"
    }
  }
}

# Some maintenance workflows (drift detection, scheduled data quality runs) run
# on a schedule against the default branch without an `environment:` block.
# Only granted where the environment is not branch-restricted, plus prod, where
# we deliberately want scheduled drift detection.
resource "azuread_application_federated_identity_credential" "deploy_branch" {
  for_each = { for k, v in var.environments : k => v if v.restrict_to_default_branch }

  application_id = azuread_application.deploy[each.key].id
  display_name   = "github-branch-${var.default_branch}"
  description    = "Scheduled/maintenance workflows on refs/heads/${var.default_branch}."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.repo_slug}:ref:refs/heads/${var.default_branch}"
}

# ---------------------------------------------------------------------------
# 3. Read-only CI identity - used by pull_request `terraform plan`
#
# A PR from a fork or from an untrusted branch must never hold Contributor.
# This identity can read everything and write only Terraform state (plan needs
# to take the state lock), and nothing else.
# ---------------------------------------------------------------------------

resource "azuread_application" "ci" {
  display_name = "sp-${var.project}-github-ci"
  owners       = [data.azuread_client_config.current.object_id]
  description  = "Read-only GitHub Actions identity for ${local.repo_slug}: pull-request terraform plan, drift detection, cost estimation. Holds Reader + state-blob write only."

  feature_tags {
    enterprise = true
  }
}

resource "azuread_service_principal" "ci" {
  client_id                    = azuread_application.ci.client_id
  app_role_assignment_required = false
  owners                       = [data.azuread_client_config.current.object_id]
  description                  = "Read-only CI identity."
  tags                         = ["edw-platform", "github-actions", "ci"]
}

resource "azuread_application_federated_identity_credential" "ci_pull_request" {
  application_id = azuread_application.ci.id
  display_name   = "github-pull-request"
  description    = "Any pull_request-triggered workflow run in ${local.repo_slug}."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.repo_slug}:pull_request"
}

resource "azuread_application_federated_identity_credential" "ci_branch" {
  application_id = azuread_application.ci.id
  display_name   = "github-branch-${var.default_branch}"
  description    = "Push-triggered validation on refs/heads/${var.default_branch}."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.repo_slug}:ref:refs/heads/${var.default_branch}"
}

# Entra takes a few seconds to replicate a new service principal. Without this,
# the first apply frequently fails with
# "PrincipalNotFound: Principal <guid> does not exist in the directory".
resource "time_sleep" "wait_for_sp_replication" {
  depends_on = [
    azuread_service_principal.deploy,
    azuread_service_principal.ci,
  ]
  create_duration = "45s"
}

# ---------------------------------------------------------------------------
# 4. Entra groups used as data-plane administrators
#
# Azure SQL and Synapse take a SINGLE Entra administrator. Pointing that at a
# group rather than a person is what makes Entra-only authentication survive
# staff turnover - and it is what lets the deployment SP run sqlpackage and
# serverless DDL without a SQL login.
# ---------------------------------------------------------------------------

resource "azuread_group" "sql_admins" {
  for_each = var.environments

  display_name     = "sg-${var.project}-sqladmin-${each.key}"
  description      = "Azure SQL Entra administrator for the ${each.key} EDW environment. Membership grants full control of the database - review quarterly."
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]

  members = distinct(concat(
    var.human_admin_object_ids,
    each.value.additional_admin_object_ids,
    [azuread_service_principal.deploy[each.key].object_id],
  ))

  lifecycle {
    # Membership is also managed by your IGA/PIM tooling in a real tenant.
    # Remove this ignore_changes if Terraform is the source of truth.
    ignore_changes = []
  }
}

resource "azuread_group" "synapse_admins" {
  for_each = var.environments

  display_name     = "sg-${var.project}-synapseadmin-${each.key}"
  description      = "Synapse workspace Entra administrator for the ${each.key} EDW environment. Grants Synapse Administrator + serverless SQL sysadmin."
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]

  members = distinct(concat(
    var.human_admin_object_ids,
    each.value.additional_admin_object_ids,
    [azuread_service_principal.deploy[each.key].object_id],
  ))
}

# ---------------------------------------------------------------------------
# 5. Azure RBAC
# ---------------------------------------------------------------------------

# Deployment identity: full control of the environment's scope.
resource "azurerm_role_assignment" "deploy_contributor" {
  for_each = var.environments

  scope                            = local.env_scopes[each.key]
  role_definition_name             = "Contributor"
  principal_id                     = azuread_service_principal.deploy[each.key].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "EDW ${each.key} deployment identity."

  depends_on = [time_sleep.wait_for_sp_replication]
}

# Terraform assigns data-plane roles (Storage Blob Data Contributor to the ADF
# and Synapse managed identities, for example). Contributor alone cannot create
# role assignments, so the deployment identity also needs RBAC Administrator.
#
# This is a real privilege-escalation path: an identity that can assign roles
# can assign itself Owner. The `condition` below constrains it to the specific
# role definitions this template actually assigns, which closes that path.
resource "azurerm_role_assignment" "deploy_rbac_admin" {
  for_each = var.environments

  scope                            = local.env_scopes[each.key]
  role_definition_name             = "Role Based Access Control Administrator"
  principal_id                     = azuread_service_principal.deploy[each.key].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "EDW ${each.key} deployment identity - constrained to data-plane roles only."

  # ABAC condition: may only assign/remove the listed role definitions.
  #   ba92f5b4-2d11-453d-a403-e96b0029c9fe  Storage Blob Data Contributor
  #   2a2b9908-6ea1-4ae2-8e65-a410df84e7d1  Storage Blob Data Reader
  #   4633458b-17de-408a-b874-0445c86b69e6  Key Vault Secrets User
  #   b24988ac-6180-42a0-ab88-20f7382dd24c  Contributor (for MI on child scopes)
  #   acdd72a7-3385-48ef-bd42-f606fba81ae7  Reader
  condition_version = "2.0"
  condition         = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals{ba92f5b4-2d11-453d-a403-e96b0029c9fe, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 4633458b-17de-408a-b874-0445c86b69e6, b24988ac-6180-42a0-ab88-20f7382dd24c, acdd72a7-3385-48ef-bd42-f606fba81ae7}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals{ba92f5b4-2d11-453d-a403-e96b0029c9fe, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 4633458b-17de-408a-b874-0445c86b69e6, b24988ac-6180-42a0-ab88-20f7382dd24c, acdd72a7-3385-48ef-bd42-f606fba81ae7}
     )
    )
  EOT

  depends_on = [time_sleep.wait_for_sp_replication]
}

# Deployment identity: read/write Terraform state.
resource "azurerm_role_assignment" "deploy_state_blob" {
  for_each = var.environments

  scope                            = azurerm_storage_container.tfstate.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azuread_service_principal.deploy[each.key].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "Terraform state read/write for ${each.key}."

  depends_on = [time_sleep.wait_for_sp_replication]
}

# CI identity: read the whole subscription so `terraform plan` can refresh.
resource "azurerm_role_assignment" "ci_reader" {
  scope                            = "/subscriptions/${var.subscription_id}"
  role_definition_name             = "Reader"
  principal_id                     = azuread_service_principal.ci.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "EDW read-only CI identity."

  depends_on = [time_sleep.wait_for_sp_replication]
}

# `terraform plan` writes a lock blob, so read-only is not sufficient here.
resource "azurerm_role_assignment" "ci_state_blob" {
  scope                            = azurerm_storage_container.tfstate.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azuread_service_principal.ci.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "Terraform state lock for plan-only runs."

  depends_on = [time_sleep.wait_for_sp_replication]
}

# Key Vault secret read for the CI identity is deliberately NOT granted.
# Plan-time secret reads are a data-exfiltration vector on fork PRs.
