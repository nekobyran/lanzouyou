Set-StrictMode -Version Latest

function Resolve-LzyToolPath {
    param([Parameter(Mandatory)][ValidateSet('gh', 'git')][string]$Name)

    $overrideName = if ($Name -ceq 'gh') { 'LANZOUYOU_GH_COMMAND' } else { 'LANZOUYOU_GIT_COMMAND' }
    $override = [Environment]::GetEnvironmentVariable($overrideName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $resolvedOverride = [IO.Path]::GetFullPath($override)
        if (-not (Test-Path -LiteralPath $resolvedOverride -PathType Leaf)) {
            throw "$overrideName does not point to a file."
        }
        return $resolvedOverride
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return [IO.Path]::GetFullPath($command.Source)
    }

    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $candidates = if ($Name -ceq 'gh') {
        @(
            (Join-Path $programFiles 'GitHub CLI\gh.exe'),
            (Join-Path $localAppData 'Microsoft\WinGet\Links\gh.exe'),
            (Join-Path $localAppData 'Programs\GitHub CLI\gh.exe')
        )
    } else {
        @(
            (Join-Path $programFiles 'Git\cmd\git.exe'),
            (Join-Path $programFiles 'Git\bin\git.exe')
        )
    }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "Required tool is unavailable: $Name"
}

function New-LzyCommandSpec {
    param([Parameter(Mandatory)][string]$FilePath)

    $fullPath = [IO.Path]::GetFullPath($FilePath)
    if ([IO.Path]::GetExtension($fullPath) -in @('.bat', '.cmd')) {
        $commandInterpreter = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        if (-not (Test-Path -LiteralPath $commandInterpreter -PathType Leaf)) {
            throw 'Windows command interpreter is unavailable.'
        }
        return [pscustomobject]@{
            FilePath = $commandInterpreter
            Prefix = @('/d', '/s', '/c', $fullPath)
        }
    }
    return [pscustomobject]@{ FilePath = $fullPath; Prefix = @() }
}

function Invoke-LzyTool {
    param(
        [Parameter(Mandatory)]$Command,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$StandardInput,
        [int]$TimeoutSeconds = 180
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [string]$Command.FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @($Command.Prefix) + @($Arguments)) {
        [void]$start.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Unable to start external tool.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInput) { $process.StandardInput.Write($StandardInput) }
        $process.StandardInput.Close()
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = if ($completed) { $process.ExitCode } else { 124 }
            StdOut = $stdout
            StdErr = if ($completed) { $stderr } else { $stderr + "`nTimed out after $TimeoutSeconds seconds." }
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-LzyCheckedTool {
    param(
        [Parameter(Mandatory)]$Command,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$StandardInput,
        [int]$TimeoutSeconds = 180,
        [Parameter(Mandatory)][string]$Failure
    )

    $result = Invoke-LzyTool -Command $Command -Arguments $Arguments -StandardInput $StandardInput -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        $detail = ($result.StdErr + "`n" + $result.StdOut).Trim()
        if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + '...' }
        throw "$Failure $detail"
    }
    return $result
}

function Save-LzyEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    return [pscustomobject]@{ Exists = $null -ne $value; Value = $value }
}

function Restore-LzyEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Saved)
    $value = if ($Saved.Exists) { [string]$Saved.Value } else { $null }
    [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
}

function Get-LzyGitHubCredential {
    param([Parameter(Mandatory)]$GitCommand)

    $helpers = Invoke-LzyTool -Command $GitCommand -Arguments @('config', '--show-origin', '--get-all', 'credential.helper')
    if ($helpers.ExitCode -notin @(0, 1) -or $helpers.StdOut -notmatch '(?im)\bmanager(?:-core)?\b') {
        throw 'Git Credential Manager is not configured for GitHub publishing.'
    }
    $result = Invoke-LzyCheckedTool -Command $GitCommand -Arguments @('credential', 'fill') `
        -StandardInput "protocol=https`nhost=github.com`n`n" `
        -Failure 'Git Credential Manager did not return GitHub credentials.'
    $values = @{}
    foreach ($line in $result.StdOut -split "`r?`n") {
        if ($line -match '^([^=]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    if ([string]$values.host -cne 'github.com' -or
        [string]::IsNullOrWhiteSpace([string]$values.username) -or
        [string]::IsNullOrWhiteSpace([string]$values.password)) {
        throw 'Git Credential Manager returned incomplete GitHub credentials.'
    }
    return [pscustomobject]@{
        Username = [string]$values.username
        Token = [string]$values.password
    }
}

function Enable-LzyGitHubCredential {
    param([Parameter(Mandatory)]$Credential)
    [Environment]::SetEnvironmentVariable('GH_TOKEN', [string]$Credential.Token, 'Process')
    [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Process')
    [Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', 'Never', 'Process')
}

function Invoke-LzyDownload {
    param(
        [Parameter(Mandatory)]$Command,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$Destination,
        [int]$TimeoutSeconds = 180
    )

    $destinationFull = [IO.Path]::GetFullPath($Destination)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationFull) | Out-Null
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [string]$Command.FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @($Command.Prefix) + @($Arguments)) {
        [void]$start.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $output = $null
    try {
        if (-not $process.Start()) { throw 'Unable to start download tool.' }
        $output = [IO.File]::Open($destinationFull, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($output)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit()
        }
        [void]$copyTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if (-not $completed -or $process.ExitCode -ne 0) {
            $code = if ($completed) { $process.ExitCode } else { 124 }
            throw "Download tool failed with exit code $code. $($stderr.Trim())"
        }
    } catch {
        Remove-Item -LiteralPath $destinationFull -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($null -ne $output) { $output.Dispose() }
        $process.Dispose()
    }
    $file = Get-Item -LiteralPath $destinationFull -ErrorAction Stop
    if ($file.Length -le 0) { throw 'Downloaded file is empty.' }
    return $destinationFull
}
