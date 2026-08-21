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
    That is the template default because GitHub-hosted runners have no stable
    egress IP, and the state account is protected by Entra RBAC + OIDC anyway.

    If you run *all* Terraform from the self-hosted runners created in
    infra/terraform/modules/runner (which sit behind a static NAT Gateway IP),
    set this to that IP and the account flips to default-action Deny. That is
    the recommended production posture - see docs/05-self-hosted-runners.md.
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
