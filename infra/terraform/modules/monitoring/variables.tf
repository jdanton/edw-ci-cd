# ---------------------------------------------------------------------------
# modules/monitoring/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Log Analytics workspace name."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the action group name, e.g. \"edwtaxi-dev\"."
  type        = string
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "retention_in_days" {
  description = "Log Analytics retention. 30 is the free floor; 90 is enough to investigate a quarter-end anomaly."
  type        = number
  default     = 30

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "Retention must be between 30 and 730 days."
  }
}

variable "daily_quota_gb" {
  description = "Hard cap on daily ingestion in GB. -1 for unlimited. A cap is strongly recommended in dev, where a mis-scoped diagnostic setting is most likely."
  type        = number
  default     = 5
}

variable "alert_email_receivers" {
  description = "Map of short receiver name -> email address. Keep the name short; Azure truncates it in SMS and ITSM payloads."
  type        = map(string)
  default     = {}
}

variable "alert_webhook_receivers" {
  description = "Map of short receiver name -> webhook URI. Use for Teams/Slack connectors or PagerDuty. Sends the common alert schema."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
