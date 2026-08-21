#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the repository and environment variables that the workflows need,
    from the bootstrap Terraform outputs, using the GitHub CLI.

.DESCRIPTION
    Run this ONCE, after `terraform apply` in bootstrap/.

    Everything it writes is a VARIABLE, not a secret. Under OIDC federation
    there is nothing secret to store: a client ID, a tenant ID and a
    subscription ID are all identifiers, not credentials. The credential is the
    short-lived token GitHub mints per job, which Entra accepts only for the
    exact repository, environment and workflow the federated credential names.

    If you find yourself adding an AZURE_CLIENT_SECRET here, stop and re-read
    bootstrap/main.tf - the whole design exists to avoid it.

    It also CREATES the three GitHub Environments and, for test and prod, sets
    the deployment branch policy to the protected branch. Required reviewers
    cannot be set through this API for every plan tier, so the script prints
    what to configure by hand and where.

.PARAMETER BootstrapDirectory
    Where bootstrap/ terraform state lives.

.PARAMETER Repository
    owner/repo. Defaults to the value baked into the bootstrap outputs.

.EXAMPLE
    ./scripts/Set-GitHubOidcSecrets.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $BootstrapDirectory = (Join-Path $PSScriptRoot '..' 'bootstrap'),
    [string] $Repository,
    [string] $DefaultBranch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    !! $m" -ForegroundColor Yellow }

Resolve-RequiredTool -Name 'gh' `
    -InstallHint 'Install the GitHub CLI: https://cli.github.com/  (brew install gh)' `
    -PostCheck { gh auth status *>$null; $LASTEXITCODE -eq 0 } `
    -FailureMessage 'The GitHub CLI is installed but not authenticated. Run: gh auth login' | Out-Null

Resolve-RequiredTool -Name 'terraform' `
    -InstallHint 'Install Terraform: https://developer.hashicorp.com/terraform/install  (brew install terraform)' | Out-Null

Write-Step 'Reading bootstrap outputs.'

Push-Location $BootstrapDirectory
try {
    $json = terraform output -raw github_configuration_json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed. Has bootstrap/ been applied?' }
    $cfg = $json | ConvertFrom-Json
}
finally {
    Pop-Location
}

if (-not $Repository) { $Repository = $cfg.repository }
Write-Ok "Repository: $Repository"

# ---------------------------------------------------------------------------
# Repository-level variables
# ---------------------------------------------------------------------------

Write-Step 'Setting repository variables.'

foreach ($property in $cfg.repositoryVariables.PSObject.Properties) {
    if ($PSCmdlet.ShouldProcess("$Repository / $($property.Name)", 'Set repository variable')) {
        gh variable set $property.Name --repo $Repository --body $property.Value
        if ($LASTEXITCODE -ne 0) { throw "Failed to set repository variable $($property.Name)." }
        Write-Ok "$($property.Name) = $($property.Value)"
    }
}

# ---------------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------------

