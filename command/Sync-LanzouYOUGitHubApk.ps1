[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApkPath,
    [string]$Repo = 'nekobyran/lanzouyou',
    [string]$Tag,
    [string]$AssetName = 'LanzouYOU.apk',
    [switch]$AllowPublic,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LanzouYOUGitHub.Common.ps1')

$script:GhCommand = New-LzyCommandSpec -FilePath (Resolve-LzyToolPath -Name 'gh')

function Assert-GitHubInput {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ReleaseTag,
        [Parameter(Mandatory)][string]$ReleaseAssetName
    )

    $repoPattern = '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9])?$'
    if ($Repository.Length -gt 140 -or $Repository -cnotmatch $repoPattern) {
        throw 'Repo must use the strict owner/repository GitHub format.'
    }
    if ($ReleaseTag.Length -gt 128 -or $ReleaseTag -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9._+-]{0,126}[A-Za-z0-9])?$' -or
        $ReleaseTag.Contains('..')) {
        throw 'Tag contains unsupported characters or traversal syntax.'
    }
    if ($ReleaseAssetName.Length -gt 128 -or $ReleaseAssetName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._ -]*\.apk$' -or
        $ReleaseAssetName.Contains('..') -or $ReleaseAssetName -match '[\\/]' -or
        $ReleaseAssetName -match '[<>:"|?*\x00-\x1f]') {
        throw 'AssetName must be a plain .apk filename without separators or traversal syntax.'
    }
}

function Invoke-GhJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = Invoke-LzyCheckedTool -Command $script:GhCommand -Arguments $Arguments -Failure 'GitHub CLI command failed.'
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) { return $null }
    return $result.StdOut | ConvertFrom-Json -Depth 32
}

function Get-AssetDigest {
    param([Parameter(Mandatory)]$Asset)

    $property = $Asset.PSObject.Properties['digest']
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return $null
    }
    return [string]$property.Value
}

