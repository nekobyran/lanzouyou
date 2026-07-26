[CmdletBinding(DefaultParameterSetName = 'Package')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Package')]
    [string]$RecipePath,

    [Parameter(ParameterSetName = 'Package')]
    [string]$OutputRoot,

    [Parameter(ParameterSetName = 'Package')]
    [switch]$DryRun,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$templateRoot = Join-Path $workspaceRoot 'project\LanzouYOU\assets\templates'
$templateLockPath = Join-Path (Split-Path -Parent $templateRoot) '.lanzou-library-templates.lock'
$fixedCoreLibraryPath = Join-Path $workspaceRoot 'release\LanzouYOU_Windows\release\lanzouyou_core.dll'
$manifestLibrary = Join-Path $PSScriptRoot 'LanzouLibraryTemplateManifest.ps1'
if (-not (Test-Path -LiteralPath $manifestLibrary -PathType Leaf)) {
    throw 'The template manifest contract helper was not found.'
}
. $manifestLibrary

function Assert-ExactObject {
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

function Assert-RequiredAllowedObject {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Required,
        [Parameter(Mandatory)][string[]]$Allowed
    )
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$Label must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties.Name)
    foreach ($name in $Required) {
        if ($name -notin $actual) { throw "$Label is missing a required field." }
    }
    foreach ($name in $actual) {
        if ($name -notin $Allowed) { throw "$Label contains an unsupported field." }
    }
}

function Assert-Slug {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Value -cnotmatch $Pattern) {
        throw "$Label has an invalid format."
    }
}

function Test-WindowsReservedName {
    param([Parameter(Mandatory)][string]$Value)
    return $Value -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])$'
}

function Assert-HttpsUrl {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Label,
        [switch]$LanzouHost,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) { return }
        throw "$Label cannot be empty."
    }
    if ($Value.Length -gt 2048) {
        throw "$Label is too long."
    }
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "$Label must be a safe HTTPS URL."
    }
    if ($LanzouHost) {
        $authorityMatch = [regex]::Match(
            $Value,
            '\Ahttps://(?<authority>[^/?#]+)',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        $authority = $authorityMatch.Groups['authority'].Value
        if (-not $authorityMatch.Success -or
            $authority -match '[^\x00-\x7F]' -or
            $authority.Contains('@') -or
            $authority.Contains(':') -or
            $authority.EndsWith('.', [StringComparison]::Ordinal) -or
            $authority -match '(?i)(?:^|\.)xn--' -or
            -not $authority.Equals($uri.Host, [StringComparison]::OrdinalIgnoreCase) -or
            $authority -notmatch '^(?i:(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*(?:lanzouw|lanzoui)\.com)$') {
            throw "$Label must use lanzouw.com or lanzoui.com without credentials, IDN, trailing dot, or an explicit port."
        }
    }
}

