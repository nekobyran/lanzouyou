[CmdletBinding(DefaultParameterSetName = 'Build', PositionalBinding = $false)]
param(
    [Parameter(ParameterSetName = 'Build')]
    [string]$FlutterSdkPath,

    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'ValidateAndroid')]
    [string]$AndroidSdkPath,

    [Parameter(ParameterSetName = 'Build')]
    [string]$JavaHome,

    [Parameter(ParameterSetName = 'Build')]
    [string]$GradleUserHome,

    [Parameter(ParameterSetName = 'Build')]
    [string]$CargoPath,

    [Parameter(ParameterSetName = 'Build')]
    [string]$SdkRoot,

    [Parameter(ParameterSetName = 'Build')]
    [string]$CargoHome,

    [Parameter(ParameterSetName = 'Build')]
    [string]$RustupHome,

    [Parameter(ParameterSetName = 'Build')]
    [string]$PubCache,

    [Parameter(ParameterSetName = 'Build')]
    [string]$NuGetPackages,

    [Parameter(ParameterSetName = 'Build')]
    [string]$TempPath,

    [Parameter(ParameterSetName = 'Build')]
    [switch]$EnvironmentCheck,

    [Parameter(ParameterSetName = 'Build')]
    [switch]$SkipAndroid,

    [Parameter(ParameterSetName = 'Build')]
    [switch]$SkipWindows,

    [Parameter(Mandatory, ParameterSetName = 'ValidateAndroid')]
    [string]$ValidateAndroidApkPath,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$manifestLibrary = Join-Path $PSScriptRoot 'LanzouLibraryTemplateManifest.ps1'
if (-not (Test-Path -LiteralPath $manifestLibrary -PathType Leaf)) {
    throw 'The template manifest contract helper was not found.'
}
. $manifestLibrary

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceDriveRoot = [IO.Path]::GetPathRoot($projectRoot)
$canonicalSdkRoot = [IO.Path]::GetFullPath((Join-Path $workspaceDriveRoot 'vibecoding\sdk'))
$standardSdkRoot = [IO.Path]::GetFullPath($(if ($SdkRoot) { $SdkRoot } else { $canonicalSdkRoot }))
if (-not $standardSdkRoot.Equals($canonicalSdkRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "SdkRoot must use the canonical workspace SDK root: $canonicalSdkRoot"
}
if (-not (Test-Path -LiteralPath $standardSdkRoot -PathType Container)) {
    throw "Canonical SDK root does not exist: $standardSdkRoot"
}
$sdkRootItem = Get-Item -LiteralPath $standardSdkRoot -Force
if ($sdkRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Canonical SDK root must be a physical directory: $standardSdkRoot"
}
$defaultFlutterSdk = Join-Path $standardSdkRoot 'flutter'
$defaultAndroidSdk = Join-Path $standardSdkRoot 'android'
$defaultJavaHome = Join-Path $standardSdkRoot 'jdk'
$defaultCargoHome = Join-Path $standardSdkRoot 'rust\cargo'
$defaultRustupHome = Join-Path $standardSdkRoot 'rust\rustup'
$defaultPubCache = Join-Path $standardSdkRoot 'cache\pub'
$defaultGradleUserHome = Join-Path $standardSdkRoot 'cache\gradle'
$defaultNuGetPackages = Join-Path $standardSdkRoot 'cache\nuget'
$defaultTempPath = Join-Path $standardSdkRoot 'cache\temp'
$defaultAndroidUserHome = Join-Path $standardSdkRoot 'cache\android-user'
$defaultCmakeHome = Join-Path $standardSdkRoot 'android\cmake\3.22.1'
$shellProject = Join-Path $projectRoot 'project\LanzouLibraryShell'
$coreProject = Join-Path $projectRoot 'project\LanzouYOU\native\lanzouyou_core'
$defaultCargoTargetDir = Join-Path $coreProject 'target'
$assetDirectory = Join-Path $projectRoot 'project\LanzouYOU\assets\templates'
$assetParent = Split-Path -Parent $assetDirectory
$assetLockPath = Join-Path $assetParent '.lanzou-library-templates.lock'
$releaseRoot = Join-Path $projectRoot 'release\LanzouLibraryShell_templates\release'
$stageParent = Join-Path $projectRoot 'build\library-template-publisher'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Add-PathEntry {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    $entries = @($env:PATH -split [IO.Path]::PathSeparator)
    if ($entries -notcontains $Path) {
        $env:PATH = $Path + [IO.Path]::PathSeparator + $env:PATH
    }
}

function Test-CanonicalSdkContainment {
    param([Parameter(Mandatory)][string]$Path)
    $root = $standardSdkRoot.TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    return $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-UnderCanonicalSdkRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DisplayName,
        [switch]$ReturnPhysical
    )
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-CanonicalSdkContainment -Path $full)) {
        throw "$DisplayName must be under the canonical SDK root: $standardSdkRoot"
    }
    $relative = [IO.Path]::GetRelativePath($standardSdkRoot, $full)
    $physical = $standardSdkRoot
    if ($relative -ne '.') {
        foreach ($segment in $relative.Split(
            [IO.Path]::DirectorySeparatorChar,
            [StringSplitOptions]::RemoveEmptyEntries
        )) {
            $physical = Join-Path $physical $segment
            if (Test-Path -LiteralPath $physical) {
                $item = Get-Item -LiteralPath $physical -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $target = $item.ResolveLinkTarget($true)
                    if (-not $target) {
                        throw "$DisplayName contains an unresolved reparse point: $($item.FullName)"
                    }
                    $physical = $target.FullName
                }
            }
            if (-not (Test-CanonicalSdkContainment -Path $physical)) {
                throw "$DisplayName escapes the canonical SDK root through a reparse point: $physical"
            }
        }
    }
    if ($ReturnPhysical) { return [IO.Path]::GetFullPath($physical) }
    return $full
}

function Resolve-Application {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Candidates,
        [Parameter(Mandatory)][string[]]$CommandNames,
        [Parameter(Mandatory)][string]$RelativeExecutable
    )
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $path = $candidate
        if (Test-Path -LiteralPath $path -PathType Container) {
            $path = Join-Path $path $RelativeExecutable
        }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $resolved = (Resolve-Path -LiteralPath $path).Path
            Add-PathEntry -Path (Split-Path -Parent $resolved)
            return $resolved
        }
    }
    throw "$DisplayName was not found at its canonical SDK path."
}

