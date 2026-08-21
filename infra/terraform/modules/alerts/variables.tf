# ---------------------------------------------------------------------------
# modules/alerts/variables.tf
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for alert rule names, e.g. \"edwtaxi-dev\"."
  type        = string
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "environment" {
  description = "Drives alert severity: prod failures are Sev 1, non-prod are Sev 3/4."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Workspace the scheduled query rules run against."
  type        = string
}

variable "action_group_id" {
  description = "Action group every rule in this module fires into."
  type        = string
}

# ---------------------------------------------------------------------------
# Targets - null skips the corresponding rules
# ---------------------------------------------------------------------------

variable "data_factory_id" {
  type    = string
  default = null
}

variable "synapse_workspace_id" {
  type    = string
  default = null
}

variable "sql_database_id" {
  type    = string
  default = null
}

# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------

variable "pipeline_sla_minutes" {
  description = "How long a pipeline may run before it counts as overrunning. Derive it from the actual SLA: if the warehouse must be ready by 06:00 and the load starts at 03:00, 150 leaves a 30-minute window to intervene."
  type        = number
  default     = 120
}

variable "serverless_data_processed_gb_threshold" {
  description = "Alert when Synapse serverless processes more than this many GB in an hour. A full NYC Taxi year rebuild scans roughly 40 GB, so 100 catches runaways without crying wolf."
  type        = number
  default     = 100
}

variable "sql_cpu_threshold_percent" {
  type    = number
  default = 80
}

variable "sql_storage_threshold_percent" {
  type    = number
  default = 85
}

variable "tags" {
  type    = map(string)
  default = {}
}