function Read-AndValidateRecipe {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 1MB) {
        throw 'Recipe file size is invalid.'
    }
    $recipe = Get-Content -LiteralPath $item.FullName -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 32
    $requiredRoot = @(
        'schemaVersion', 'identity', 'branding', 'sources', 'features', 'build'
    )
    Assert-RequiredAllowedObject $recipe 'recipe' $requiredRoot @(
        $requiredRoot + @('workspace', 'home')
    )
    if ($recipe.schemaVersion -ne 1) {
        throw 'Only schemaVersion 1 is supported.'
    }

    Assert-ExactObject $recipe.identity 'identity' @(
        'projectId', 'displayName', 'applicationId', 'versionName',
        'versionCode', 'windowsExeName'
    )
    $identity = $recipe.identity
    Assert-Slug ([string]$identity.projectId) '^[a-z][a-z0-9_]{1,39}$' 'projectId'
    Assert-Slug ([string]$identity.applicationId) '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,7}$' 'applicationId'
    Assert-Slug ([string]$identity.versionName) '^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$' 'versionName'
    Assert-Slug ([string]$identity.windowsExeName) '^[a-z][a-z0-9_-]{1,39}$' 'windowsExeName'
    if ((Test-WindowsReservedName ([string]$identity.projectId)) -or
        (Test-WindowsReservedName ([string]$identity.windowsExeName))) {
        throw 'projectId and windowsExeName cannot use Windows reserved device names.'
    }
    if (([string]$identity.applicationId).Length -gt 127) {
        throw 'applicationId cannot exceed 127 ASCII bytes.'
    }
    $numericVersion = (([string]$identity.versionName) -split '[-+]', 2)[0]
    foreach ($segment in $numericVersion -split '\.') {
        if ([long]$segment -gt 65535) {
            throw 'versionName numeric segments cannot exceed 65535.'
        }
    }
    $displayName = [string]$identity.displayName
    if ([string]::IsNullOrWhiteSpace($displayName) -or
        $displayName.Length -gt 80 -or
        $displayName.IndexOfAny([char[]](0..31)) -ge 0) {
        throw 'displayName must contain 1-80 printable characters.'
    }
    if ($identity.versionCode -isnot [long] -and $identity.versionCode -isnot [int]) {
        throw 'versionCode must be an integer.'
    }
    $versionCode = [long]$identity.versionCode
    if ($versionCode -lt 1 -or $versionCode -gt [uint32]::MaxValue) {
        throw 'versionCode is outside the supported range.'
    }

    Assert-ExactObject $recipe.branding 'branding' @(
        'seedColor', 'officialUrl', 'publisher', 'logoAsset', 'themeMode'
    )
    $branding = $recipe.branding
    Assert-Slug ([string]$branding.seedColor) '^#[0-9A-Fa-f]{6}$' 'seedColor'
    Assert-HttpsUrl ([string]$branding.officialUrl) 'officialUrl' -AllowEmpty
    if ([string]$branding.logoAsset -cne 'assets/runtime/logo.png') {
        throw 'logoAsset must use the fixed runtime path.'
    }
    if ([string]$branding.themeMode -cnotin @('system', 'light', 'dark')) {
        throw 'themeMode is invalid.'
    }
    $publisher = [string]$branding.publisher
    if ($publisher.Length -gt 80 -or $publisher.IndexOfAny([char[]](0..31)) -ge 0) {
        throw 'publisher is invalid.'
    }

    $sources = @($recipe.sources)
    if ($sources.Count -lt 1 -or $sources.Count -gt 512) {
        throw 'sources must contain 1-512 entries.'
    }
    $sourceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($source in $sources) {
        Assert-ExactObject $source 'source' @(
            'sourceId', 'title', 'shareUrl', 'password', 'searchable', 'recommended'
        )
        $sourceId = [string]$source.sourceId
        Assert-Slug $sourceId '^[a-z][a-z0-9_-]{1,63}$' 'sourceId'
        if (-not $sourceIds.Add($sourceId)) {
            throw 'sourceId values must be unique.'
        }
        $title = [string]$source.title
        if ([string]::IsNullOrWhiteSpace($title) -or
            $title.Length -gt 80 -or
            $title.IndexOfAny([char[]](0..31)) -ge 0) {
            throw 'source title is invalid.'
        }
        Assert-HttpsUrl ([string]$source.shareUrl) 'shareUrl' -LanzouHost
        $password = [string]$source.password
        if ($password.Length -gt 64 -or $password.IndexOfAny([char[]](0..31)) -ge 0) {
            throw 'source access code is invalid.'
        }
        if ($source.searchable -isnot [bool] -or $source.recommended -isnot [bool]) {
            throw 'source flags must be booleans.'
        }
    }

    Assert-ExactObject $recipe.features 'features' @(
        'browse', 'search', 'download', 'showDescription'
    )
    foreach ($name in @('browse', 'search', 'download', 'showDescription')) {
        if ($recipe.features.$name -isnot [bool]) {
            throw 'feature flags must be booleans.'
        }
    }

    $homeConfig = if ($null -ne $recipe.PSObject.Properties['home']) {
        $recipe.home
    } else {
        [pscustomobject]@{
            visible = $true; splashImage = ''; splashText = ''
            carouselImages = @(); announcementUrl = ''; webPages = @()
        }
    }
    Assert-ExactObject $homeConfig 'home' @(
        'visible', 'splashImage', 'splashText', 'carouselImages',
        'announcementUrl', 'webPages'
    )
    if ($homeConfig.visible -isnot [bool] -or ([string]$homeConfig.splashText).Length -gt 2000 -or
        @($homeConfig.carouselImages).Count -gt 50 -or @($homeConfig.webPages).Count -gt 50) {
        throw 'home configuration exceeds its safety limits.'
    }
    Assert-HttpsUrl ([string]$homeConfig.splashImage) 'home.splashImage' -AllowEmpty
    Assert-HttpsUrl ([string]$homeConfig.announcementUrl) 'home.announcementUrl' -AllowEmpty
    foreach ($image in @($homeConfig.carouselImages)) {
        Assert-HttpsUrl ([string]$image) 'home.carouselImages[]'
    }
    foreach ($page in @($homeConfig.webPages)) {
        Assert-ExactObject $page 'home.webPages[]' @('name', 'url', 'icon')
        if ([string]::IsNullOrWhiteSpace([string]$page.name) -or ([string]$page.name).Length -gt 80) {
            throw 'home web page name is invalid.'
        }
        Assert-HttpsUrl ([string]$page.url) 'home.webPages[].url'
        Assert-HttpsUrl ([string]$page.icon) 'home.webPages[].icon' -AllowEmpty
    }

    Assert-ExactObject $recipe.build 'build' @('targets', 'iconSourcePath')
    $targets = @($recipe.build.targets | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($targets.Count -lt 1 -or $targets.Count -gt 2 -or
        @($targets | Select-Object -Unique).Count -ne $targets.Count) {
        throw 'targets must contain one or two unique entries.'
    }
    foreach ($target in $targets) {
        if ($target -cnotin @('android', 'windows')) {
            throw 'targets contains an unsupported platform.'
        }
    }
    $iconPath = [string]$recipe.build.iconSourcePath
    if (-not [string]::IsNullOrWhiteSpace($iconPath)) {
        $iconItem = Get-Item -LiteralPath $iconPath -ErrorAction Stop
        if ($iconItem.PSIsContainer -or $iconItem.Length -le 0 -or $iconItem.Length -gt 32MB) {
            throw 'Icon file size is invalid.'
        }
        $iconPath = $iconItem.FullName
    }

    [pscustomobject]@{
        Recipe = $recipe
        RuntimeConfig = [ordered]@{
            schemaVersion = 1
            identity = $recipe.identity
            branding = $recipe.branding
            home = $homeConfig
            sources = $recipe.sources
            features = $recipe.features
        }
        Targets = $targets
        IconPath = $iconPath
    }
}

