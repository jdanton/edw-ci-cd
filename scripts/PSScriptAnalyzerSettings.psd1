# ---------------------------------------------------------------------------
# PSScriptAnalyzer settings for scripts/
#
# Used by .github/workflows/pr-validate.yml. Every exclusion below is a
# deliberate decision with a reason - if you add one, add the reason too, or
# the file degrades into "silence whatever is currently red".
# ---------------------------------------------------------------------------

@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # PSAvoidUsingWriteHost
        #
        # The rule exists because Write-Host writes to the host rather than the
        # pipeline, so its output cannot be captured or redirected - which
        # matters for a FUNCTION whose output someone might want to consume.
        #
        # These are top-level CLI scripts. Their human-facing progress output
        # (coloured "==> Deploying...", the manual-steps block) is deliberately
        # NOT pipeline output: Deploy-DataFactory.ps1 returns nothing, and
        # New-DeploymentConfig.ps1 returns conflict objects that Write-Output
        # progress messages would corrupt.
        #
        # Write-Information is the textbook alternative and is invisible by
        # default ($InformationPreference = 'SilentlyContinue'), which would
        # make every script silent in GitHub Actions unless each one set the
        # preference - strictly worse.
        'PSAvoidUsingWriteHost'

        # PSUseShouldProcessForStateChangingFunctions
        #
        # The scripts that change state already declare
        # [CmdletBinding(SupportsShouldProcess)] and honour -WhatIf. The rule
        # also fires on internal helpers named with state-changing verbs that
        # are only ever called from inside a ShouldProcess block.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        PSAvoidUsingCmdletAliases = @{
            # '?' and '%' are idiomatic in interactive shells and unclear in a
            # script somebody has to debug at 03:00. Allowed nowhere.
            Whitelist = @()
        }
    }
}
