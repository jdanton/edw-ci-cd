output "workspace_id" {
  description = "Log Analytics workspace resource ID. Passed to every module's log_analytics_workspace_id variable, and to modules/alerts."
  value       = azurerm_log_analytics_workspace.this.id
}

output "workspace_name" {
  value       = azurerm_log_analytics_workspace.this.name
  description = "Log Analytics workspace name."
}

output "workspace_customer_id" {
  description = "The workspace GUID, used by the Log Analytics query API and by any agent-based collection you add later."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "action_group_id" {
  description = "Action group all alerts fire into. Reuse it for any alert you add outside modules/alerts."
  value       = azurerm_monitor_action_group.this.id
}
