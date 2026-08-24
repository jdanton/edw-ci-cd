# ---------------------------------------------------------------------------
# scripts/_Tooling.ps1
#
# Dot-sourced by every script in this folder. Two jobs, both about the gap
# between "the tool is installed" and "this process can see it".
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# On macOS, Homebrew puts its binaries in /opt/homebrew/bin (Apple Silicon) or
# /usr/local/bin (Intel), and exports that directory from ~/.zprofile via
# `eval "$(brew shellenv)"`. That is a ZSH file. PowerShell never reads it.
#
# The consequence is confusing, because it depends on how pwsh was started:
#
#   ./scripts/Deploy-Thing.ps1  from zsh   -> pwsh is a CHILD of zsh, inherits
#                                             the full PATH, everything works
#   pwsh, then ./scripts/Deploy-Thing.ps1  -> if that pwsh was not itself
#                                             started from an interactive zsh,
#                                             gh / az / terraform all vanish
#
# The same class of problem exists elsewhere: `sqlpackage` installs as a dotnet
# global tool into ~/.dotnet/tools, which is on PATH only if a shell profile
# put it there.
#
# On the Linux self-hosted runners none of these paths exist, so
# Add-KnownToolPath is a no-op there and nothing is masked.
# ---------------------------------------------------------------------------

function Add-KnownToolPath {
    <#
    .SYNOPSIS
        Idempotently adds the usual tool locations to PATH for this process.
    .DESCRIPTION
        Only adds directories that actually exist and are not already present.
        Appends rather than prepends, so a deliberately-chosen tool earlier in
        PATH (a pinned terraform, say) still wins.
    #>
    [CmdletBinding()]
    param()

    $candidates = @(
        '/opt/homebrew/bin'               # Homebrew, Apple Silicon
        '/opt/homebrew/sbin'
        '/usr/local/bin'                  # Homebrew, Intel; pwsh
        '/opt/homebrew/opt/dotnet@8/bin'  # dotnet 8 via Homebrew
        "$HOME/.dotnet/tools"             # sqlpackage and other dotnet global tools
        '/usr/local/share/dotnet'
    )

    $separator = [System.IO.Path]::PathSeparator
    $current   = $env:PATH -split $separator

    foreach ($candidate in $candidates) {
        if ((Test-Path $candidate) -and ($current -notcontains $candidate)) {
            $env:PATH = $env:PATH + $separator + $candidate
            Write-Verbose "Added '$candidate' to PATH for this process."
        }
    }
}

function Resolve-RequiredTool {
    <#
    .SYNOPSIS
        Requires a command to be available, with an error that says what is
        actually wrong.
    .DESCRIPTION
        Distinguishes the two cases that a naive `Get-Command` check conflates:

          NOT INSTALLED    -> tell them how to install it
          INSTALLED, but not on PATH for THIS process
                           -> tell them where it is, and why pwsh cannot see it

        The second case is the common one on macOS and produces, from a naive
        check, an error telling you to install software you already have.
    .PARAMETER Name
        Command name, e.g. 'gh'.
    .PARAMETER InstallHint
        What to tell someone who genuinely does not have it.
    .PARAMETER PostCheck
        Optional scriptblock run once the tool is found - for example an
        authentication check. Return $true for OK. A $false result raises
        FailureMessage.
    .PARAMETER FailureMessage
        Message when PostCheck returns $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $InstallHint = '',
        [scriptblock] $PostCheck,
        [string] $FailureMessage = ''
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue

    if (-not $command) {
        # Is it installed but simply invisible to this process?
        $searchDirs = @(
            '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin',
            "$HOME/.dotnet/tools", '/opt/homebrew/opt/dotnet@8/bin'
        )
        $found = $searchDirs |
                 Where-Object { Test-Path $_ } |
                 ForEach-Object { Join-Path $_ $Name } |
                 Where-Object { Test-Path $_ } |
                 Select-Object -First 1

        if ($found) {
            throw @"
'$Name' is installed at $found but is NOT on PATH for this PowerShell process.

This is almost always the Homebrew/zsh split: Homebrew exports its bin
directory from ~/.zprofile, which pwsh does not read.

Pick one:

  1. Run the script FROM ZSH rather than from inside a pwsh session. The
     shebang starts pwsh as a child, which inherits the full PATH:

         ./scripts/$(Split-Path -Leaf $PSCommandPath)

  2. Add the directory for this session:

         `$env:PATH += ':$(Split-Path -Parent $found)'

  3. Fix it permanently by creating a pwsh profile:

         mkdir -p ~/.config/powershell
         '`$env:PATH += ":$(Split-Path -Parent $found)"' | Out-File -Append ~/.config/powershell/Microsoft.PowerShell_profile.ps1
"@
        }

        throw "'$Name' was not found on PATH and is not in any of the usual install locations.$(if ($InstallHint) { "`n`n$InstallHint" })"
    }

    Write-Verbose "$Name -> $($command.Source)"

    if ($PostCheck) {
        $ok = & $PostCheck
        if (-not $ok) {
            throw $(if ($FailureMessage) { $FailureMessage } else { "'$Name' is installed but not usable." })
        }
    }

    return $command.Source
}