function Find-CoreLibrary {
    if (Test-Path -LiteralPath $fixedCoreLibraryPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $fixedCoreLibraryPath).Path
    }
    throw 'The fixed prebuilt LanzouYOU Rust core was not found in the Windows release bundle.'
}

function Assert-CoreLibraryAbi {
    param([Parameter(Mandatory)][string]$Path)

    $handle = [IntPtr]::Zero
    try {
        $handle = [Runtime.InteropServices.NativeLibrary]::Load($Path)
        foreach ($export in $script:LanzouTemplateCoreExports) {
            [void][Runtime.InteropServices.NativeLibrary]::GetExport($handle, $export)
        }
    }
    catch {
        throw 'The prebuilt Rust core does not satisfy the template manifest C ABI.'
    }
    finally {
        if ($handle -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.NativeLibrary]::Free($handle)
        }
    }
}

function Initialize-CoreBridge {
    if ('LanzouCoreBridge' -as [type]) { return }
    $bridgeSource = @'
using System;
using System.Runtime.InteropServices;

public static class LanzouCoreBridge
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr DispatchDelegate(IntPtr request);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void FreeDelegate(IntPtr response);

    public static string Call(string libraryPath, string request)
    {
        IntPtr library = NativeLibrary.Load(libraryPath);
        IntPtr requestPointer = IntPtr.Zero;
        IntPtr responsePointer = IntPtr.Zero;
        try
        {
            var dispatch = Marshal.GetDelegateForFunctionPointer<DispatchDelegate>(
                NativeLibrary.GetExport(library, "lanzouyou_dispatch"));
            var free = Marshal.GetDelegateForFunctionPointer<FreeDelegate>(
                NativeLibrary.GetExport(library, "lanzouyou_free"));
            requestPointer = Marshal.StringToCoTaskMemUTF8(request);
            responsePointer = dispatch(requestPointer);
            if (responsePointer == IntPtr.Zero)
                throw new InvalidOperationException("Rust core returned no response.");
            string response = Marshal.PtrToStringUTF8(responsePointer);
            free(responsePointer);
            responsePointer = IntPtr.Zero;
            return response;
        }
        finally
        {
            if (requestPointer != IntPtr.Zero)
                Marshal.FreeCoTaskMem(requestPointer);
            NativeLibrary.Free(library);
        }
    }
}
'@
    Add-Type -TypeDefinition $bridgeSource | Out-Null
}

function Invoke-CoreRepackage {
    param(
        [Parameter(Mandatory)][string]$CoreLibrary,
        [Parameter(Mandatory)][hashtable]$Request
    )

    Initialize-CoreBridge
    $requestJson = $Request | ConvertTo-Json -Depth 32 -Compress
    $responseJson = [LanzouCoreBridge]::Call($CoreLibrary, $requestJson)
    $envelope = $responseJson | ConvertFrom-Json -Depth 32
    if ($null -eq $envelope -or $envelope.ok -ne $true) {
        $code = if ($null -ne $envelope -and $null -ne $envelope.error) {
            [string]$envelope.error.code
        } else {
            'invalid_response'
        }
        $message = if ($null -ne $envelope -and $null -ne $envelope.error) {
            [string]$envelope.error.message
        } else {
            ''
        }
        $message = ($message -replace '[\x00-\x1f\x7f]+', ' ').Trim()
        if ($message.Length -gt 300) {
            $message = $message.Substring(0, 300)
        }
        $detail = if ([string]::IsNullOrWhiteSpace($message)) { '' } else { " $message" }
        throw "Rust core packaging failed ($code).$detail"
    }
    return $envelope.data
}

