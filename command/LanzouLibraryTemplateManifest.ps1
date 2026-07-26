Set-StrictMode -Version Latest

$script:LanzouTemplateManifestSchemaVersion = 2
$script:LanzouTemplateRecipeSchemaVersion = 1
$script:LanzouTemplateCoreAbiVersion = 1
$script:LanzouTemplatePurpose = 'maintainer-precompiled-shell-templates'
$script:LanzouTemplateManifestName = 'templates-manifest.json'
$script:LanzouTemplateCoreExports = @(
    'lanzouyou_dispatch',
    'lanzouyou_free'
)

function Assert-LanzouExactObject {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Properties
    )

    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$Label must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties.Name)
    foreach ($name in $Properties) {
        if ($name -notin $actual) {
            throw "$Label is missing a required field."
        }
    }
    foreach ($name in $actual) {
        if ($name -notin $Properties) {
            throw "$Label contains an unsupported field."
        }
    }
}

function Get-LanzouTemplateFileName {
    param([Parameter(Mandatory)][string]$Target)

    switch -CaseSensitive ($Target) {
        'android' { return 'lanzou_library_shell_android.apk' }
        'windows' { return 'lanzou_library_shell_windows.zip' }
        default { throw 'Template target is unsupported.' }
    }
}

function Write-LanzouUtf8JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [ValidateRange(2, 64)][int]$Depth = 8
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function New-LanzouTemplateManifest {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][object[]]$Artifacts,
        [DateTimeOffset]$GeneratedAt = [DateTimeOffset]::UtcNow
    )

    if ($RunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Template runId must be 32 lowercase hexadecimal characters.'
    }
    if ($Artifacts.Count -lt 1 -or $Artifacts.Count -gt 2) {
        throw 'A template generation must contain one or two targets.'
    }

    $targets = [Collections.Generic.List[string]]::new()
    $manifestArtifacts = [Collections.Generic.List[object]]::new()
    foreach ($artifact in $Artifacts) {
        $target = [string]$artifact.target
        if ($target -cin @($targets)) {
            throw 'Template target values must be unique.'
        }
        $expectedFile = Get-LanzouTemplateFileName -Target $target
        if ([string]$artifact.file -cne $expectedFile) {
            throw 'Template artifact file does not match its target.'
        }
        $bytes = [long]$artifact.bytes
        $sha256 = ([string]$artifact.sha256).ToLowerInvariant()
        if ($bytes -le 0 -or $sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Template artifact metadata is invalid.'
        }
        $targets.Add($target)
        $manifestArtifacts.Add([ordered]@{
            target = $target
            file = $expectedFile
            bytes = $bytes
            sha256 = $sha256
        })
    }

    [ordered]@{
        schemaVersion = $script:LanzouTemplateManifestSchemaVersion
        purpose = $script:LanzouTemplatePurpose
        generation = [ordered]@{
            runId = $RunId
            generatedAt = $GeneratedAt.ToUniversalTime().ToString('o')
        }
        coreAbi = [ordered]@{
            version = $script:LanzouTemplateCoreAbiVersion
            exports = @($script:LanzouTemplateCoreExports)
        }
        recipeSchemaVersion = $script:LanzouTemplateRecipeSchemaVersion
        targets = @($targets)
        artifacts = @($manifestArtifacts)
    }
}

