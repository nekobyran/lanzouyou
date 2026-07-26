[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApkPath,
    [string]$Repo = 'nekobyran/lanzouyou',
    [string]$Tag,
    [string]$AssetName = 'LanzouYOU.apk',
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GhJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $text = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($text -join "`n") }
    return ($text -join "`n") | ConvertFrom-Json -Depth 32
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
$repoInfo = Invoke-GhJson @('repo', 'view', $Repo, '--json', 'isPrivate,nameWithOwner')
if ($repoInfo.isPrivate -ne $true) { throw 'The target repository must be private.' }
$release = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
$sha256 = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$stable = @($release.assets | Where-Object { $_.name -ceq $AssetName })
if ($stable.Count -gt 1) { throw 'The release contains duplicate stable APK assets.' }

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
$stagePath = Join-Path ([IO.Path]::GetTempPath()) $stageName
Copy-Item -LiteralPath $apk.FullName -Destination $stagePath -Force
$oldId = if ($stable.Count -eq 1) { [long]$stable[0].id } else { $null }
$stageId = $null
try {
    & gh release upload $Tag $stagePath --repo $Repo
    if ($LASTEXITCODE -ne 0) { throw 'Uploading the staged APK failed.' }
    $current = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
    $stage = @($current.assets | Where-Object { $_.name -ceq $stageName })
    if ($stage.Count -ne 1 -or [long]$stage[0].size -ne $apk.Length) {
        throw 'The staged APK could not be verified by name and size.'
    }
    $stageId = [long]$stage[0].id
    if ($stage[0].digest -and [string]$stage[0].digest -cne "sha256:$sha256") {
        throw 'The staged APK digest does not match the local file.'
    }
    if ($null -ne $oldId) {
        Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$oldId", '-f', "name=$backupName") | Out-Null
    }
    Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$stageId", '-f', "name=$AssetName") | Out-Null
    $verified = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
    $newStable = @($verified.assets | Where-Object { $_.name -ceq $AssetName })
    if ($newStable.Count -ne 1 -or [long]$newStable[0].id -ne $stageId -or
        [long]$newStable[0].size -ne $apk.Length -or
        ($newStable[0].digest -and [string]$newStable[0].digest -cne "sha256:$sha256")) {
        throw 'The new stable APK failed remote verification.'
    }
    if ($null -ne $oldId) {
        Invoke-GhJson @('api', '--method', 'DELETE', "repos/$Repo/releases/assets/$oldId") | Out-Null
    }
    $summary.status = 'published'
    $summary.newAssetId = $stageId
    $summary | ConvertTo-Json -Depth 8
} catch {
    if ($null -ne $oldId) {
        try {
            $state = Invoke-GhJson @('api', "repos/$Repo/releases/tags/$Tag")
            $old = @($state.assets | Where-Object { [long]$_.id -eq $oldId })
            $new = @($state.assets | Where-Object { $null -ne $stageId -and [long]$_.id -eq $stageId })
            if ($new.Count -eq 1 -and $new[0].name -ceq $AssetName) {
                Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$stageId", '-f', "name=$stageName") | Out-Null
            }
            if ($old.Count -eq 1 -and $old[0].name -ceq $backupName) {
                Invoke-GhJson @('api', '--method', 'PATCH', "repos/$Repo/releases/assets/$oldId", '-f', "name=$AssetName") | Out-Null
            }
        } catch { }
    }
    throw "APK replacement failed; inspect the release assets before retrying. $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $stagePath -Force -ErrorAction SilentlyContinue
}
