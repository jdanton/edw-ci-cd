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

# Applied on dot-source. Safe and idempotent: only existing directories are
# added, and only if absent.
Add-KnownToolPath
