# ---------------------------------------------------------------------------
# bootstrap/variables.tf
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID that will host the EDW platform. All three environments live in this subscription in the default template; see docs/02-bootstrap.md for the multi-subscription variant."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "project" {
  description = "Short lowercase project token used in every resource name. Keep it <= 8 characters: it is concatenated into storage account names, which are capped at 24 characters."
  type        = string
  default     = "edwtaxi"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,7}$", var.project))
    error_message = "project must be 3-8 chars, lowercase alphanumeric, starting with a letter."
  }
}

variable "location" {
  description = "Azure region for the state storage account. Should match (or be close to) the region the environments deploy into."
  type        = string
  default     = "eastus2"
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository, e.g. \"contoso\"."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name (without the owner), e.g. \"edw-ci-cd\"."
  type        = string
}

# ---------------------------------------------------------------------------
# IMMUTABLE SUBJECT CLAIMS
#
# GitHub is migrating OIDC subjects from name-based to ID-based:
#
#   legacy     repo:jdanton/edw-ci-cd:pull_request
#   immutable  repo:jdanton@7385792/edw-ci-cd@1341714815:pull_request
#
# The numeric IDs are the owner ID and repository ID. This is a genuine security
# improvement, not churn: names can be renamed, transferred, deleted and
# re-registered by someone else, so a name-based federated credential can in
# principle be inherited by a different repository. Numeric IDs cannot be.
#
# A mismatch fails at azure/login with:
#
#   AADSTS700213: No matching federated identity record found for presented
#   assertion subject 'repo:jdanton@7385792/edw-ci-cd@1341714815:pull_request'
#
# Find your IDs with:
#   gh api repos/<owner>/<repo> --jq '{owner_id: .owner.id, repo_id: .id}'
#
# Confirm which form YOUR repository issues with:
#   gh api repos/<owner>/<repo>/actions/oidc/customization/sub
# and read `sub_claim_prefix`. Note that `use_immutable_subject: false` does
# NOT reliably mean legacy subjects are issued - during the rollout the prefix
# field is the accurate signal.
# ---------------------------------------------------------------------------

variable "use_immutable_subject_claim" {
  description = "Build federated credential subjects with the ID-based (immutable) format. Set false only if `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` shows a name-based sub_claim_prefix."
  type        = bool
  default     = true
}

variable "github_owner_id" {
  description = "Numeric GitHub owner (user or org) ID. Required when use_immutable_subject_claim = true. gh api repos/<owner>/<repo> --jq .owner.id"
  type        = number
  default     = null
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID. Required when use_immutable_subject_claim = true. gh api repos/<owner>/<repo> --jq .id"
  type        = number
  default     = null

  # Cross-variable validation is not available in a variable block at the
  # required_version floor of 1.5 - a condition may only reference its own
  # variable. The "IDs are required when immutable" check is a precondition on
  # azuread_application_federated_identity_credential.deploy_environment in
  # main.tf instead.
}

variable "environments" {
  description = <<-EOT
    Map of environment name -> settings. The key becomes:
      * the GitHub Environment name (`environment:dev` in the OIDC subject)
      * the Terraform state blob key (`dev.tfstate`)
      * the `-Stage` argument passed to azure.datafactory.tools / azure.synapse.tools

    `deploy_scope` controls how broadly the environment's deployment identity is
    granted rights:
      * "subscription" - Contributor + RBAC Administrator at subscription scope.
        Simplest, and required if you want Terraform to create the resource
        groups themselves. This is the template default.
      * "resource_group" - the identity is scoped to a pre-created resource
        group whose name you supply in `existing_resource_group_name`. Use this
        in tenants where subscription-level Contributor is not grantable.
  EOT
  type = map(object({
    deploy_scope                 = optional(string, "subscription")
    existing_resource_group_name = optional(string, null)
    # Extra Entra object IDs (users or groups) to add as SQL/Synapse admins.
    additional_admin_object_ids = optional(list(string), [])
    # When true, the environment's deployment SP may only be used from the
    # protected branch. Leave false for dev so feature branches can deploy.
    restrict_to_default_branch = optional(bool, false)
  }))

  default = {
    dev  = { deploy_scope = "subscription", restrict_to_default_branch = false }
    test = { deploy_scope = "subscription", restrict_to_default_branch = true }
    prod = { deploy_scope = "subscription", restrict_to_default_branch = true }
  }

  validation {
    condition     = alltrue([for e in var.environments : contains(["subscription", "resource_group"], e.deploy_scope)])
    error_message = "deploy_scope must be either \"subscription\" or \"resource_group\"."
  }

  validation {
    condition     = alltrue([for e in var.environments : e.deploy_scope == "subscription" || e.existing_resource_group_name != null])
    error_message = "existing_resource_group_name is required when deploy_scope is \"resource_group\"."
  }
}

variable "default_branch" {
  description = "Name of the protected trunk branch. Used to build the `ref:refs/heads/<branch>` OIDC subject."
  type        = string
  default     = "main"
}

variable "human_admin_object_ids" {
  description = "Entra object IDs of the humans who should be members of the SQL and Synapse admin groups in every environment. Usually just you, on day one. Find yours with: az ad signed-in-user show --query id -o tsv"
  type        = list(string)
  default     = []
}

variable "state_storage_replication" {
  description = "Replication for the Terraform state account. GRS is the sane default - losing state is far more painful than the marginal cost."
  type        = string
  default     = "GRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS"], var.state_storage_replication)
    error_message = "Must be one of LRS, ZRS, GRS, GZRS."
  }
}

variable "state_storage_allowed_ips" {
  description = <<-EOT
    Public IPs / CIDRs permitted to reach the Terraform state account.

    Leave EMPTY to keep the account open to any network (default-action Allow).
    That is the template default, and it is defensible: the account has
    shared_access_key_enabled = false, so the only way in is an Entra token held
    by an OIDC-federated principal. There is no key to leak.

    Tighten it once your runners are proven. All Terraform in this template runs
    on your VNet-attached self-hosted runners, so there is exactly one egress IP
    to allow - typically the NAT gateway on the runner subnet:

        az network nat gateway show -g <rg> -n <natgw> --query publicIpAddresses

    or, from a job on the runner itself:

        curl -s https://api.ipify.org

    Setting this flips the account to default-action Deny. See
    docs/05-runner-connectivity.md#outbound-internet.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every bootstrap resource."
  type        = map(string)
  default = {
    workload    = "edw-platform"
    layer       = "bootstrap"
    managed-by  = "terraform"
    cost-center = "REPLACE-ME"
  }
}