foreach ($envProperty in $cfg.environments.PSObject.Properties) {
    $environmentName = $envProperty.Name
    $environment     = $envProperty.Value

    Write-Step "Environment: $environmentName"

    if ($PSCmdlet.ShouldProcess("$Repository / $environmentName", 'Create GitHub Environment')) {
        # gh has no first-class `environment create`, so go through the API.
        # PUT is idempotent - re-running does not disturb existing protection
        # rules, which matters because you will configure reviewers by hand.
        gh api --method PUT "repos/$Repository/environments/$environmentName" --silent 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not create environment '$environmentName'. Environments require a public repository or a paid plan on private repositories. Create it manually: Settings -> Environments."
        }
        else {
            Write-Ok "Environment '$environmentName' exists."
        }
    }

    foreach ($variable in $environment.variables.PSObject.Properties) {
        if ($PSCmdlet.ShouldProcess("$Repository / $environmentName / $($variable.Name)", 'Set environment variable')) {
            gh variable set $variable.Name --repo $Repository --env $environmentName --body $variable.Value
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Failed to set $($variable.Name) on environment $environmentName."
            }
            else {
                Write-Ok "$($variable.Name) = $($variable.Value)"
            }
        }
    }

    # -----------------------------------------------------------------------
    # Branch policy for test and prod.
    #
    # This is what makes the OIDC subject claim meaningful. Without it, a
    # feature branch can run a job with `environment: prod` and Entra will
    # happily issue a token - the subject only says "environment:prod", not
    # which branch asked. The branch restriction is enforced by GitHub, before
    # the token is ever minted.
    # -----------------------------------------------------------------------
    if ($environmentName -in @('test', 'prod')) {
        if ($PSCmdlet.ShouldProcess("$Repository / $environmentName", "Restrict deployments to $DefaultBranch")) {

            $body = @{
                deployment_branch_policy = @{
                    protected_branches     = $false
                    custom_branch_policies = $true
                }
            } | ConvertTo-Json -Depth 5

            $body | gh api --method PUT "repos/$Repository/environments/$environmentName" --input - --silent 2>$null

            gh api --method POST "repos/$Repository/environments/$environmentName/deployment-branch-policies" `
                   -f "name=$DefaultBranch" -f 'type=branch' --silent 2>$null

            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Deployments restricted to '$DefaultBranch'."
            }
            else {
                Write-Warn "Could not set the branch policy (it may already exist). Verify at: Settings -> Environments -> $environmentName."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# What cannot be automated
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '========================================================================' -ForegroundColor Yellow
Write-Host ' MANUAL STEPS REMAINING' -ForegroundColor Yellow
Write-Host '========================================================================' -ForegroundColor Yellow
Write-Host @"

1. REQUIRED REVIEWERS on test and prod
   Settings -> Environments -> prod -> Required reviewers

   This is the control that stops an automated pipeline from changing
   production unsupervised. The API for it is not available on every plan
   tier, so it is set by hand - and it should be reviewed by a human anyway.

2. SELF-HOSTED RUNNER LABELS
   The workflows target [self-hosted, Linux, X64, edw], falling back to that
   list only when the RUNNER_LABELS repository VARIABLE is unset.

   Check what your runners actually report:
     gh api repos/$Repository/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'

   Then either add the label:
     Settings -> Actions -> Runners -> <runner> -> Labels -> add 'edw'

   ...or declare what they already have, which is better if the runner is
   shared with other repositories:
     gh variable set RUNNER_LABELS --repo $Repository --body '["self-hosted","Linux","X64"]'

   A label added through the UI is WIPED if the runner re-registers - a rebuilt
   VM, config.sh --replace, or anything ephemeral/containerised. For those, put
   --labels edw in the registration instead.

   Do NOT switch to ubuntu-latest. The lint and build jobs would pass and every
   deployment job would hang: a GitHub-hosted runner cannot reach any private
   endpoint in this platform, and the failures look like authentication problems
   rather than network ones.

3. NETWORK CONTRIBUTOR ON THE RUNNER VNET
   Terraform creates the VNet peering in BOTH directions - Azure peering is not
   implicit, and one side alone sits in state 'Initiated' carrying no traffic.
   That means the deployment identities need write access on the runner's VNet,
   which lives outside every resource group this platform owns.

   Run this BEFORE the first infrastructure apply. Skip it and the apply fails
   partway through on Microsoft.Network/virtualNetworks/peer/action, having
   already created the EDW VNet and half its private endpoints.

     RUNNER_VNET=<resource id of your runner VNet>
     for e in dev test prod; do
       SP=`$(az ad sp list --display-name "sp-<project>-github-deploy-`$e" --query "[0].id" -o tsv)
       az role assignment create --assignee-object-id "`$SP" \
         --assignee-principal-type ServicePrincipal \
         --role "Network Contributor" --scope "`$RUNNER_VNET"
     done

   Alternative: set peer_runner_vnet = false in each tfvars and create both
   peerings by hand. See docs/05-runner-connectivity.md.

4. BRANCH PROTECTION on $DefaultBranch
   Settings -> Branches -> Add rule
     - Require a pull request before merging
     - Require status checks: pr-validate
     - Do not allow bypassing the above settings

5. VERIFY THE FEDERATION
   Push a branch and open a pull request. The pr-validate workflow runs
   terraform plan using the read-only CI identity. If it authenticates, the
   OIDC federation is correct.

"@ -ForegroundColor Gray

Write-Step 'GitHub configuration complete.'