# ---------------------------------------------------------------------------
# TRANSIENT SQL FAILURES
#
# Every SQL endpoint in this platform can refuse a connection for reasons that
# resolve themselves in under a minute, and none of them say so clearly:
#
#   Azure SQL, dev and test    GP_S_Gen5 with auto-pause. A paused database
#                              accepts the TCP connection and then takes 30-60s
#                              to resume. The client gives up first, reporting
#                              "Connection Timeout Expired. The timeout period
#                              elapsed during the post-login phase" - which
#                              reads like a firewall or port-range fault.
#
#   Synapse serverless         No always-on compute. The first statement after
#                              an idle period is answered with "The SQL pool is
#                              warming up. Please try again." - an instruction,
#                              not a failure.
#
#   Either, any time           40613 not currently available, 40197 service
#                              error, transport-level errors during a planned
#                              failover.
#
# Retrying these is the documented response. Retrying ANYTHING ELSE is harmful:
# it turns a five-second syntax error into a five-minute one and buries the real
# message under attempts. So the classification is deliberately narrow, and
# checked by error NUMBER where the provider gives one - message text varies by
# driver and locale, numbers do not.
# ---------------------------------------------------------------------------

$script:TransientSqlErrorNumbers = @(
    -2,     # client timeout - covers the paused-database resume
    20,     # instance does not support encryption (transient during failover)
    64,     # connection failed during login
    233,    # named pipe / transport closed
    4060,   # cannot open database (transient during resume)
    10053,  # transport-level error on receive
    10054,  # existing connection forcibly closed
    10060,  # network or instance-specific error
    10928,  # resource limit reached
    10929,  # server too busy
    40197,  # the service has encountered an error processing your request
    40501,  # service is busy
    40613,  # database is not currently available
    49918,  # cannot process request, not enough resources
    49919,  # cannot process create or update request
    49920   # cannot process request, too many operations
)

# Belt and braces for drivers that surface a message but no usable number.
$script:TransientSqlErrorPattern =
    'is warming up|is not currently available|Please retry the connection|' +
    'transport-level error|Connection Timeout Expired|post-login phase|' +
    'semaphore timeout|is paused|resuming'

function Test-TransientSqlError {
    <#
    .SYNOPSIS
        True when an ErrorRecord is a SQL failure worth retrying.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorRecord)

    # Walk the inner exceptions: Invoke-Sqlcmd wraps SqlException, and the
    # number lives on the wrapped one.
    $exception = $ErrorRecord.Exception
    while ($exception) {
        $number = $exception.PSObject.Properties['Number']
        if ($number -and $number.Value -in $script:TransientSqlErrorNumbers) {
            return $true
        }
        $exception = $exception.InnerException
    }

    return ($ErrorRecord.Exception.Message -match $script:TransientSqlErrorPattern)
}

function Invoke-SqlWithRetry {
    <#
    .SYNOPSIS
        Runs a scriptblock, retrying only transient SQL failures.

    .DESCRIPTION
        Takes a scriptblock rather than proxying Invoke-Sqlcmd's parameters, so
        callers keep -InputFile, -Variable, -AbortOnError and everything else
        exactly as they had them, and the return value passes straight through.

        Backs off 15s, 30s, 45s, 60s, 60s... Eight attempts is about five
        minutes - comfortably longer than a serverless resume, and short enough
        that a genuinely unreachable endpoint fails inside a coffee break
        instead of holding a runner for an hour.

    .EXAMPLE
        $rows = Invoke-SqlWithRetry -Activity 'dim.TaxiZone merge' -ScriptBlock {
            Invoke-Sqlcmd -ServerInstance $fqdn -Database $db -AccessToken $t -Query $sql
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $Activity = 'SQL command',
        [int]    $MaxAttempts = 8
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            if (-not (Test-TransientSqlError $_)) { throw }

            if ($attempt -ge $MaxAttempts) {
                Write-Host "    $Activity - still failing after $MaxAttempts attempt(s)." -ForegroundColor Red
                throw
            }

            $delay = [math]::Min(60, 15 * $attempt)
            Write-Host "    $Activity - transient: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "    retrying in ${delay}s (attempt $attempt of $MaxAttempts)" -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
    }
}

# Applied on dot-source. Safe and idempotent: only existing directories are
# added, and only if absent.
Add-KnownToolPath