function Read-LanzouTemplateSet {
    param([Parameter(Mandatory)][string]$RootPath)

    $rootItem = Get-Item -LiteralPath $RootPath -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) {
        throw 'Template root must be a directory.'
    }
    $root = $rootItem.FullName
    $manifestPath = Join-Path $root $script:LanzouTemplateManifestName
    $manifestItem = Get-Item -LiteralPath $manifestPath -ErrorAction Stop
    if ($manifestItem.PSIsContainer -or $manifestItem.Length -le 0 -or $manifestItem.Length -gt 64KB) {
        throw 'Template manifest size is invalid.'
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestItem.FullName -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 16
    }
    catch {
        throw 'Template manifest is not valid JSON.'
    }
    Assert-LanzouExactObject $manifest 'template manifest' @(
        'schemaVersion', 'purpose', 'generation', 'coreAbi',
        'recipeSchemaVersion', 'targets', 'artifacts'
    )
    if ($manifest.schemaVersion -ne $script:LanzouTemplateManifestSchemaVersion -or
        [string]$manifest.purpose -cne $script:LanzouTemplatePurpose -or
        $manifest.recipeSchemaVersion -ne $script:LanzouTemplateRecipeSchemaVersion) {
        throw 'Template manifest contract version is unsupported.'
    }

    Assert-LanzouExactObject $manifest.generation 'template generation' @('runId', 'generatedAt')
    $runId = [string]$manifest.generation.runId
    if ($runId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Template manifest runId is invalid.'
    }
    $generatedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$manifest.generation.generatedAt,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$generatedAt
    )) {
        throw 'Template manifest generatedAt is invalid.'
    }

    Assert-LanzouExactObject $manifest.coreAbi 'template coreAbi' @('version', 'exports')
    if ($manifest.coreAbi.version -ne $script:LanzouTemplateCoreAbiVersion -or
        $manifest.coreAbi.exports -isnot [array]) {
        throw 'Template core ABI is unsupported.'
    }
    $exports = @($manifest.coreAbi.exports)
    if ($exports.Count -ne $script:LanzouTemplateCoreExports.Count) {
        throw 'Template core ABI exports are invalid.'
    }
    for ($index = 0; $index -lt $exports.Count; $index++) {
        if ([string]$exports[$index] -cne $script:LanzouTemplateCoreExports[$index]) {
            throw 'Template core ABI exports are invalid.'
        }
    }

    if ($manifest.targets -isnot [array] -or $manifest.artifacts -isnot [array]) {
        throw 'Template targets and artifacts must be JSON arrays.'
    }
    $targets = @($manifest.targets | ForEach-Object { [string]$_ })
    $artifacts = @($manifest.artifacts)
    if ($targets.Count -lt 1 -or $targets.Count -gt 2 -or
        $artifacts.Count -ne $targets.Count) {
        throw 'Template target set is invalid.'
    }

    $seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $templates = @{}
    $records = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $targets.Count; $index++) {
        $target = $targets[$index]
        if ($target -cnotin @('android', 'windows') -or -not $seenTargets.Add($target)) {
            throw 'Template target set is invalid.'
        }
        $artifact = $artifacts[$index]
        Assert-LanzouExactObject $artifact 'template artifact' @('target', 'file', 'bytes', 'sha256')
        $expectedFile = Get-LanzouTemplateFileName -Target $target
        if ([string]$artifact.target -cne $target -or [string]$artifact.file -cne $expectedFile) {
            throw 'Template artifact does not match the ordered target set.'
        }
        if ($artifact.bytes -isnot [long] -and $artifact.bytes -isnot [int]) {
            throw 'Template artifact byte count must be an integer.'
        }
        $expectedBytes = [long]$artifact.bytes
        $expectedHash = [string]$artifact.sha256
        if ($expectedBytes -le 0 -or $expectedHash -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Template artifact metadata is invalid.'
        }

        $templatePath = Join-Path $root $expectedFile
        $templateItem = Get-Item -LiteralPath $templatePath -ErrorAction Stop
        if ($templateItem.PSIsContainer -or $templateItem.Length -ne $expectedBytes) {
            throw 'Template artifact size does not match its generation manifest.'
        }
        $actualHash = (Get-FileHash -LiteralPath $templateItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne $expectedHash) {
            throw 'Template artifact digest does not match its generation manifest.'
        }
        $templates[$target] = $templateItem.FullName
        $records.Add([pscustomobject]@{
            Target = $target
            File = $expectedFile
            Bytes = $expectedBytes
            Sha256 = $expectedHash
            Path = $templateItem.FullName
        })
    }

    [pscustomobject]@{
        RunId = $runId
        GeneratedAt = $generatedAt
        Targets = $targets
        Templates = $templates
        Records = @($records)
        Manifest = $manifest
        ManifestPath = $manifestItem.FullName
    }
}