function Get-RemoteAssetSha256 {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][long]$AssetId,
        [Parameter(Mandatory)][string]$Destination
    )

    $downloadPath = [string](Invoke-LzyDownload -Command $script:GhCommand -Arguments @(
        'api', '-H', 'Accept: application/octet-stream', "repos/$Repository/releases/assets/$AssetId"
    ) -Destination $Destination -TimeoutSeconds 300)
    return (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-RemoteAsset {
    param(
        [Parameter(Mandatory)]$Asset,
        [Parameter(Mandatory)][long]$ExpectedBytes,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$DownloadPath,
        [switch]$AlwaysDownload
    )

    if ([long]$Asset.size -ne $ExpectedBytes) {
        throw "Remote asset $($Asset.id) size does not match the local APK."
    }
    $digest = Get-AssetDigest -Asset $Asset
    if ($null -ne $digest -and $digest -cne "sha256:$ExpectedSha256") {
        throw "Remote asset $($Asset.id) digest does not match the local APK."
    }
    if ($AlwaysDownload -or $null -eq $digest) {
        $remoteSha256 = Get-RemoteAssetSha256 -Repository $Repository -AssetId ([long]$Asset.id) -Destination $DownloadPath
        if ($remoteSha256 -cne $ExpectedSha256) {
            throw "Remote asset $($Asset.id) downloaded SHA-256 does not match the local APK."
        }
        return $remoteSha256
    }
    return $ExpectedSha256
}

$apk = Get-Item -LiteralPath $ApkPath -ErrorAction Stop
if ($apk.PSIsContainer -or $apk.Extension -cne '.apk' -or $apk.Length -le 0) {
    throw 'ApkPath must be a non-empty APK file.'
}
if ([string]::IsNullOrWhiteSpace($Tag)) {
    $pubspec = Join-Path $PSScriptRoot '..\project\LanzouYOU\pubspec.yaml'
    $match = [regex]::Match((Get-Content -LiteralPath $pubspec -Raw), '(?m)^version:\s*([^+\s]+)')
    if (-not $match.Success) { throw 'Unable to read the LanzouYOU version.' }
    $Tag = 'v' + $match.Groups[1].Value
}
Assert-GitHubInput -Repository $Repo -ReleaseTag $Tag -ReleaseAssetName $AssetName

$savedEnvironment = @{}
foreach ($name in @('GH_TOKEN', 'GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE')) {
    $savedEnvironment[$name] = Save-LzyEnvironmentValue $name
}
$credential = $null
try {
    $ghOverride = [Environment]::GetEnvironmentVariable('LANZOUYOU_GH_COMMAND', 'Process')
    if ([string]::IsNullOrWhiteSpace($ghOverride) -and [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $gitCommand = New-LzyCommandSpec -FilePath (Resolve-LzyToolPath -Name 'git')
        $credential = Get-LzyGitHubCredential -GitCommand $gitCommand
        Enable-LzyGitHubCredential -Credential $credential
    }

$repoInfo = Invoke-GhJson @('repo', 'view', $Repo, '--json', 'isPrivate,nameWithOwner')
if ($repoInfo.isPrivate -ne $true) { throw 'The target repository must be private.' }
$release = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
$sha256 = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$stable = @($release.assets | Where-Object { $_.name -ceq $AssetName })
if ($stable.Count -gt 1) { throw 'The release contains duplicate stable APK assets.' }
$transientPrefix = "$AssetName."
$transient = @($release.assets | Where-Object {
    ([string]$_.name).StartsWith("$transientPrefix" + 'stage-', [StringComparison]::Ordinal) -or
    ([string]$_.name).StartsWith("$transientPrefix" + 'backup-', [StringComparison]::Ordinal)
})
if ($transient.Count -gt 0) {
    throw 'The release already contains staged or backup APK assets; resolve them before publishing.'
}

$summary = [ordered]@{
    mode = if ($Apply) { 'apply' } else { 'dry-run' }
    repo = $Repo
    tag = $Tag
    asset = $AssetName
    apk = $apk.FullName
    bytes = $apk.Length
    sha256 = $sha256
    previousAssetId = if ($stable.Count -eq 1) { [long]$stable[0].id } else { $null }
}
if (-not $Apply) {
    $summary | ConvertTo-Json -Depth 8
    return
}

$transaction = [guid]::NewGuid().ToString('N')
$stageName = "$AssetName.stage-$transaction"
$backupName = "$AssetName.backup-$transaction"
$localRoot = Join-Path ([IO.Path]::GetTempPath()) "lanzouyou-github-$transaction"
$stagePath = Join-Path $localRoot $stageName
$remoteCheckPath = Join-Path $localRoot 'remote-check.apk'
$oldBackupPath = Join-Path $localRoot $backupName
$oldId = if ($stable.Count -eq 1) { [long]$stable[0].id } else { $null }
$stageId = $null
$stageTracked = $false
$oldDownloaded = $false
New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
Copy-Item -LiteralPath $apk.FullName -Destination $stagePath -Force

try {
    # Track the remote name before invoking upload: gh can create an asset and still return failure.
    $stageTracked = $true
    [void](Invoke-LzyCheckedTool -Command $script:GhCommand -Arguments @('release', 'upload', $Tag, $stagePath, '--repo', $Repo) `
        -TimeoutSeconds 600 -Failure 'Uploading the staged APK failed.')

    $current = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
    $stage = @($current.assets | Where-Object { $_.name -ceq $stageName })
    if ($stage.Count -ne 1) {
        throw 'The staged APK could not be identified uniquely.'
    }
    $stageId = [long]$stage[0].id
    [void](Test-RemoteAsset -Asset $stage[0] -ExpectedBytes $apk.Length -ExpectedSha256 $sha256 `
        -Repository $Repo -DownloadPath $remoteCheckPath)

    if ($null -ne $oldId) {
        # Keep a local byte-for-byte recovery copy until the final readback succeeds.
        [void](Get-RemoteAssetSha256 -Repository $Repo -AssetId $oldId -Destination $oldBackupPath)
        $oldDownloaded = $true
        Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$oldId", '-f', "name=$backupName") | Out-Null
    }
    Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$stageId", '-f', "name=$AssetName") | Out-Null

    $promoted = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
    $promotedStable = @($promoted.assets | Where-Object { $_.name -ceq $AssetName })
    if ($promotedStable.Count -ne 1 -or [long]$promotedStable[0].id -ne $stageId) {
        throw 'The promoted APK could not be identified uniquely.'
    }
    [void](Test-RemoteAsset -Asset $promotedStable[0] -ExpectedBytes $apk.Length -ExpectedSha256 $sha256 `
        -Repository $Repo -DownloadPath $remoteCheckPath -AlwaysDownload)

    if ($null -ne $oldId) {
        Invoke-GhJson @('api', '--method', 'DELETE', "repos/$Repo/releases/assets/$oldId") | Out-Null
    }

    $verified = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
    $newStable = @($verified.assets | Where-Object { $_.name -ceq $AssetName })
    $remainingTransient = @($verified.assets | Where-Object {
        ([string]$_.name).StartsWith("$transientPrefix" + 'stage-', [StringComparison]::Ordinal) -or
        ([string]$_.name).StartsWith("$transientPrefix" + 'backup-', [StringComparison]::Ordinal)
    })
    if ($newStable.Count -ne 1 -or [long]$newStable[0].id -ne $stageId -or $remainingTransient.Count -ne 0) {
        throw 'Final release readback did not contain exactly one stable APK and zero transaction assets.'
    }
    $remoteSha256 = Test-RemoteAsset -Asset $newStable[0] -ExpectedBytes $apk.Length -ExpectedSha256 $sha256 `
        -Repository $Repo -DownloadPath $remoteCheckPath -AlwaysDownload
    $remoteDigest = Get-AssetDigest -Asset $newStable[0]

    $summary.status = 'published'
    $summary.newAssetId = $stageId
    $summary.remoteBytes = [long]$newStable[0].size
    $summary.remoteDigest = $remoteDigest
    $summary.remoteSha256 = $remoteSha256
    $summary.readback = 'one stable asset; zero stage/backup assets'
    $summary | ConvertTo-Json -Depth 8
} catch {
    $failure = $_.Exception.Message
    $rollbackNotes = [Collections.Generic.List[string]]::new()
    try {
        $state = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
        $old = if ($null -ne $oldId) {
            @($state.assets | Where-Object { [long]$_.id -eq $oldId })
        } else { @() }
        $new = @($state.assets | Where-Object {
            ($null -ne $stageId -and [long]$_.id -eq $stageId) -or
            ($stageTracked -and $_.name -ceq $stageName)
        })

        if ($null -eq $oldId) {
            foreach ($candidate in $new) {
                try {
                    Invoke-GhJson @('api', '--method', 'DELETE', "repos/$Repo/releases/assets/$([long]$candidate.id)") | Out-Null
                } catch {
                    $rollbackNotes.Add("could not delete staged asset $($candidate.id)")
                }
            }
        } elseif ($old.Count -eq 1 -and $old[0].name -ceq $AssetName) {
            foreach ($candidate in $new) {
                try {
                    Invoke-GhJson @('api', '--method', 'DELETE', "repos/$Repo/releases/assets/$([long]$candidate.id)") | Out-Null
                } catch {
                    $rollbackNotes.Add("could not delete staged asset $($candidate.id)")
                }
            }
        } elseif ($old.Count -eq 1 -and $old[0].name -ceq $backupName) {
            $newStableCandidate = @($new | Where-Object { $_.name -ceq $AssetName })
            foreach ($candidate in $newStableCandidate) {
                try {
                    Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$([long]$candidate.id)", '-f', "name=$stageName") | Out-Null
                    $candidate.name = $stageName
                } catch {
                    $rollbackNotes.Add("could not demote staged asset $($candidate.id)")
                }
            }
            $restored = $false
            try {
                Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$oldId", '-f', "name=$AssetName") | Out-Null
                $restored = $true
            } catch {
                $rollbackNotes.Add("could not restore previous stable asset $oldId")
            }
            if ($restored) {
                foreach ($candidate in $new) {
                    try {
                        Invoke-GhJson @('api', '--method', 'DELETE', "repos/$Repo/releases/assets/$([long]$candidate.id)") | Out-Null
                    } catch {
                        $rollbackNotes.Add("could not delete staged asset $($candidate.id)")
                    }
                }
            } else {
                $fallback = @($new | Where-Object { $_.name -ceq $stageName } | Select-Object -First 1)
                if ($fallback.Count -eq 1) {
                    try {
                        Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$([long]$fallback[0].id)", '-f', "name=$AssetName") | Out-Null
                    } catch {
                        $rollbackNotes.Add('could not keep the new APK under the stable name')
                    }
                }
            }
        } elseif ($old.Count -eq 0 -and $oldDownloaded -and (Test-Path -LiteralPath $oldBackupPath)) {
            # The old remote asset was already deleted. Keep the verified new stable asset and
            # re-upload the old bytes under the transaction backup name for manual recovery.
            $newStageCandidate = @($new | Where-Object { $_.name -ceq $stageName } | Select-Object -First 1)
            if ($newStageCandidate.Count -eq 1) {
                try {
                    Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$([long]$newStageCandidate[0].id)", '-f', "name=$AssetName") | Out-Null
                } catch {
                    $rollbackNotes.Add('could not keep the new APK under the stable name')
                }
            }
            try {
                [void](Invoke-LzyCheckedTool -Command $script:GhCommand -Arguments @(
                    'release', 'upload', $Tag, $oldBackupPath, '--repo', $Repo
                ) -TimeoutSeconds 600 -Failure 'backup upload failed')
            } catch {
                $rollbackNotes.Add('could not re-upload the previous APK recovery copy')
            }
        } else {
            $rollbackNotes.Add('remote asset state was ambiguous; assets were left intact for recovery')
        }
    } catch {
        $rollbackNotes.Add("could not read or restore release state: $($_.Exception.Message)")
    }
    $rollbackText = if ($rollbackNotes.Count -eq 0) { 'rollback completed' } else { $rollbackNotes -join '; ' }
    throw "APK replacement failed ($rollbackText). $failure"
} finally {
    Remove-Item -LiteralPath $localRoot -Recurse -Force -ErrorAction SilentlyContinue
}
} finally {
    foreach ($name in @('GH_TOKEN', 'GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE')) {
        Restore-LzyEnvironmentValue -Name $name -Saved $savedEnvironment[$name]
    }
    $credential = $null
}