function Resolve-BuildCacheDirectory {
    param(
        [string]$RequestedPath,
        [Parameter(Mandatory)][string]$DefaultPath,
        [Parameter(Mandatory)][string]$DisplayName
    )
    $selected = if ($RequestedPath) { $RequestedPath } else { $DefaultPath }
    [void](Assert-UnderCanonicalSdkRoot -Path $selected -DisplayName $DisplayName)
    New-Item -ItemType Directory -Force -Path $selected | Out-Null
    return (Assert-UnderCanonicalSdkRoot `
        -Path (Resolve-Path -LiteralPath $selected).Path `
        -DisplayName $DisplayName)
}

function Set-BuildCacheEnvironment {
    $env:CARGO_HOME = Resolve-BuildCacheDirectory -RequestedPath $CargoHome -DefaultPath $defaultCargoHome -DisplayName 'CARGO_HOME'
    $env:RUSTUP_HOME = Resolve-BuildCacheDirectory -RequestedPath $RustupHome -DefaultPath $defaultRustupHome -DisplayName 'RUSTUP_HOME'
    $env:PUB_CACHE = Resolve-BuildCacheDirectory -RequestedPath $PubCache -DefaultPath $defaultPubCache -DisplayName 'PUB_CACHE'
    $env:GRADLE_USER_HOME = Resolve-BuildCacheDirectory -RequestedPath $GradleUserHome -DefaultPath $defaultGradleUserHome -DisplayName 'GRADLE_USER_HOME'
    $env:NUGET_PACKAGES = Resolve-BuildCacheDirectory -RequestedPath $NuGetPackages -DefaultPath $defaultNuGetPackages -DisplayName 'NUGET_PACKAGES'
    $resolvedTemp = Resolve-BuildCacheDirectory -RequestedPath $TempPath -DefaultPath $defaultTempPath -DisplayName 'Build TEMP'
    $env:TEMP = $resolvedTemp
    $env:TMP = $resolvedTemp
    $env:TMPDIR = $resolvedTemp
    $env:ANDROID_USER_HOME = Resolve-BuildCacheDirectory -DefaultPath $defaultAndroidUserHome -DisplayName 'ANDROID_USER_HOME'
    $cargoTarget = [IO.Path]::GetFullPath($defaultCargoTargetDir)
    $projectPrefix = $projectRoot.TrimEnd('\') + '\'
    if (-not $cargoTarget.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CARGO_TARGET_DIR escaped the D-drive project root: $cargoTarget"
    }
    New-Item -ItemType Directory -Force -Path $cargoTarget | Out-Null
    $env:CARGO_TARGET_DIR = (Resolve-Path -LiteralPath $cargoTarget).Path
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DART_SUPPRESS_ANALYTICS = 'true'
}

function Sync-FlutterLocalProperties {
    param(
        [Parameter(Mandatory)][string]$AndroidSdk,
        [Parameter(Mandatory)][string]$FlutterSdk
    )
    $escape = { param([string]$Value) $Value.Replace('\', '\\') }
    foreach ($file in @(
        (Join-Path $shellProject 'android\local.properties'),
        (Join-Path $projectRoot 'project\LanzouYOU\android\local.properties')
    )) {
        $preserved = if (Test-Path -LiteralPath $file -PathType Leaf) {
            @(Get-Content -LiteralPath $file -Encoding utf8 |
                Where-Object { $_ -notmatch '^\s*(sdk\.dir|flutter\.sdk)\s*=' })
        } else { @() }
        $content = @(
            ('sdk.dir=' + (& $escape $AndroidSdk)),
            ('flutter.sdk=' + (& $escape $FlutterSdk))
        ) + $preserved
        [IO.File]::WriteAllLines($file, $content, [Text.UTF8Encoding]::new($false))
    }
}

function Sync-FlutterToolConfiguration {
    param(
        [Parameter(Mandatory)][string]$FlutterCommand,
        [Parameter(Mandatory)][string]$AndroidSdk,
        [Parameter(Mandatory)][string]$JavaHome
    )
    $output = @(& $FlutterCommand config `
        --jdk-dir $JavaHome `
        --android-sdk $AndroidSdk 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter SDK/JDK configuration sync failed: $($output -join ' ')"
    }

    $settings = @(& $FlutterCommand config --list 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw 'Flutter configuration verification failed.'
    }
    $androidSetting = @($settings | Where-Object { $_ -match '^\s*android-sdk:' })
    $javaSetting = @($settings | Where-Object { $_ -match '^\s*jdk-dir:' })
    if ($androidSetting.Count -ne 1 -or
        $androidSetting[0].Trim() -cne "android-sdk: $AndroidSdk" -or
        $javaSetting.Count -ne 1 -or
        $javaSetting[0].Trim() -cne "jdk-dir: $JavaHome") {
        throw 'Flutter persisted Android SDK/JDK configuration is not canonical.'
    }
    Write-Host 'FlutterToolConfiguration: canonical'
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Invoke-VersionProbe {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    [void](Assert-UnderCanonicalSdkRoot -Path $FilePath -DisplayName $Label)
    $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "$Label version probe failed with exit code $LASTEXITCODE."
    }
    $summary = ($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    Write-Host ("{0}Probe: {1}" -f $Label, $summary)
    return $summary
}

function Get-WindowsToolchainCandidates {
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($name in @('cmake.exe', 'ninja.exe', 'cl.exe')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $entries.Add([pscustomobject]@{
            Name = $name
            Path = if ($command) { $command.Source } else { $null }
        })
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $visualStudioPath = $null
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $visualStudioPath = (@(& $vswhere -latest -products * -property installationPath 2>$null) -join '').Trim()
    }
    $entries.Add([pscustomobject]@{ Name = 'VisualStudio'; Path = $visualStudioPath })
    $windowsSdkPath = $env:WindowsSdkDir
    if (-not $windowsSdkPath) {
        foreach ($registryPath in @(
            'HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0'
        )) {
            $windowsSdk = Get-ItemProperty `
                -LiteralPath $registryPath `
                -Name InstallationFolder `
                -ErrorAction SilentlyContinue
            if ($windowsSdk) {
                $windowsSdkPath = $windowsSdk.InstallationFolder
            }
            if ($windowsSdkPath) { break }
        }
    }
    $entries.Add([pscustomobject]@{ Name = 'WindowsSdk'; Path = $windowsSdkPath })
    return @($entries)
}

function Invoke-WindowsToolchainPreflight {
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($entry in Get-WindowsToolchainCandidates) {
        if ([string]::IsNullOrWhiteSpace($entry.Path)) {
            $problems.Add("$($entry.Name)=missing")
            continue
        }
        try {
            [void](Assert-UnderCanonicalSdkRoot -Path $entry.Path -DisplayName "Windows toolchain $($entry.Name)")
        }
        catch {
            $problems.Add("$($entry.Name)=$($entry.Path)")
        }
    }
    if ($problems.Count -gt 0) {
        throw "Windows template build is blocked until its complete toolchain is under $standardSdkRoot. $($problems -join '; ')"
    }
    Write-Host 'WindowsToolchainCheck: pass'
}

function Assert-ZipEntries {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string[]]$RequiredEntries
    )
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::OpenRead($Archive)
    try {
        $zip = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Read,
            $false
        )
        try {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($entry in $zip.Entries) {
                $normalizedName = $entry.FullName.Replace('\', '/')
                if (-not $names.Add($normalizedName)) {
                    throw "Template archive contains a duplicate entry: $normalizedName"
                }
            }
            foreach ($required in $RequiredEntries) {
                if (-not $names.Contains($required)) {
                    throw "Template archive is missing required entry: $required"
                }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-AndroidReleaseArchive {
    param([Parameter(Mandatory)][string]$Archive)

    Add-Type -AssemblyName System.IO.Compression
    $expectedAbis = @('arm64-v8a', 'x86_64')
    $requiredEntries = @(
        'AndroidManifest.xml',
        'resources.arsc',
        'assets/flutter_assets/assets/runtime/library.json',
        'assets/flutter_assets/assets/runtime/logo.png'
    )
    foreach ($abi in $expectedAbis) {
        $requiredEntries += @(
            "lib/$abi/libapp.so",
            "lib/$abi/libflutter.so",
            "lib/$abi/liblanzouyou_core.so"
        )
    }
    $forbiddenJitEntries = @(
        'assets/flutter_assets/kernel_blob.bin',
        'assets/flutter_assets/isolate_snapshot_data',
        'assets/flutter_assets/vm_snapshot_data'
    )

    $stream = [IO.File]::OpenRead($Archive)
    try {
        $zip = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Read,
            $false
        )
        try {
            $entries = @($zip.Entries)
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($entry in $entries) {
                $normalizedName = $entry.FullName.Replace('\', '/')
                if (-not $names.Add($normalizedName)) {
                    throw "Android release template contains a duplicate entry: $normalizedName"
                }
            }
            foreach ($required in $requiredEntries) {
                if (-not $names.Contains($required)) {
                    throw "Android release template is missing required AOT entry: $required"
                }
            }
            foreach ($forbidden in $forbiddenJitEntries) {
                if ($names.Contains($forbidden)) {
                    throw "Android release template contains a debug/JIT entry: $forbidden"
                }
            }
            if ($entries.FullName -match '(^|/)libVkLayer_khronos_validation\.so$') {
                throw 'Android release template contains the debug Vulkan validation layer.'
            }

            $actualAbis = @(
                $entries |
                    ForEach-Object {
                        if ($_.FullName.Replace('\', '/') -match '^lib/([^/]+)/[^/]+\.so$') {
                            $Matches[1]
                        }
                    } |
                    Sort-Object -Unique
            )
            if (($actualAbis -join ',') -cne (($expectedAbis | Sort-Object) -join ',')) {
                throw "Android release template ABI set is invalid: $($actualAbis -join ', ')"
            }

            foreach ($entry in $entries | Where-Object { $_.FullName -match '^lib/.+\.so$' }) {
                if ($entry.Length -le 0 -or $entry.CompressedLength -ne $entry.Length) {
                    throw "Android release native library must be non-empty and stored uncompressed: $($entry.FullName)"
                }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Resolve-AndroidBuildTool {
    param(
        [Parameter(Mandatory)][string]$SdkRoot,
        [Parameter(Mandatory)][string]$ToolName
    )

    $buildToolsRoot = Join-Path $SdkRoot 'build-tools'
    $fileName = $ToolName + $(if ($IsWindows) { '.exe' } else { '' })
    $candidates = @(
        Get-ChildItem -LiteralPath $buildToolsRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $tool = Join-Path $_.FullName $fileName
                if (Test-Path -LiteralPath $tool -PathType Leaf) {
                    [pscustomobject]@{
                        Path = $tool
                        Version = $(
                            $parsed = [version]'0.0'
                            [void][version]::TryParse(($_.Name -replace '-.*$', ''), [ref]$parsed)
                            $parsed
                        )
                    }
                }
            }
    )
    $selected = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $selected) {
        throw "Android SDK build tool was not found: $ToolName"
    }
    return $selected.Path
}

function Invoke-Captured {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $output = @(& $FilePath @ArgumentList 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')`n$($output -join "`n")"
    }
    return ($output -join "`n")
}

function Assert-AndroidReleaseManifest {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Aapt2Path
    )

    $manifestTree = Invoke-Captured `
        -FilePath $Aapt2Path `
        -ArgumentList @('dump', 'xmltree', $Archive, '--file', 'AndroidManifest.xml')
    if ($manifestTree -match 'android:debuggable\([^\r\n]*\)=true') {
        throw 'Android release template is debuggable.'
    }
    if ($manifestTree -notmatch 'android:extractNativeLibs\([^\r\n]*\)=false') {
        throw 'Android release template must memory-map uncompressed native libraries.'
    }
    if (@([regex]::Matches($manifestTree, 'android:hardwareAccelerated\([^\r\n]*\)=true')).Count -lt 2) {
        throw 'Android release template must keep hardware acceleration enabled for the application and main activity.'
    }
    if ($manifestTree -notmatch 'android:minSdkVersion\([^\r\n]*\)=24') {
        throw 'Android release template minimum SDK contract changed unexpectedly.'
    }
    if ($manifestTree -match 'io\.flutter\.embedding\.android\.(EnableImpeller|ImpellerBackend|EnableVulkan)') {
        throw 'Android release template must not force a Flutter renderer without target-device evidence.'
    }
}

function Get-TemplateArtifactRecord {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Path
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0) {
        throw 'The staged template artifact is invalid.'
    }
    [pscustomobject]@{
        target = $Target
        file = Get-LanzouTemplateFileName -Target $Target
        bytes = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Copy-UnmanagedTemplateEntries {
    param(
        [Parameter(Mandatory)][string]$ExistingDirectory,
        [Parameter(Mandatory)][string]$CandidateDirectory
    )
    if (-not (Test-Path -LiteralPath $ExistingDirectory -PathType Container)) {
        return
    }
    $managedNames = @(
        'lanzou_library_shell_android.apk',
        'lanzou_library_shell_windows.zip',
        'templates-manifest.json'
    )
    foreach ($entry in Get-ChildItem -LiteralPath $ExistingDirectory -Force) {
        if ($entry.Name -cin $managedNames) {
            continue
        }
        $destination = Join-Path $CandidateDirectory $entry.Name
        if (Test-Path -LiteralPath $destination) {
            throw 'An unmanaged template entry conflicts with the staged generation.'
        }
        Copy-Item -LiteralPath $entry.FullName -Destination $destination -Recurse
    }
}

function Publish-EmbeddedTemplateGeneration {
    param(
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [Parameter(Mandatory)][string]$RunId,
        [switch]$SimulateActivationFailure
    )

    $destinationParent = Split-Path -Parent $DestinationDirectory
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    $incoming = Join-Path $destinationParent ('.templates.incoming.' + $RunId)
    $backup = Join-Path $destinationParent ('.templates.backup.' + $RunId)
    $failed = Join-Path $destinationParent ('.templates.failed.' + $RunId)
    foreach ($reserved in @($incoming, $backup, $failed)) {
        if (Test-Path -LiteralPath $reserved) {
            throw 'A reserved template publication directory already exists.'
        }
    }

    [void](Read-LanzouTemplateSet -RootPath $CandidateDirectory)

    $lock = $null
    $hadCurrent = $false
    $activated = $false
    try {
        $lock = [IO.File]::Open(
            $assetLockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $hadCurrent = Test-Path -LiteralPath $DestinationDirectory -PathType Container
        Copy-UnmanagedTemplateEntries `
            -ExistingDirectory $DestinationDirectory `
            -CandidateDirectory $CandidateDirectory
        [void](Read-LanzouTemplateSet -RootPath $CandidateDirectory)
        [IO.Directory]::Move($CandidateDirectory, $incoming)
        if ($hadCurrent) {
            [IO.Directory]::Move($DestinationDirectory, $backup)
        }
        if ($SimulateActivationFailure) {
            throw 'Simulated template activation failure.'
        }
        [IO.Directory]::Move($incoming, $DestinationDirectory)
        $activated = $true
        $published = Read-LanzouTemplateSet -RootPath $DestinationDirectory
        if ($published.RunId -cne $RunId) {
            throw 'The activated template generation is unexpected.'
        }
    }
    catch {
        $publicationError = $_
        if ($activated -and (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            [IO.Directory]::Move($DestinationDirectory, $failed)
            $activated = $false
        }
        if ($hadCurrent -and (Test-Path -LiteralPath $backup -PathType Container)) {
            [IO.Directory]::Move($backup, $DestinationDirectory)
        }
        if (Test-Path -LiteralPath $failed -PathType Container) {
            Remove-Item -LiteralPath $failed -Recurse -Force
        }
        throw $publicationError
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
        if (-not $activated -and (Test-Path -LiteralPath $incoming -PathType Container)) {
            Remove-Item -LiteralPath $incoming -Recurse -Force
        }
    }

    if ($hadCurrent -and (Test-Path -LiteralPath $backup -PathType Container)) {
        try {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        catch {
            Write-Warning 'The previous embedded template backup could not be cleaned; the new generation remains active.'
        }
    }
}

function Publish-ReleaseGeneration {
    param(
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [Parameter(Mandatory)][string]$RunId
    )

    [void](Read-LanzouTemplateSet -RootPath $CandidateDirectory)
    $generationParent = Join-Path $releaseRoot 'generations'
    New-Item -ItemType Directory -Path $generationParent -Force | Out-Null
    $final = Join-Path $generationParent $RunId
    $incoming = Join-Path $generationParent ('.' + $RunId + '.staging')
    foreach ($reserved in @($final, $incoming)) {
        if (Test-Path -LiteralPath $reserved) {
            throw 'The release template generation already exists.'
        }
    }
    [IO.Directory]::Move($CandidateDirectory, $incoming)
    try {
        [IO.Directory]::Move($incoming, $final)
        [void](Read-LanzouTemplateSet -RootPath $final)
    }
    catch {
        if (Test-Path -LiteralPath $incoming -PathType Container) {
            Remove-Item -LiteralPath $incoming -Recurse -Force
        }
        if (Test-Path -LiteralPath $final -PathType Container) {
            Remove-Item -LiteralPath $final -Recurse -Force
        }
        throw
    }
    return $final
}

function Remove-LegacyReleaseEntrypoints {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ExpectedRootPath,
        [Parameter(Mandatory)][string]$PublishedGenerationPath
    )

    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $expectedRoot = [IO.Path]::GetFullPath($ExpectedRootPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $root.Equals($expectedRoot, $comparison) -or
        -not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'Legacy release cleanup root is not the validated release directory.'
    }

    $generationRoot = [IO.Path]::GetFullPath((Join-Path $root 'generations')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $generation = [IO.Path]::GetFullPath($PublishedGenerationPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not ([IO.Path]::GetDirectoryName($generation)).Equals($generationRoot, $comparison) -or
        [IO.Path]::GetFileName($generation) -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Published template generation is outside the validated generations directory.'
    }
    $validated = Read-LanzouTemplateSet -RootPath $generation
    if ($validated.RunId -cne [IO.Path]::GetFileName($generation) -or
        $validated.Targets.Count -ne 2) {
        throw 'Published template generation is not a complete schema 2 generation.'
    }

    $legacyNames = @(
        'lanzou_library_shell_android.apk',
        'lanzou_library_shell_windows.zip',
        'templates-manifest.json'
    )
    $removed = [Collections.Generic.List[string]]::new()
    foreach ($name in $legacyNames) {
        $path = [IO.Path]::GetFullPath((Join-Path $root $name))
        if (-not ([IO.Path]::GetDirectoryName($path)).Equals($root, $comparison)) {
            throw 'Legacy release cleanup path escaped the validated release directory.'
        }
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'A legacy release entry is not a regular file.'
        }
        Remove-Item -LiteralPath $path -Force
        $removed.Add($name)
    }
    if (-not (Test-Path -LiteralPath $generation -PathType Container)) {
        throw 'Immutable template generation changed during legacy cleanup.'
    }
    return @($removed)
}

function Invoke-TemplateSelfTest {
    $scriptsToParse = @($PSCommandPath, $manifestLibrary)
    foreach ($scriptPath in $scriptsToParse) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -ne 0) {
            throw 'Template script parser self-test failed.'
        }
    }

    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lanzou-template-selftest-' + [guid]::NewGuid().ToString('N'))
    $destination = Join-Path $testRoot 'assets\templates'
    $candidate = Join-Path $testRoot 'candidate'
    New-Item -ItemType Directory -Path $destination, $candidate -Force | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $destination 'old-marker.txt'), 'preserve')
        $oldHash = (Get-FileHash -LiteralPath (Join-Path $destination 'old-marker.txt') -Algorithm SHA256).Hash

        $runId = [guid]::NewGuid().ToString('N')
        $androidPath = Join-Path $candidate (Get-LanzouTemplateFileName -Target 'android')
        $windowsPath = Join-Path $candidate (Get-LanzouTemplateFileName -Target 'windows')
        [IO.File]::WriteAllBytes($androidPath, [byte[]](1, 2, 3))
        [IO.File]::WriteAllBytes($windowsPath, [byte[]](4, 5, 6))
        $records = @(
            Get-TemplateArtifactRecord -Target 'android' -Path $androidPath
            Get-TemplateArtifactRecord -Target 'windows' -Path $windowsPath
        )
        $manifest = New-LanzouTemplateManifest -RunId $runId -Artifacts $records
        Write-LanzouUtf8JsonFile `
            -Path (Join-Path $candidate 'templates-manifest.json') `
            -Value $manifest
        $validated = Read-LanzouTemplateSet -RootPath $candidate
        if ($validated.RunId -cne $runId -or $validated.Targets.Count -ne 2) {
            throw 'Template manifest self-test failed.'
        }

        $script:assetLockPath = Join-Path $testRoot '.templates.lock'
        $rolledBack = $false
        try {
            Publish-EmbeddedTemplateGeneration `
                -CandidateDirectory $candidate `
                -DestinationDirectory $destination `
                -RunId $runId `
                -SimulateActivationFailure
        }
        catch {
            $rolledBack = $true
        }
        if (-not $rolledBack -or
            -not (Test-Path -LiteralPath (Join-Path $destination 'old-marker.txt') -PathType Leaf) -or
            (Get-FileHash -LiteralPath (Join-Path $destination 'old-marker.txt') -Algorithm SHA256).Hash -cne $oldHash -or
            (Test-Path -LiteralPath (Join-Path $destination 'templates-manifest.json'))) {
            throw 'Template publication rollback self-test failed.'
        }

        $releaseTestRoot = Join-Path $testRoot 'release'
        $releaseRunId = [guid]::NewGuid().ToString('N')
        $releaseGeneration = Join-Path (Join-Path $releaseTestRoot 'generations') $releaseRunId
        New-Item -ItemType Directory -Path $releaseGeneration -Force | Out-Null
        $releaseAndroid = Join-Path $releaseGeneration (Get-LanzouTemplateFileName -Target 'android')
        $releaseWindows = Join-Path $releaseGeneration (Get-LanzouTemplateFileName -Target 'windows')
        [IO.File]::WriteAllBytes($releaseAndroid, [byte[]](7, 8, 9))
        [IO.File]::WriteAllBytes($releaseWindows, [byte[]](10, 11, 12))
        $releaseRecords = @(
            Get-TemplateArtifactRecord -Target 'android' -Path $releaseAndroid
            Get-TemplateArtifactRecord -Target 'windows' -Path $releaseWindows
        )
        Write-LanzouUtf8JsonFile `
            -Path (Join-Path $releaseGeneration 'templates-manifest.json') `
            -Value (New-LanzouTemplateManifest -RunId $releaseRunId -Artifacts $releaseRecords)
        foreach ($legacyName in @(
            'lanzou_library_shell_android.apk',
            'lanzou_library_shell_windows.zip',
            'templates-manifest.json'
        )) {
            [IO.File]::WriteAllText((Join-Path $releaseTestRoot $legacyName), '{"schemaVersion":1}')
        }
        $removed = @(Remove-LegacyReleaseEntrypoints `
            -RootPath $releaseTestRoot `
            -ExpectedRootPath $releaseTestRoot `
            -PublishedGenerationPath $releaseGeneration)
        $legacyRemaining = @(Get-ChildItem -LiteralPath $releaseTestRoot -File -Force)
        $releaseValidated = Read-LanzouTemplateSet -RootPath $releaseGeneration
        if ($removed.Count -ne 3 -or $legacyRemaining.Count -ne 0 -or
            $releaseValidated.RunId -cne $releaseRunId) {
            throw 'Legacy release entry cleanup self-test failed.'
        }

        $apkRoot = Join-Path $testRoot 'release-apk-root'
        $validApk = Join-Path $testRoot 'release-aot.apk'
        $archiveEntries = @(
            'AndroidManifest.xml',
            'resources.arsc',
            'assets/flutter_assets/assets/runtime/library.json',
            'assets/flutter_assets/assets/runtime/logo.png',
            'lib/arm64-v8a/libapp.so',
            'lib/arm64-v8a/libflutter.so',
            'lib/arm64-v8a/liblanzouyou_core.so',
            'lib/x86_64/libapp.so',
            'lib/x86_64/libflutter.so',
            'lib/x86_64/liblanzouyou_core.so'
        )
        foreach ($relativePath in $archiveEntries) {
            $entryPath = Join-Path $apkRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $entryPath) -Force | Out-Null
            [IO.File]::WriteAllBytes($entryPath, [byte[]](1, 2, 3, 4))
        }
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $apkRoot,
            $validApk,
            [IO.Compression.CompressionLevel]::NoCompression,
            $false
        )
        Assert-AndroidReleaseArchive -Archive $validApk

        $duplicateEntryApk = Join-Path $testRoot 'duplicate-entry.apk'
        Copy-Item -LiteralPath $validApk -Destination $duplicateEntryApk
        $duplicateStream = [IO.File]::Open($duplicateEntryApk, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
        try {
            $duplicateZip = [IO.Compression.ZipArchive]::new(
                $duplicateStream,
                [IO.Compression.ZipArchiveMode]::Update,
                $false
            )
            try {
                $duplicateEntry = $duplicateZip.CreateEntry(
                    'resources.arsc',
                    [IO.Compression.CompressionLevel]::NoCompression
                )
                $duplicateEntryStream = $duplicateEntry.Open()
                try {
                    $duplicateEntryStream.Write([byte[]](9, 9, 9), 0, 3)
                }
                finally {
                    $duplicateEntryStream.Dispose()
                }
            }
            finally {
                $duplicateZip.Dispose()
            }
        }
        finally {
            $duplicateStream.Dispose()
        }
        $rejectedDuplicateEntry = $false
        try {
            Assert-AndroidReleaseArchive -Archive $duplicateEntryApk
        }
        catch {
            $rejectedDuplicateEntry = $true
        }
        if (-not $rejectedDuplicateEntry) {
            throw 'Android duplicate ZIP entry rejection self-test failed.'
        }

        $jitEntry = Join-Path $apkRoot 'assets/flutter_assets/kernel_blob.bin'
        [IO.File]::WriteAllBytes($jitEntry, [byte[]](5, 6, 7, 8))
        $jitApk = Join-Path $testRoot 'debug-jit.apk'
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $apkRoot,
            $jitApk,
            [IO.Compression.CompressionLevel]::NoCompression,
            $false
        )
        $rejectedJitArchive = $false
        try {
            Assert-AndroidReleaseArchive -Archive $jitApk
        }
        catch {
            $rejectedJitArchive = $true
        }
        if (-not $rejectedJitArchive) {
            throw 'Android debug/JIT archive rejection self-test failed.'
        }

        Remove-Item -LiteralPath $jitEntry -Force
        $extraAbiEntry = Join-Path $apkRoot 'lib/armeabi-v7a/libflutter.so'
        New-Item -ItemType Directory -Path (Split-Path -Parent $extraAbiEntry) -Force | Out-Null
        [IO.File]::WriteAllBytes($extraAbiEntry, [byte[]](9, 10, 11, 12))
        $extraAbiApk = Join-Path $testRoot 'extra-abi.apk'
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $apkRoot,
            $extraAbiApk,
            [IO.Compression.CompressionLevel]::NoCompression,
            $false
        )
        $rejectedExtraAbi = $false
        try {
            Assert-AndroidReleaseArchive -Archive $extraAbiApk
        }
        catch {
            $rejectedExtraAbi = $true
        }
        if (-not $rejectedExtraAbi) {
            throw 'Android extra ABI rejection self-test failed.'
        }

        Remove-Item -LiteralPath (Split-Path -Parent $extraAbiEntry) -Recurse -Force
        $missingAotEntry = Join-Path $apkRoot 'lib/x86_64/libapp.so'
        Remove-Item -LiteralPath $missingAotEntry -Force
        $missingAotApk = Join-Path $testRoot 'missing-aot.apk'
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $apkRoot,
            $missingAotApk,
            [IO.Compression.CompressionLevel]::NoCompression,
            $false
        )
        $rejectedMissingAot = $false
        try {
            Assert-AndroidReleaseArchive -Archive $missingAotApk
        }
        catch {
            $rejectedMissingAot = $true
        }
        if (-not $rejectedMissingAot) {
            throw 'Android missing AOT engine rejection self-test failed.'
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
            'generation-manifest-contract',
            'two-target-staging',
            'embedded-directory-rollback',
            'legacy-release-entry-cleanup',
            'android-release-aot-archive-contract',
            'android-duplicate-entry-rejection',
            'android-debug-jit-rejection',
            'android-extra-abi-rejection',
            'android-missing-aot-rejection'
        )
    } | ConvertTo-Json -Compress
}

if ($SelfTest) {
    Invoke-TemplateSelfTest
    exit 0
}

if ($PSCmdlet.ParameterSetName -eq 'ValidateAndroid') {
    $sdkCandidates = @(
        $AndroidSdkPath,
        $defaultAndroidSdk
    )
    $sdk = $sdkCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -First 1
    if (-not $sdk) {
        throw 'Android SDK was not found. Pass -AndroidSdkPath or configure ANDROID_SDK_ROOT.'
    }
    $apk = (Resolve-Path -LiteralPath $ValidateAndroidApkPath -ErrorAction Stop).Path
    $sdk = Assert-UnderCanonicalSdkRoot `
        -Path (Resolve-Path -LiteralPath $sdk).Path `
        -DisplayName 'Android SDK'
    $aapt2 = Resolve-AndroidBuildTool -SdkRoot $sdk -ToolName 'aapt2'
    $zipalign = Resolve-AndroidBuildTool -SdkRoot $sdk -ToolName 'zipalign'
    Assert-AndroidReleaseArchive -Archive $apk
    Assert-AndroidReleaseManifest -Archive $apk -Aapt2Path $aapt2
    [void](Invoke-Captured `
        -FilePath $zipalign `
        -ArgumentList @('-c', '-P', '16', '-v', '4', $apk))
    $apkItem = Get-Item -LiteralPath $apk
    [ordered]@{
        result = 'pass'
        artifact = $apkItem.FullName
        bytes = [long]$apkItem.Length
        sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
        buildMode = 'release'
        dartRuntime = 'AOT'
        engine = 'libflutter.so'
        abis = @('arm64-v8a', 'x86_64')
        hardwareAccelerated = $true
        rendererOverride = 'none'
        zipAlignment = '16KiB'
    } | ConvertTo-Json -Compress
    exit 0
}

if ($SkipAndroid -and $SkipWindows) {
    throw 'At least one template target must be rebuilt.'
}
foreach ($path in @($shellProject, $coreProject)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Required project directory was not found: $path"
    }
}

Set-BuildCacheEnvironment
if (-not (Test-Path -LiteralPath (Join-Path $defaultCmakeHome 'bin\cmake.exe') -PathType Leaf)) {
    throw "Canonical CMake is missing: $defaultCmakeHome"
}
[void](Assert-UnderCanonicalSdkRoot -Path $defaultCmakeHome -DisplayName 'CMake home')
Add-PathEntry -Path (Join-Path $defaultCmakeHome 'bin')
$flutter = Resolve-Application `
    -DisplayName 'Flutter SDK' `
    -Candidates @($FlutterSdkPath, $defaultFlutterSdk) `
    -CommandNames @('flutter.bat', 'flutter') `
    -RelativeExecutable 'bin\flutter.bat'
$cargo = Resolve-Application `
    -DisplayName 'Cargo' `
    -Candidates @($CargoPath, (Join-Path $env:CARGO_HOME 'bin\cargo.exe')) `
    -CommandNames @('cargo.exe', 'cargo') `
    -RelativeExecutable 'cargo.exe'

$env:CARGO = $cargo
$env:LANZOUYOU_CORE_DIR = $coreProject
Add-PathEntry -Path (Split-Path -Parent $cargo)
$resolvedFlutterSdk = Split-Path -Parent (Split-Path -Parent $flutter)
$env:FLUTTER_ROOT = $resolvedFlutterSdk
$env:FLUTTER_HOME = $resolvedFlutterSdk
[void](Assert-UnderCanonicalSdkRoot -Path $flutter -DisplayName 'Flutter SDK')
[void](Assert-UnderCanonicalSdkRoot -Path $cargo -DisplayName 'Cargo')

$resolvedJavaHome = if ($JavaHome) { $JavaHome } else { $defaultJavaHome }
if (-not (Test-Path -LiteralPath (Join-Path $resolvedJavaHome 'bin\java.exe') -PathType Leaf)) {
    throw "JavaHome does not contain bin\java.exe: $resolvedJavaHome"
}
$env:JAVA_HOME = Assert-UnderCanonicalSdkRoot `
    -Path (Resolve-Path -LiteralPath $resolvedJavaHome).Path `
    -DisplayName 'JAVA_HOME'
Add-PathEntry -Path (Join-Path $env:JAVA_HOME 'bin')

$androidAapt2 = $null
$androidZipalign = $null
if (-not $SkipAndroid) {
    $sdkCandidates = @($AndroidSdkPath, $defaultAndroidSdk)
    $sdk = $sdkCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -First 1
    if (-not $sdk) {
        throw 'Android SDK was not found. Pass -AndroidSdkPath or configure ANDROID_SDK_ROOT.'
    }
    $sdk = Assert-UnderCanonicalSdkRoot `
        -Path (Resolve-Path -LiteralPath $sdk).Path `
        -DisplayName 'Android SDK'
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
    Add-PathEntry -Path (Join-Path $sdk 'platform-tools')
    Sync-FlutterLocalProperties -AndroidSdk $sdk -FlutterSdk $resolvedFlutterSdk
    Sync-FlutterToolConfiguration `
        -FlutterCommand $flutter `
        -AndroidSdk $sdk `
        -JavaHome $env:JAVA_HOME
    $androidAapt2 = Resolve-AndroidBuildTool -SdkRoot $sdk -ToolName 'aapt2'
    $androidZipalign = Resolve-AndroidBuildTool -SdkRoot $sdk -ToolName 'zipalign'
}

Write-Host "SdkRoot: $standardSdkRoot"
Write-Host "ShellProject: $shellProject"
Write-Host "CoreProject: $coreProject"
Write-Host "FlutterCommand: $flutter"
Write-Host "CargoCommand: $cargo"
Write-Host "JavaHome: $env:JAVA_HOME"
Write-Host "GradleUserHome: $env:GRADLE_USER_HOME"
Write-Host "PubCache: $env:PUB_CACHE"
Write-Host "CargoHome: $env:CARGO_HOME"
Write-Host "CargoTargetDir: $env:CARGO_TARGET_DIR"
Write-Host "RustupHome: $env:RUSTUP_HOME"
Write-Host "NuGetPackages: $env:NUGET_PACKAGES"
Write-Host "BuildTemp: $env:TEMP"
Write-Host "AndroidUserHome: $env:ANDROID_USER_HOME"
Write-Host "CmakeHome: $defaultCmakeHome"
if ($EnvironmentCheck) {
    $dart = Join-Path $resolvedFlutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
    $rustup = Join-Path (Split-Path -Parent $cargo) 'rustup.exe'
    $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
    $adb = Join-Path $sdk 'platform-tools\adb.exe'
    $flutterVersion = Invoke-VersionProbe -Label 'Flutter' -FilePath $flutter -Arguments @('--version')
    $dartVersion = Invoke-VersionProbe -Label 'Dart' -FilePath $dart -Arguments @('--version')
    $cargoVersion = Invoke-VersionProbe -Label 'Cargo' -FilePath $cargo -Arguments @('--version')
    $rustupVersion = Invoke-VersionProbe -Label 'Rustup' -FilePath $rustup -Arguments @('show', 'active-toolchain')
    $javaVersion = Invoke-VersionProbe -Label 'Java' -FilePath $java -Arguments @('-version')
    $adbVersion = Invoke-VersionProbe -Label 'Adb' -FilePath $adb -Arguments @('version')
    if ($cargoVersion -notmatch '^cargo\s+\d') {
        throw "Cargo proxy identity check failed: $cargoVersion"
    }
    Write-Host "FlutterPhysical: $(Assert-UnderCanonicalSdkRoot -Path $flutter -DisplayName 'Flutter' -ReturnPhysical)"
    Write-Host "CargoPhysical: $(Assert-UnderCanonicalSdkRoot -Path $cargo -DisplayName 'Cargo' -ReturnPhysical)"
    Invoke-WindowsToolchainPreflight
    Write-Host 'EnvironmentCheck: pass (including Windows toolchain)'
    exit 0
}

if (-not $SkipWindows) {
    Invoke-WindowsToolchainPreflight
}
$runId = [guid]::NewGuid().ToString('N')
$runStageRoot = Join-Path $stageParent $runId
$stagedAssets = Join-Path $runStageRoot 'embedded-assets'
$stagedRelease = Join-Path $runStageRoot 'release-generation'
New-Item -ItemType Directory -Path $stagedAssets -Force | Out-Null
$releaseGeneration = $null
$published = $false

Write-Host "RunId: $runId"

try {
    if ($SkipAndroid -or $SkipWindows) {
        [void](Read-LanzouTemplateSet -RootPath $assetDirectory)
        $preservedTarget = if ($SkipAndroid) { 'android' } else { 'windows' }
        $preservedName = Get-LanzouTemplateFileName -Target $preservedTarget
        Copy-Item `
            -LiteralPath (Join-Path $assetDirectory $preservedName) `
            -Destination (Join-Path $stagedAssets $preservedName)
        Write-Host "PreservedTemplate: $preservedTarget (verified current generation)"
    }
    Push-Location $shellProject
    try {
        Write-Step -Message 'Resolve shell dependencies.'
        Invoke-Checked -FilePath $flutter -ArgumentList @('pub', 'get')

        if (-not $SkipAndroid) {
            Write-Step -Message 'Build and stage the maintainer Android shell template.'
            Invoke-Checked -FilePath $flutter -ArgumentList @(
                'build', 'apk', '--release',
                '--target-platform', 'android-arm64,android-x64'
            )
            $sourceApk = Join-Path $shellProject 'build\app\outputs\flutter-apk\app-release.apk'
            Assert-AndroidReleaseArchive -Archive $sourceApk
            Assert-AndroidReleaseManifest -Archive $sourceApk -Aapt2Path $androidAapt2
            [void](Invoke-Captured `
                -FilePath $androidZipalign `
                -ArgumentList @('-c', '-P', '16', '-v', '4', $sourceApk))
            Write-Host 'AndroidReleaseContract: release/AOT, non-debuggable, hardware-accelerated, no renderer override, arm64-v8a+x86_64, 16-KiB aligned'
            Copy-Item `
                -LiteralPath $sourceApk `
                -Destination (Join-Path $stagedAssets (Get-LanzouTemplateFileName -Target 'android'))
        }

        if (-not $SkipWindows) {
            Write-Step -Message 'Build and stage the maintainer Windows shell template.'
            Invoke-Checked -FilePath $flutter -ArgumentList @('build', 'windows', '--release')
            $bundle = Join-Path $shellProject 'build\windows\x64\runner\Release'
            foreach ($required in @(
                (Join-Path $bundle 'lanzou_library_shell.exe'),
                (Join-Path $bundle 'lanzouyou_core.dll'),
                (Join-Path $bundle 'data\flutter_assets\assets\runtime\library.json'),
                (Join-Path $bundle 'data\flutter_assets\assets\runtime\logo.png')
            )) {
                if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
                    throw "Windows shell bundle is incomplete: $required"
                }
            }
            $windowsTemplate = Join-Path $stagedAssets (Get-LanzouTemplateFileName -Target 'windows')
            Compress-Archive `
                -Path (Join-Path $bundle '*') `
                -DestinationPath $windowsTemplate `
                -CompressionLevel Optimal
            Assert-ZipEntries -Archive $windowsTemplate -RequiredEntries @(
                'lanzou_library_shell.exe',
                'lanzouyou_core.dll',
                'data/flutter_assets/assets/runtime/library.json',
                'data/flutter_assets/assets/runtime/logo.png'
            )
        }
    }
    finally {
        Pop-Location
    }

    $artifactRecords = [Collections.Generic.List[object]]::new()
    foreach ($target in @('android', 'windows')) {
        $path = Join-Path $stagedAssets (Get-LanzouTemplateFileName -Target $target)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $artifactRecords.Add((Get-TemplateArtifactRecord -Target $target -Path $path))
        }
    }
    if ($artifactRecords.Count -ne 2) {
        throw 'Embedded template publication requires exactly two artifacts.'
    }
    $manifest = New-LanzouTemplateManifest -RunId $runId -Artifacts @($artifactRecords)
    Write-LanzouUtf8JsonFile `
        -Path (Join-Path $stagedAssets 'templates-manifest.json') `
        -Value $manifest
    [void](Read-LanzouTemplateSet -RootPath $stagedAssets)

    Copy-Item -LiteralPath $stagedAssets -Destination $stagedRelease -Recurse
    [void](Read-LanzouTemplateSet -RootPath $stagedRelease)

    Write-Step -Message 'Publish the immutable release generation.'
    $releaseGeneration = Publish-ReleaseGeneration `
        -CandidateDirectory $stagedRelease `
        -RunId $runId

    try {
        Write-Step -Message 'Atomically activate the embedded template generation.'
        Publish-EmbeddedTemplateGeneration `
            -CandidateDirectory $stagedAssets `
            -DestinationDirectory $assetDirectory `
            -RunId $runId
        $published = $true
    }
    catch {
        if ($releaseGeneration -and (Test-Path -LiteralPath $releaseGeneration -PathType Container)) {
            Remove-Item -LiteralPath $releaseGeneration -Recurse -Force
        }
        throw
    }

    $active = Read-LanzouTemplateSet -RootPath $assetDirectory
    Write-Step -Message 'Remove obsolete root-level release compatibility entries.'
    [void](Remove-LegacyReleaseEntrypoints `
        -RootPath $releaseRoot `
        -ExpectedRootPath $releaseRoot `
        -PublishedGenerationPath $releaseGeneration)
    Write-Step -Message 'Template preparation completed.'
    foreach ($record in $active.Records) {
        Write-Host ('Artifact: {0} | Bytes: {1} | SHA256: {2}' -f $record.File, $record.Bytes, $record.Sha256)
    }
    Write-Host "Generation: $($active.RunId)"
    Write-Host "EmbeddedAssets: $assetDirectory"
    Write-Host "ReleaseGeneration: $releaseGeneration"
}
finally {
    if (Test-Path -LiteralPath $runStageRoot -PathType Container) {
        Remove-Item -LiteralPath $runStageRoot -Recurse -Force
    }
    if (-not $published -and $releaseGeneration -and
        (Test-Path -LiteralPath $releaseGeneration -PathType Container)) {
        Remove-Item -LiteralPath $releaseGeneration -Recurse -Force
    }
}