function Test-PathInside {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\')
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $childPath.StartsWith("$parentPath\", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-FileHash {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    if ($Expected -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'Rust core returned an invalid digest.'
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $Expected.ToLowerInvariant()) {
        throw 'Generated artifact digest verification failed.'
    }
    return $actual
}

function Copy-ValidatedTemplateSet {
    param(
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [Parameter(Mandatory)][string[]]$RequestedTargets
    )

    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    $lock = $null
    try {
        $lock = [IO.File]::Open(
            $templateLockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $templateSet = Read-LanzouTemplateSet -RootPath $templateRoot
        $copiedTemplates = @{}
        foreach ($target in $RequestedTargets) {
            if ($target -cnotin $templateSet.Targets) {
                throw 'The requested target is not present in the active template generation.'
            }
            $record = @($templateSet.Records | Where-Object { $_.Target -ceq $target })
            if ($record.Count -ne 1) {
                throw 'The active template generation has an invalid target record.'
            }
            $destination = Join-Path $DestinationDirectory $record[0].File
            Copy-Item -LiteralPath $record[0].Path -Destination $destination
            $copy = Get-Item -LiteralPath $destination -ErrorAction Stop
            if ($copy.PSIsContainer -or $copy.Length -ne $record[0].Bytes -or
                (Get-FileHash -LiteralPath $copy.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record[0].Sha256) {
                throw 'A template changed while it was being frozen for packaging.'
            }
            $copiedTemplates[$target] = $copy.FullName
        }
        [pscustomobject]@{
            RunId = $templateSet.RunId
            Targets = @($templateSet.Targets)
            Templates = $copiedTemplates
        }
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}

function Publish-CustomArtifactSet {
    param(
        [Parameter(Mandatory)][object[]]$Artifacts,
        [Parameter(Mandatory)][string]$OutputRootFull,
        [Parameter(Mandatory)][string]$BundleName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TemplateGeneration,
        [Parameter(Mandatory)][string]$TrustedStagingRoot,
        [switch]$SimulateSecondTargetFailure
    )

    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or
        $TemplateGeneration -cnotmatch '^[0-9a-f]{32}$' -or
        $BundleName -cnotmatch '^LanzouLibrary_[a-z][a-z0-9_]{1,39}-[1-9][0-9]*$') {
        throw 'Artifact publication identity is invalid.'
    }
    if ($Artifacts.Count -lt 1 -or $Artifacts.Count -gt 2) {
        throw 'Artifact publication requires one or two targets.'
    }
    if (Test-Path -LiteralPath $OutputRootFull -PathType Leaf) {
        throw 'OutputRoot must be a directory.'
    }

    $seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($artifact in $Artifacts) {
        $target = [string]$artifact.Target
        if ($target -cnotin @('android', 'windows') -or -not $seenTargets.Add($target)) {
            throw 'Artifact target set is invalid.'
        }
        $expectedExtension = if ($target -ceq 'android') { '.apk' } else { '.zip' }
        $source = [string]$artifact.TemporaryPath
        if (-not (Test-PathInside -Child $source -Parent $TrustedStagingRoot) -or
            -not (Test-Path -LiteralPath $source -PathType Leaf) -or
            [IO.Path]::GetExtension([string]$artifact.FileName) -cne $expectedExtension -or
            [IO.Path]::GetFileName([string]$artifact.FileName) -cne [string]$artifact.FileName) {
            throw 'A staged artifact failed path validation.'
        }
        $sourceItem = Get-Item -LiteralPath $source
        if ($sourceItem.Length -le 0 -or $sourceItem.Length -ne [long]$artifact.Bytes -or
            (Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$artifact.Sha256) {
            throw 'A staged artifact failed integrity validation.'
        }
    }

    $finalDirectory = Join-Path $OutputRootFull $BundleName
    if (-not (Test-PathInside -Child $finalDirectory -Parent $OutputRootFull)) {
        throw 'Final artifact bundle path validation failed.'
    }
    if (Test-Path -LiteralPath $finalDirectory) {
        throw 'The destination artifact bundle already exists; choose a new version before generating.'
    }

    $createdOutputRoot = $false
    if (-not (Test-Path -LiteralPath $OutputRootFull -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputRootFull -Force | Out-Null
        $createdOutputRoot = $true
    }
    $stage = Join-Path $OutputRootFull ('.' + $BundleName + '.' + $RunId + '.staging')
    if (Test-Path -LiteralPath $stage) {
        throw 'A reserved artifact publication directory already exists.'
    }
    New-Item -ItemType Directory -Path $stage | Out-Null

    $activated = $false
    try {
        $publishedRecords = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $Artifacts.Count; $index++) {
            if ($SimulateSecondTargetFailure -and $index -eq 1) {
                throw 'Simulated second-target publication failure.'
            }
            $artifact = $Artifacts[$index]
            $platformName = if ([string]$artifact.Target -ceq 'android') { 'Android' } else { 'Windows' }
            $platformDirectory = Join-Path $stage (Join-Path $platformName 'release')
            New-Item -ItemType Directory -Path $platformDirectory -Force | Out-Null
            $stagedDestination = Join-Path $platformDirectory ([string]$artifact.FileName)
            Copy-Item -LiteralPath ([string]$artifact.TemporaryPath) -Destination $stagedDestination
            $copied = Get-Item -LiteralPath $stagedDestination -ErrorAction Stop
            $copiedHash = (Get-FileHash -LiteralPath $copied.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($copied.Length -ne [long]$artifact.Bytes -or $copiedHash -cne [string]$artifact.Sha256) {
                throw 'A copied artifact failed integrity validation.'
            }
            $publishedRecords.Add([ordered]@{
                target = [string]$artifact.Target
                file = [string]$artifact.FileName
                bytes = [long]$copied.Length
                sha256 = $copiedHash
            })
        }

        $publicationManifest = [ordered]@{
            schemaVersion = 1
            runId = $RunId
            templateGeneration = $TemplateGeneration
            recipeSchemaVersion = $script:LanzouTemplateRecipeSchemaVersion
            targets = @($publishedRecords | ForEach-Object { $_.target })
            artifacts = @($publishedRecords)
        }
        Write-LanzouUtf8JsonFile `
            -Path (Join-Path $stage 'artifacts-manifest.json') `
            -Value $publicationManifest

        [IO.Directory]::Move($stage, $finalDirectory)
        $activated = $true

        $resultArtifacts = [Collections.Generic.List[object]]::new()
        foreach ($record in $publishedRecords) {
            $platformName = if ($record.target -ceq 'android') { 'Android' } else { 'Windows' }
            $path = Join-Path $finalDirectory (Join-Path (Join-Path $platformName 'release') $record.file)
            $resultArtifacts.Add([ordered]@{
                platform = $record.target
                path = (Get-Item -LiteralPath $path).FullName
                sha256 = $record.sha256
            })
        }
        [pscustomobject]@{
            Directory = (Get-Item -LiteralPath $finalDirectory).FullName
            Artifacts = @($resultArtifacts)
        }
    }
    finally {
        if (-not $activated -and (Test-Path -LiteralPath $stage -PathType Container)) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
        if (-not $activated -and $createdOutputRoot -and
            (Test-Path -LiteralPath $OutputRootFull -PathType Container)) {
            try {
                [IO.Directory]::Delete($OutputRootFull, $false)
            }
            catch {
                # A concurrently created user entry is never removed.
            }
        }
    }
}

function Invoke-SelfTest {
    foreach ($scriptPath in @($PSCommandPath, $manifestLibrary)) {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -ne 0) {
            throw 'Script parser self-test failed.'
        }
        $commands = @(
            $ast.FindAll(
                { param($node) $node -is [Management.Automation.Language.CommandAst] },
                $true
            ) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
        )
        foreach ($forbidden in @('flutter', 'flutter.bat', 'gradle', 'gradlew', 'gradlew.bat', 'cargo')) {
            if ($forbidden -in $commands) {
                throw 'Packaging script contains a forbidden source-build command.'
            }
        }
    }

    $expectedCorePath = Join-Path $workspaceRoot 'release\LanzouYOU_Windows\release\lanzouyou_core.dll'
    if (-not $fixedCoreLibraryPath.Equals($expectedCorePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixed prebuilt core path self-test failed.'
    }

    $rejectedTraversal = $false
    try {
        Assert-Slug '../escape' '^[a-z][a-z0-9_]{1,39}$' 'projectId'
    }
    catch {
        $rejectedTraversal = $true
    }
    if (-not $rejectedTraversal) {
        throw 'Traversal validation self-test failed.'
    }
    if (-not (Test-WindowsReservedName 'con') -or (Test-WindowsReservedName 'content')) {
        throw 'Windows reserved-name self-test failed.'
    }

    Assert-HttpsUrl 'https://lanzouw.com/share' 'shareUrl' -LanzouHost
    Assert-HttpsUrl 'https://safe-sub.lanzoui.com/share' 'shareUrl' -LanzouHost
    foreach ($unsafeUrl in @(
        'https://lanzoux.com/share',
        'https://lanzouw.com.evil.invalid/share',
        'https://user@lanzouw.com/share',
        'https://lanzouw.com:443/share',
        'https://lanzoui.com:8443/share',
        'https://lanzouw.com./share',
        'https://xn--example.lanzouw.com/share',
        ('https://' + [char]0x4f8b + [char]0x5b50 + '.lanzouw.com/share')
    )) {
        $rejected = $false
        try {
            Assert-HttpsUrl $unsafeUrl 'shareUrl' -LanzouHost
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw 'Lanzou registrable-domain validation self-test failed.'
        }
    }

    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lanzou-custom-selftest-' + [guid]::NewGuid().ToString('N'))
    $templateTestRoot = Join-Path $testRoot 'templates'
    $stagingRoot = Join-Path $testRoot 'job'
    $outputTestRoot = Join-Path $testRoot 'release-output'
    New-Item -ItemType Directory -Path $templateTestRoot, $stagingRoot -Force | Out-Null
    try {
        $largeCatalogSources = @(
            0..473 | ForEach-Object {
                [ordered]@{
                    sourceId = "source_$_"
                    title = "Source $_"
                    shareUrl = 'https://www.lanzouw.com/b123'
                    password = ''
                    searchable = $true
                    recommended = ($_ -eq 0)
                }
            }
        )
        $largeCatalogRecipe = [ordered]@{
            schemaVersion = 1
            identity = [ordered]@{
                projectId = 'large_catalog'
                displayName = 'Large catalog'
                applicationId = 'cc.nkbr.largecatalog'
                versionName = '1.0.0'
                versionCode = 1
                windowsExeName = 'large-catalog'
            }
            branding = [ordered]@{
                seedColor = '#2563EB'
                officialUrl = 'https://example.com/'
                publisher = 'Publisher'
                logoAsset = 'assets/runtime/logo.png'
                themeMode = 'system'
            }
            sources = $largeCatalogSources
            features = [ordered]@{
                browse = $true
                search = $true
                download = $true
                showDescription = $true
            }
            build = [ordered]@{
                targets = @('windows')
                iconSourcePath = ''
            }
        }
        $largeCatalogRecipePath = Join-Path $testRoot 'large-catalog.json'
        Write-LanzouUtf8JsonFile -Path $largeCatalogRecipePath -Value $largeCatalogRecipe
        $validatedLargeCatalog = Read-AndValidateRecipe -Path $largeCatalogRecipePath
        if (@($validatedLargeCatalog.Recipe.sources).Count -ne 474) {
            throw 'Current 474-source catalog validation self-test failed.'
        }
        $largeCatalogRecipe.sources = @(
            $largeCatalogSources
            474..512 | ForEach-Object {
                [ordered]@{
                    sourceId = "source_$_"
                    title = "Source $_"
                    shareUrl = 'https://www.lanzouw.com/b123'
                    password = ''
                    searchable = $true
                    recommended = $false
                }
            }
        )
        Write-LanzouUtf8JsonFile -Path $largeCatalogRecipePath -Value $largeCatalogRecipe
        $oversizedCatalogRejected = $false
        try {
            [void](Read-AndValidateRecipe -Path $largeCatalogRecipePath)
        }
        catch {
            $oversizedCatalogRejected = $true
        }
        if (-not $oversizedCatalogRejected) {
            throw '513-source catalog ceiling self-test failed.'
        }

        $templateRunId = [guid]::NewGuid().ToString('N')
        $templateRecords = [Collections.Generic.List[object]]::new()
        foreach ($target in @('android', 'windows')) {
            $templatePath = Join-Path $templateTestRoot (Get-LanzouTemplateFileName -Target $target)
            [IO.File]::WriteAllText($templatePath, "template-$target")
            $templateItem = Get-Item -LiteralPath $templatePath
            $templateRecords.Add([pscustomobject]@{
                target = $target
                file = $templateItem.Name
                bytes = [long]$templateItem.Length
                sha256 = (Get-FileHash -LiteralPath $templateItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
        $templateManifest = New-LanzouTemplateManifest `
            -RunId $templateRunId `
            -Artifacts @($templateRecords)
        Write-LanzouUtf8JsonFile `
            -Path (Join-Path $templateTestRoot 'templates-manifest.json') `
            -Value $templateManifest
        [void](Read-LanzouTemplateSet -RootPath $templateTestRoot)
        Add-Content `
            -LiteralPath (Join-Path $templateTestRoot 'lanzou_library_shell_windows.zip') `
            -Value 'tamper' `
            -NoNewline
        $tamperRejected = $false
        try {
            [void](Read-LanzouTemplateSet -RootPath $templateTestRoot)
        }
        catch {
            $tamperRejected = $true
        }
        if (-not $tamperRejected) {
            throw 'Template manifest tamper self-test failed.'
        }

        $artifactRecords = [Collections.Generic.List[object]]::new()
        foreach ($target in @('android', 'windows')) {
            $extension = if ($target -ceq 'android') { 'apk' } else { 'zip' }
            $path = Join-Path $stagingRoot "demo_library-1.0.0.$extension"
            [IO.File]::WriteAllText($path, "artifact-$target")
            $item = Get-Item -LiteralPath $path
            $artifactRecords.Add([pscustomobject]@{
                Target = $target
                TemporaryPath = $item.FullName
                FileName = $item.Name
                Bytes = [long]$item.Length
                Sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
        $secondFailed = $false
        try {
            [void](Publish-CustomArtifactSet `
                -Artifacts @($artifactRecords) `
                -OutputRootFull $outputTestRoot `
                -BundleName 'LanzouLibrary_demo_library-1' `
                -RunId ([guid]::NewGuid().ToString('N')) `
                -TemplateGeneration $templateRunId `
                -TrustedStagingRoot $stagingRoot `
                -SimulateSecondTargetFailure)
        }
        catch {
            $secondFailed = $true
        }
        if (-not $secondFailed -or (Test-Path -LiteralPath $outputTestRoot)) {
            throw 'Two-target atomic publication self-test failed.'
        }

        $existingBundle = Join-Path $outputTestRoot 'LanzouLibrary_demo_library-1'
        New-Item -ItemType Directory -Path $existingBundle -Force | Out-Null
        $existingMarker = Join-Path $existingBundle 'user-marker.txt'
        [IO.File]::WriteAllText($existingMarker, 'preserve')
        $existingHash = (Get-FileHash -LiteralPath $existingMarker -Algorithm SHA256).Hash
        $overwriteRejected = $false
        try {
            [void](Publish-CustomArtifactSet `
                -Artifacts @($artifactRecords) `
                -OutputRootFull $outputTestRoot `
                -BundleName 'LanzouLibrary_demo_library-1' `
                -RunId ([guid]::NewGuid().ToString('N')) `
                -TemplateGeneration $templateRunId `
                -TrustedStagingRoot $stagingRoot)
        }
        catch {
            $overwriteRejected = $true
        }
        if (-not $overwriteRejected -or
            (Get-FileHash -LiteralPath $existingMarker -Algorithm SHA256).Hash -cne $existingHash) {
            throw 'Existing artifact non-overwrite self-test failed.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $testRoot -PathType Container) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    [ordered]@{
        result = 'pass'
        checks = @(
            'syntax',
            'no-source-build-commands',
            'fixed-prebuilt-core-path',
            '474-source-catalog-supported',
            '513-source-catalog-rejected',
            'manifest-tamper-rejected',
            'two-target-failure-zero-publish',
            'existing-bundle-not-overwritten',
            'traversal-rejected',
            'windows-reserved-name-rejected',
            'lanzou-registrable-domain-allowlist'
        )
    } | ConvertTo-Json -Compress
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$validated = Read-AndValidateRecipe -Path $RecipePath
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $workspaceRoot 'release'
}
$outputRootFull = [IO.Path]::GetFullPath($OutputRoot)

$jobRoot = Join-Path $workspaceRoot 'build\library-packager'
New-Item -ItemType Directory -Path $jobRoot -Force | Out-Null
$jobRoot = (Get-Item -LiteralPath $jobRoot).FullName
$runId = [guid]::NewGuid().ToString('N')
$job = Join-Path $jobRoot $runId
New-Item -ItemType Directory -Path $job | Out-Null
$templateCopies = Join-Path $job 'templates'
$generatedArtifacts = [Collections.Generic.List[object]]::new()

try {
    $frozenTemplates = Copy-ValidatedTemplateSet `
        -DestinationDirectory $templateCopies `
        -RequestedTargets $validated.Targets

    $bundleName = 'LanzouLibrary_{0}-{1}' -f @(
        [string]$validated.Recipe.identity.projectId,
        [long]$validated.Recipe.identity.versionCode
    )
    $plannedDirectory = Join-Path $outputRootFull $bundleName
    if (-not (Test-PathInside -Child $plannedDirectory -Parent $outputRootFull)) {
        throw 'Output bundle path validation failed.'
    }
    if (Test-Path -LiteralPath $plannedDirectory) {
        throw 'The destination artifact bundle already exists; choose a new version before generating.'
    }

    if ($DryRun) {
        [ordered]@{
            result = 'pass'
            dryRun = $true
            templateGeneration = $frozenTemplates.RunId
            targets = $validated.Targets
        } | ConvertTo-Json -Compress
        exit 0
    }
    if (-not $IsWindows) {
        throw 'This packaging entry currently requires the prebuilt Windows Rust core.'
    }
    $coreLibrary = Find-CoreLibrary
    Assert-CoreLibraryAbi -Path $coreLibrary

    foreach ($target in $validated.Targets) {
        $isAndroid = $target -ceq 'android'
        $extension = if ($isAndroid) { 'apk' } else { 'zip' }
        $templatePath = (Get-Item -LiteralPath $frozenTemplates.Templates[$target]).FullName
        $templateHashBefore = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $fileName = '{0}-{1}.{2}' -f @(
            $validated.Recipe.identity.projectId,
            $validated.Recipe.identity.versionName,
            $extension
        )
        $temporaryOutput = Join-Path $job $fileName
        $request = @{
            op = if ($isAndroid) { 'library_repackage_android' } else { 'library_repackage_windows' }
            templatePath = $templatePath
            outputPath = $temporaryOutput
            runtimeConfig = $validated.RuntimeConfig
        }
        if (-not [string]::IsNullOrWhiteSpace($validated.IconPath)) {
            $request.iconPath = $validated.IconPath
        }
        if ($isAndroid) {
            $signingRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) `
                'LanzouYOU\data\signing\library-builder'
            New-Item -ItemType Directory -Path $signingRoot -Force | Out-Null
            $request.signingIdentityPath = Join-Path $signingRoot 'android-signing-identity.bin'
        }

        $data = Invoke-CoreRepackage -CoreLibrary $coreLibrary -Request $request
        $returnedPath = if ($isAndroid) { [string]$data.apkPath } else { [string]$data.archivePath }
        if ([IO.Path]::GetFullPath($returnedPath) -cne [IO.Path]::GetFullPath($temporaryOutput) -or
            -not (Test-Path -LiteralPath $temporaryOutput -PathType Leaf)) {
            throw 'Rust core returned an unexpected output path.'
        }
        $sha256 = Assert-FileHash -Path $temporaryOutput -Expected ([string]$data.sha256)
        if ($isAndroid) {
            if ([string]$data.packageName -cne [string]$validated.Recipe.identity.applicationId -or
                [string]$data.versionName -cne [string]$validated.Recipe.identity.versionName -or
                [long]$data.versionCode -ne [long]$validated.Recipe.identity.versionCode -or
                [string]$data.certificateSha256 -cnotmatch '^[0-9a-fA-F]{64}$') {
                throw 'Android artifact identity verification failed.'
            }
        } elseif ([string]$data.exeName -cne "$($validated.Recipe.identity.windowsExeName).exe") {
            throw 'Windows artifact identity verification failed.'
        }
        $templateHashAfter = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($templateHashAfter -cne $templateHashBefore) {
            throw 'The immutable template was modified.'
        }

        if (-not (Test-PathInside -Child $temporaryOutput -Parent $job)) {
            throw 'Artifact path validation failed.'
        }
        $generatedItem = Get-Item -LiteralPath $temporaryOutput
        $generatedArtifacts.Add([pscustomobject]@{
            Target = $target
            TemporaryPath = $generatedItem.FullName
            FileName = $fileName
            Bytes = [long]$generatedItem.Length
            Sha256 = $sha256
        })
    }

    $publication = Publish-CustomArtifactSet `
        -Artifacts @($generatedArtifacts) `
        -OutputRootFull $outputRootFull `
        -BundleName $bundleName `
        -RunId $runId `
        -TemplateGeneration $frozenTemplates.RunId `
        -TrustedStagingRoot $job

    [ordered]@{
        result = 'pass'
        directory = $publication.Directory
        templateGeneration = $frozenTemplates.RunId
        artifacts = $publication.Artifacts
    } | ConvertTo-Json -Depth 8 -Compress
}
finally {
    if ((Test-PathInside -Child $job -Parent $jobRoot) -and
        (Test-Path -LiteralPath $job -PathType Container)) {
        Remove-Item -LiteralPath $job -Recurse -Force
    }
}
