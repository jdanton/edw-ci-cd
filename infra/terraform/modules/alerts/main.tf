# ---------------------------------------------------------------------------
# modules/alerts/main.tf
#
# The alert set is deliberately short. A platform with forty alerts has zero
# alerts, because nobody reads them. These five each map to a distinct failure
# mode with a distinct response in docs/11-operations-runbook.md:
#
#   1. ADF pipeline failed              -> the load did not happen
#   2. ADF pipeline overrunning         -> the load will miss its SLA
#   3. Serverless bytes processed spike -> someone wrote a cartesian join and
#                                          is spending real money
#   4. Azure SQL CPU sustained high     -> the merge is regressing
#   5. Azure SQL storage near cap       -> the next load will fail hard
#
# Severity convention used here:
#   Sev 1 - wake someone now                (prod data loss / outage)
#   Sev 2 - act before the next business day
#   Sev 3 - triage in hours
#   Sev 4 - informational, non-prod
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. ADF pipeline failures
# ---------------------------------------------------------------------------

resource "azurerm_monitor_metric_alert" "adf_pipeline_failed" {
  count = var.data_factory_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-adf-pipeline-failed"
  resource_group_name = var.resource_group_name
  scopes              = [var.data_factory_id]

  description = "One or more ADF pipeline runs failed. Runbook: docs/11-operations-runbook.md#adf-pipeline-failure"
  severity    = var.environment == "prod" ? 1 : 3
  frequency   = "PT5M"
  window_size = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DataFactory/factories"
    metric_name      = "PipelineFailedRuns"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = var.action_group_id
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 2. Pipeline running past its SLA window
#
# A metric alert cannot express "still running after N minutes", so this is a
# scheduled log query against ADFPipelineRun.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "adf_pipeline_overrunning" {
  count = var.data_factory_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-adf-pipeline-overrunning"
  resource_group_name = var.resource_group_name
  location            = var.location

  description = "A pipeline has been running for more than ${var.pipeline_sla_minutes} minutes. Runbook: docs/11-operations-runbook.md#pipeline-overrun"
  severity    = var.environment == "prod" ? 2 : 4
  enabled     = true

  scopes                  = [var.log_analytics_workspace_id]
  evaluation_frequency    = "PT15M"
  window_duration         = "PT6H"
  auto_mitigation_enabled = true

  criteria {
    # ADFPipelineRun emits a row per state transition. arg_max gives the latest
    # state per run; if that is still InProgress and the start is older than the
    # SLA, the run is overrunning.
    query = <<-KQL
      ADFPipelineRun
      | where TimeGenerated > ago(6h)
      | summarize arg_max(TimeGenerated, Status, Start, PipelineName) by RunId
      | where Status == "InProgress"
      | where Start < ago(${var.pipeline_sla_minutes}m)
      | project TimeGenerated, PipelineName, RunId, Start
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [var.action_group_id]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 3. Synapse serverless spend
#
# Serverless SQL bills per TB scanned. One badly written ad-hoc query over an
# unpartitioned lake can scan terabytes in minutes, and nothing else in Azure
# will tell you until the invoice arrives.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "synapse_data_processed" {
  count = var.synapse_workspace_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-synapse-data-processed"
  resource_group_name = var.resource_group_name
  location            = var.location

  description = "Synapse serverless processed more than ${var.serverless_data_processed_gb_threshold} GB in one hour. Runbook: docs/11-operations-runbook.md#serverless-cost-spike"
  severity    = 3
  enabled     = true

  scopes                  = [var.log_analytics_workspace_id]
  evaluation_frequency    = "PT1H"
  window_duration         = "PT1H"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      SynapseBuiltinSqlPoolRequestsEnded
      | where TimeGenerated > ago(1h)
      | summarize TotalGB = sum(DataProcessedBytes) / pow(1024.0, 3)
      | where TotalGB > ${var.serverless_data_processed_gb_threshold}
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [var.action_group_id]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 4 & 5. Azure SQL health
# ---------------------------------------------------------------------------

resource "azurerm_monitor_metric_alert" "sql_cpu" {
  count = var.sql_database_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-sql-cpu"
  resource_group_name = var.resource_group_name
  scopes              = [var.sql_database_id]

  description = "Azure SQL CPU above ${var.sql_cpu_threshold_percent}% for 30 minutes. Usually the nightly merge regressing after a schema change. Runbook: docs/11-operations-runbook.md#sql-cpu"
  severity    = 3
  frequency   = "PT5M"
  window_size = "PT30M"

  criteria {
    metric_namespace = "Microsoft.Sql/servers/databases"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.sql_cpu_threshold_percent
  }

  action {
    action_group_id = var.action_group_id
  }

  tags = var.tags
}

resource "azurerm_monitor_metric_alert" "sql_storage" {
  count = var.sql_database_id == null ? 0 : 1

  name                = "alert-${var.name_prefix}-sql-storage"
  resource_group_name = var.resource_group_name
  scopes              = [var.sql_database_id]

  description = "Azure SQL allocated storage above ${var.sql_storage_threshold_percent}%. The next load will fail with 'Could not allocate space'. Runbook: docs/11-operations-runbook.md#sql-storage"
  severity    = 2
  frequency   = "PT15M"
  window_size = "PT1H"

  criteria {
    metric_namespace = "Microsoft.Sql/servers/databases"
    metric_name      = "storage_percent"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = var.sql_storage_threshold_percent
  }

  action {
    action_group_id = var.action_group_id
  }

  tags = var.tags
}
