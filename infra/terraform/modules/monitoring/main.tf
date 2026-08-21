# ---------------------------------------------------------------------------
# modules/monitoring/main.tf
#
# Log Analytics workspace + the action group everything alerts into + the saved
# queries an on-call engineer needs at 03:00.
#
# The ALERT RULES themselves live in modules/alerts, deliberately. They need
# resource IDs for ADF, Synapse and Azure SQL - all of which need this
# workspace's ID for their diagnostic settings. Keeping them in one module
# would be a dependency cycle at module granularity.
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku               = "PerGB2018"
  retention_in_days = var.retention_in_days

  # Cap daily ingest so a mis-scoped diagnostic setting cannot produce a
  # five-figure bill overnight. -1 disables the cap.
  daily_quota_gb = var.daily_quota_gb

  internet_ingestion_enabled = true
  internet_query_enabled     = true

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Action group - who gets woken up
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-${var.name_prefix}"
  resource_group_name = var.resource_group_name

  # Max 12 characters, and it is what shows up in SMS and push notifications.
  short_name = substr(replace(var.name_prefix, "-", ""), 0, 12)

  dynamic "email_receiver" {
    for_each = var.alert_email_receivers
    content {
      name                    = email_receiver.key
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  dynamic "webhook_receiver" {
    for_each = var.alert_webhook_receivers
    content {
      name                    = webhook_receiver.key
      service_uri             = webhook_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Saved queries - the starting point for anyone opening Log Analytics cold.
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_saved_search" "pipeline_history" {
  name                       = "EDW-PipelineRunHistory"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  category                   = "EDW"
  display_name               = "Pipeline run history (last 7 days)"

  query = <<-KQL
    ADFPipelineRun
    | where TimeGenerated > ago(7d)
    | summarize arg_max(TimeGenerated, Status, Start, End) by RunId, PipelineName
    | where Status in ("Succeeded", "Failed", "Cancelled")
    | extend DurationMinutes = datetime_diff('minute', End, Start)
    | project Start, PipelineName, Status, DurationMinutes, RunId
    | order by Start desc
  KQL
}

resource "azurerm_log_analytics_saved_search" "activity_failures" {
  name                       = "EDW-ActivityFailures"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  category                   = "EDW"
  display_name               = "Failed activities with error detail"

  # ADFActivityRun.Error is JSON. errorCode is the field to search the Microsoft
  # docs for; message is the field to paste into a ticket.
  query = <<-KQL
    ADFActivityRun
    | where TimeGenerated > ago(7d)
    | where Status == "Failed"
    | project TimeGenerated, PipelineName, ActivityName, ActivityType,
              ErrorCode    = tostring(parse_json(Error).errorCode),
              ErrorMessage = tostring(parse_json(Error).message),
              PipelineRunId
    | order by TimeGenerated desc
  KQL
}

resource "azurerm_log_analytics_saved_search" "serverless_cost" {
  name                       = "EDW-ServerlessCostByPrincipal"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  category                   = "EDW"
  display_name               = "Synapse serverless bytes processed, by principal"

  # Serverless is billed per TB scanned (about USD 5/TB at list price in most
  # regions - check your own rate card). This turns that into a per-user bill.
  query = <<-KQL
    SynapseBuiltinSqlPoolRequestsEnded
    | where TimeGenerated > ago(30d)
    | summarize
        Requests     = count(),
        TotalGB      = round(sum(DataProcessedBytes) / 1024.0 / 1024.0 / 1024.0, 2),
        EstimatedUSD = round(sum(DataProcessedBytes) / pow(1024.0, 4) * 5.0, 2)
      by LoginName
    | order by TotalGB desc
  KQL
}

resource "azurerm_log_analytics_saved_search" "slowest_activities" {
  name                       = "EDW-SlowestActivities"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  category                   = "EDW"
  display_name               = "Slowest activities (p95 duration, last 14 days)"

  query = <<-KQL
    ADFActivityRun
    | where TimeGenerated > ago(14d)
    | where Status == "Succeeded"
    | extend DurationSeconds = todouble(parse_json(Output).durationInMs) / 1000.0
    | summarize
        Runs   = count(),
        MedianSeconds = percentile(DurationSeconds, 50),
        P95Seconds    = percentile(DurationSeconds, 95)
      by PipelineName, ActivityName
    | order by P95Seconds desc
  KQL
}
