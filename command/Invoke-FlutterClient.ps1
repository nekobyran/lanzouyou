[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet(
        'Analyze',
        'Test',
        'PubGet',
        'EnvironmentCheck',
        'WindowsToolchainCheck',
        'BuildAndroidDebug',
        'BuildAndroidRelease',
        'BuildWindowsDebug',
        'BuildWindowsRelease',
        'BuildAllDebug',
        'InstallAndroidDebug',
        'LaunchAndroidDebug',
        'BuildInstallAndroidDebug',
        'RunWindowsDebug',
        'BuildRunWindowsDebug'
    )]
    [string]$Action = 'BuildAllDebug',

    [string]$Serial,
    [string]$ApkPath,
    [string]$ExePath,
    [string]$SdkRoot,
    [string]$FlutterSdkPath,
    [string]$AndroidSdkPath,
    [string]$JavaHome,
    [string]$GradleUserHome,
    [string]$CargoPath,
    [string]$CargoHome,
    [string]$RustupHome,
    [string]$PubCache,
    [string]$NuGetPackages,
    [string]$TempPath,
    [ValidateRange(1, 60)]
    [int]$LaunchWaitSeconds = 3,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceDriveRoot = [IO.Path]::GetPathRoot($projectRoot)
$canonicalSdkRoot = [IO.Path]::GetFullPath((Join-Path $workspaceDriveRoot 'vibecoding\sdk'))
$standardSdkRoot = [IO.Path]::GetFullPath($(if ($SdkRoot) { $SdkRoot } else { $canonicalSdkRoot }))
if (-not $standardSdkRoot.Equals($canonicalSdkRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "SdkRoot must use the canonical workspace SDK root: $canonicalSdkRoot"
}
$systemDriveRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
if ($systemDriveRoot -and
    [IO.Path]::GetPathRoot($standardSdkRoot).Equals(
        $systemDriveRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "SDK root must not use the system drive: $standardSdkRoot"
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
$defaultVisualStudioRoot = Join-Path $standardSdkRoot 'visual-studio-build-tools'
$defaultWindowsSdkRoot = Join-Path $standardSdkRoot 'windows-sdk'
$defaultPortableVswhereProgramFilesX86 = Join-Path $standardSdkRoot `
    'tool-shims\portable-vswhere\ProgramFilesX86'
$defaultPortableVswhere = Join-Path $defaultPortableVswhereProgramFilesX86 `
    'Microsoft Visual Studio\Installer\vswhere.exe'
$flutterProject = Join-Path $projectRoot 'project\LanzouYOU'
$defaultCargoTargetDir = Join-Path $flutterProject 'native\lanzouyou_core\target'
$androidDirectory = Join-Path $flutterProject 'android'
$androidLocalProperties = Join-Path $androidDirectory 'local.properties'
$releaseRoot = Join-Path $projectRoot 'release'
$androidPackage = 'cc.nkbr.lanzouyou'
$windowsExeName = 'lanzouyou.exe'
$script:flutterCommand = $null
$script:androidSdk = $null
$script:cargoCommand = $null
$script:rustToolchain = $null
$script:windowsToolchain = $null

if (-not (Test-Path -LiteralPath $flutterProject -PathType Container)) {
    throw "LanzouYOU Flutter project was not found: $flutterProject"
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Add-PathEntry {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    $entries = @($env:PATH -split [IO.Path]::PathSeparator)
    if ($entries -notcontains $Path) {
        $env:PATH = $Path + [IO.Path]::PathSeparator + $env:PATH
    }
}

function Test-CanonicalSdkContainment {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = $standardSdkRoot.TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    return $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-UnderCanonicalSdkRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayName,
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
    if ($ReturnPhysical) {
        return [IO.Path]::GetFullPath($physical)
    }
    return $full
}

function Resolve-FlutterCommand {
    $candidate = if ($FlutterSdkPath) { $FlutterSdkPath } else { $defaultFlutterSdk }
    $path = $candidate
    if (Test-Path -LiteralPath $path -PathType Container) {
        $path = Join-Path $path 'bin\flutter.bat'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Flutter SDK was not found at the canonical path: $candidate"
    }
    $resolved = Assert-UnderCanonicalSdkRoot `
        -Path (Resolve-Path -LiteralPath $path).Path `
        -DisplayName 'Flutter SDK'
    Add-PathEntry -Path (Split-Path -Parent $resolved)
    return $resolved
}

function Resolve-AndroidSdk {
    $candidate = if ($AndroidSdkPath) { $AndroidSdkPath } else { $defaultAndroidSdk }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "Android SDK was not found at the canonical path: $candidate"
    }
    return (Assert-UnderCanonicalSdkRoot `
        -Path (Resolve-Path -LiteralPath $candidate).Path `
        -DisplayName 'Android SDK')
}

function Resolve-CargoCommand {
    $candidate = if ($CargoPath) {
        $CargoPath
    } else {
        Join-Path $env:CARGO_HOME 'bin\cargo.exe'
    }
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        foreach ($relative in @('bin\cargo.exe', 'cargo.exe')) {
            $nested = Join-Path $candidate $relative
            if (Test-Path -LiteralPath $nested -PathType Leaf) {
                $candidate = $nested
                break
            }
        }
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Cargo was not found at the canonical path: $candidate"
    }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    [void](Assert-UnderCanonicalSdkRoot -Path $resolved -DisplayName 'Cargo')
    Add-PathEntry -Path (Split-Path -Parent $resolved)
    return $resolved
}

function Resolve-RustToolchain {
    $toolchainsRoot = Join-Path $env:RUSTUP_HOME 'toolchains'
    if (-not (Test-Path -LiteralPath $toolchainsRoot -PathType Container)) {
        throw "Rust toolchains directory is missing: $toolchainsRoot"
    }
    $directories = @(
        Get-ChildItem -LiteralPath $toolchainsRoot -Directory -ErrorAction Stop |
            Sort-Object @{ Expression = { if ($_.Name -like 'stable-*') { 0 } else { 1 } } }, Name
    )
    foreach ($directory in $directories) {
        $rustc = Join-Path $directory.FullName 'bin\rustc.exe'
        $rustdoc = Join-Path $directory.FullName 'bin\rustdoc.exe'
        if (-not (Test-Path -LiteralPath $rustc -PathType Leaf) -or
            -not (Test-Path -LiteralPath $rustdoc -PathType Leaf)) {
            continue
        }
        $rustlibRoot = Join-Path $directory.FullName 'lib\rustlib'
        $hostDirectory = Get-ChildItem -LiteralPath $rustlibRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match 'windows' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'lib') -PathType Container)
            } |
            Sort-Object Name |
            Select-Object -First 1
        if (-not $hostDirectory) {
            continue
        }
        $hostTuple = $hostDirectory.Name
        $hostLib = Join-Path $hostDirectory.FullName 'lib'
        if (-not (Test-Path -LiteralPath $hostLib -PathType Container)) {
            continue
        }
        return [pscustomobject]@{
            Root = $directory.FullName
            Bin = Join-Path $directory.FullName 'bin'
            Rustc = $rustc
            Rustdoc = $rustdoc
            Host = $hostTuple
        }
    }
    throw "No complete Rust toolchain was found under $toolchainsRoot"
}

function Set-JavaEnvironment {
    $resolvedJavaHome = if ($JavaHome) { $JavaHome } else { $defaultJavaHome }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedJavaHome 'bin\java.exe') -PathType Leaf)) {
        throw "JAVA_HOME does not contain bin\\java.exe: $resolvedJavaHome"
    }
    $env:JAVA_HOME = Assert-UnderCanonicalSdkRoot `
        -Path (Resolve-Path -LiteralPath $resolvedJavaHome).Path `
        -DisplayName 'JAVA_HOME'
    Add-PathEntry -Path (Join-Path $env:JAVA_HOME 'bin')
}

function Resolve-BuildCacheDirectory {
    param(
        [string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$DefaultPath,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )
    $selected = if ($RequestedPath) { $RequestedPath } else { $DefaultPath }
    [void](Assert-UnderCanonicalSdkRoot -Path $selected -DisplayName $DisplayName)
    New-Item -ItemType Directory -Force -Path $selected | Out-Null
    return (Assert-UnderCanonicalSdkRoot `
        -Path (Resolve-Path -LiteralPath $selected).Path `
        -DisplayName $DisplayName)
}

function Set-BuildCacheEnvironment {
    $env:CARGO_HOME = Resolve-BuildCacheDirectory `
        -RequestedPath $CargoHome -DefaultPath $defaultCargoHome -DisplayName 'CARGO_HOME'
    $env:RUSTUP_HOME = Resolve-BuildCacheDirectory `
        -RequestedPath $RustupHome -DefaultPath $defaultRustupHome -DisplayName 'RUSTUP_HOME'
    $env:PUB_CACHE = Resolve-BuildCacheDirectory `
        -RequestedPath $PubCache -DefaultPath $defaultPubCache -DisplayName 'PUB_CACHE'
    $env:GRADLE_USER_HOME = Resolve-BuildCacheDirectory `
        -RequestedPath $GradleUserHome -DefaultPath $defaultGradleUserHome -DisplayName 'GRADLE_USER_HOME'
    $env:NUGET_PACKAGES = Resolve-BuildCacheDirectory `
        -RequestedPath $NuGetPackages -DefaultPath $defaultNuGetPackages -DisplayName 'NUGET_PACKAGES'
    $resolvedTemp = Resolve-BuildCacheDirectory `
        -RequestedPath $TempPath -DefaultPath $defaultTempPath -DisplayName 'Build TEMP'
    $env:TEMP = $resolvedTemp
    $env:TMP = $resolvedTemp
    $env:TMPDIR = $resolvedTemp
    $env:ANDROID_USER_HOME = Resolve-BuildCacheDirectory `
        -DefaultPath $defaultAndroidUserHome -DisplayName 'ANDROID_USER_HOME'
    $env:LOCALAPPDATA = Resolve-BuildCacheDirectory `
        -DefaultPath (Join-Path $standardSdkRoot 'cache\localappdata') -DisplayName 'LOCALAPPDATA'
    $cargoTarget = [IO.Path]::GetFullPath($defaultCargoTargetDir)
    $projectPrefix = $projectRoot.TrimEnd('\') + '\'
    if (-not $cargoTarget.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CARGO_TARGET_DIR escaped the D-drive project root: $cargoTarget"
    }
    New-Item -ItemType Directory -Force -Path $cargoTarget | Out-Null
    $env:CARGO_TARGET_DIR = (Resolve-Path -LiteralPath $cargoTarget).Path
    # The shared Windows host can run several Flutter/Rust tasks at once.
    # A single Cargo codegen job avoids Win32 page-file exhaustion (1455)
    # without reducing the runtime concurrency of the produced Rust core.
    $env:CARGO_BUILD_JOBS = '1'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DART_SUPPRESS_ANALYTICS = 'true'
}

function Sync-AndroidLocalProperties {
    $flutterSdk = Split-Path -Parent (Split-Path -Parent $script:flutterCommand)
    $escape = {
        param([string]$Value)
        $Value.Replace('\', '\\')
    }
    $preserved = if (Test-Path -LiteralPath $androidLocalProperties -PathType Leaf) {
        @(Get-Content -LiteralPath $androidLocalProperties -Encoding utf8 |
            Where-Object { $_ -notmatch '^\s*(sdk\.dir|flutter\.sdk)\s*=' })
    } else {
        @()
    }
    $content = @(
        ('sdk.dir=' + (& $escape $script:androidSdk)),
        ('flutter.sdk=' + (& $escape $flutterSdk))
    ) + $preserved
    [IO.File]::WriteAllLines($androidLocalProperties, $content, [Text.UTF8Encoding]::new($false))
}

function Sync-FlutterToolConfiguration {
    $syncResult = Invoke-FlutterChecked -Arguments @(
        'config',
        '--jdk-dir', $env:JAVA_HOME,
        '--android-sdk', $script:androidSdk
    ) -FailureMessage 'Flutter SDK/JDK configuration sync failed.' -CaptureOutput
    $output = @(($syncResult.StdOut, $syncResult.StdErr) -join "`n" -split "`r?`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $settingsResult = Invoke-FlutterChecked -Arguments @('config', '--list') `
        -FailureMessage 'Flutter configuration verification failed.' -CaptureOutput
    $settings = @((($settingsResult.StdOut, $settingsResult.StdErr) -join "`n") -split "`r?`n" |
        ForEach-Object { "$_" } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $androidSetting = @($settings | Where-Object { $_ -match '^\s*android-sdk:' })
    $javaSetting = @($settings | Where-Object { $_ -match '^\s*jdk-dir:' })
    if ($androidSetting.Count -ne 1 -or
        $androidSetting[0].Trim() -cne "android-sdk: $script:androidSdk" -or
        $javaSetting.Count -ne 1 -or
        $javaSetting[0].Trim() -cne "jdk-dir: $env:JAVA_HOME") {
        throw "Flutter persisted Android SDK/JDK configuration is not canonical. Output=$($output -join ' '; $settings -join ' ')"
    }
    Write-Host 'FlutterToolConfiguration: canonical'
}

function Initialize-Tools {
    param([switch]$RequireAndroid)
    Set-BuildCacheEnvironment
    $script:flutterCommand = Resolve-FlutterCommand
    $resolvedFlutterSdk = Split-Path -Parent (Split-Path -Parent $script:flutterCommand)
    $env:FLUTTER_ROOT = $resolvedFlutterSdk
    $env:FLUTTER_HOME = $resolvedFlutterSdk
    $script:cargoCommand = Resolve-CargoCommand
    $env:CARGO = $script:cargoCommand
    Add-PathEntry -Path (Split-Path -Parent $script:cargoCommand)
    $script:rustToolchain = Resolve-RustToolchain
    $env:RUSTC = $script:rustToolchain.Rustc
    $env:RUSTDOC = $script:rustToolchain.Rustdoc
    Add-PathEntry -Path $script:rustToolchain.Bin
    Set-JavaEnvironment
    if (-not (Test-Path -LiteralPath (Join-Path $defaultCmakeHome 'bin\cmake.exe') -PathType Leaf)) {
        throw "Canonical CMake is missing: $defaultCmakeHome"
    }
    [void](Assert-UnderCanonicalSdkRoot -Path $defaultCmakeHome -DisplayName 'CMake home')
    Add-PathEntry -Path (Join-Path $defaultCmakeHome 'bin')
    if ($RequireAndroid) {
        $script:androidSdk = Resolve-AndroidSdk
        $env:ANDROID_HOME = $script:androidSdk
        $env:ANDROID_SDK_ROOT = $script:androidSdk
        Add-PathEntry -Path (Join-Path $script:androidSdk 'platform-tools')
        Sync-AndroidLocalProperties
        Sync-FlutterToolConfiguration
    }
    Write-Host "SdkRoot: $standardSdkRoot"
    Write-Host "FlutterCommand: $script:flutterCommand"
    Write-Host "CargoCommand: $script:cargoCommand"
    Write-Host "RustcCommand: $($script:rustToolchain.Rustc)"
    if ($RequireAndroid) {
        Write-Host "AndroidSdk: $script:androidSdk"
    }
    if ($env:JAVA_HOME) {
        Write-Host "JavaHome: $env:JAVA_HOME"
    }
    Write-Host "GradleUserHome: $env:GRADLE_USER_HOME"
    Write-Host "PubCache: $env:PUB_CACHE"
    Write-Host "CargoHome: $env:CARGO_HOME"
    Write-Host "CargoTargetDir: $env:CARGO_TARGET_DIR"
    Write-Host "CargoBuildJobs: $env:CARGO_BUILD_JOBS"
    Write-Host "RustupHome: $env:RUSTUP_HOME"
    Write-Host "NuGetPackages: $env:NUGET_PACKAGES"
    Write-Host "BuildTemp: $env:TEMP"
    Write-Host "AndroidUserHome: $env:ANDROID_USER_HOME"
    Write-Host "CmakeHome: $defaultCmakeHome"
}

function Invoke-VersionProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
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

function Invoke-EnvironmentCheck {
    $flutterSdk = Split-Path -Parent (Split-Path -Parent $script:flutterCommand)
    $dart = Join-Path $flutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
    $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
    $adb = Join-Path $script:androidSdk 'platform-tools\adb.exe'

    $flutterVersion = Invoke-VersionProbe -Label 'Flutter' -FilePath $script:flutterCommand -Arguments @('--version')
    $dartVersion = Invoke-VersionProbe -Label 'Dart' -FilePath $dart -Arguments @('--version')
    $cargoVersion = Invoke-VersionProbe -Label 'Cargo' -FilePath $script:cargoCommand -Arguments @('--version')
    $rustcVersion = Invoke-VersionProbe -Label 'Rustc' -FilePath $script:rustToolchain.Rustc -Arguments @('--version')
    $javaVersion = Invoke-VersionProbe -Label 'Java' -FilePath $java -Arguments @('-version')
    $adbVersion = Invoke-VersionProbe -Label 'Adb' -FilePath $adb -Arguments @('version')
    if ($cargoVersion -notmatch '^cargo\s+\d') {
        throw "Cargo proxy identity check failed: $cargoVersion"
    }
    if ($rustcVersion -notmatch '^rustc\s+\d') {
        throw "Rustc identity check failed: $rustcVersion"
    }

    Write-Host "SdkRootPhysical: $(Assert-UnderCanonicalSdkRoot -Path $standardSdkRoot -DisplayName 'SDK root' -ReturnPhysical)"
    Write-Host "FlutterPhysical: $(Assert-UnderCanonicalSdkRoot -Path $script:flutterCommand -DisplayName 'Flutter' -ReturnPhysical)"
    Write-Host "CargoPhysical: $(Assert-UnderCanonicalSdkRoot -Path $script:cargoCommand -DisplayName 'Cargo' -ReturnPhysical)"
    Write-Host "RustcPhysical: $(Assert-UnderCanonicalSdkRoot -Path $script:rustToolchain.Rustc -DisplayName 'Rustc' -ReturnPhysical)"
    Write-Host "JavaPhysical: $(Assert-UnderCanonicalSdkRoot -Path $java -DisplayName 'Java' -ReturnPhysical)"
    Write-Host "AdbPhysical: $(Assert-UnderCanonicalSdkRoot -Path $adb -DisplayName 'Adb' -ReturnPhysical)"
}

function Resolve-WindowsToolchainLayout {
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'Visual Studio Build Tools'; Path = $defaultVisualStudioRoot },
        [pscustomobject]@{ Name = 'Windows SDK'; Path = $defaultWindowsSdkRoot }
    )) {
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Container)) {
            throw "$($entry.Name) was not found at the canonical path: $($entry.Path)"
        }
        [void](Assert-UnderCanonicalSdkRoot -Path $entry.Path -DisplayName $entry.Name)
    }

    $msvcVersionFile = Join-Path $defaultVisualStudioRoot `
        'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    if (-not (Test-Path -LiteralPath $msvcVersionFile -PathType Leaf)) {
        throw "Canonical MSVC version marker is missing: $msvcVersionFile"
    }
    $msvcVersion = (Get-Content -LiteralPath $msvcVersionFile -Encoding ascii -Raw).Trim()
    if ($msvcVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Canonical MSVC version marker is invalid: $msvcVersion"
    }
    $msvcRoot = Join-Path $defaultVisualStudioRoot "VC\Tools\MSVC\$msvcVersion"

    $msbuild = Join-Path $defaultVisualStudioRoot 'MSBuild\Current\Bin\MSBuild.exe'
    $cmake = Join-Path $defaultVisualStudioRoot `
        'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    $ninja = Join-Path $defaultVisualStudioRoot `
        'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
    $cl = Join-Path $msvcRoot 'bin\Hostx64\x64\cl.exe'
    $link = Join-Path $msvcRoot 'bin\Hostx64\x64\link.exe'
    $lib = Join-Path $msvcRoot 'bin\Hostx64\x64\lib.exe'

    $sdkVersions = @(
        Get-ChildItem -LiteralPath (Join-Path $defaultWindowsSdkRoot 'Include') `
            -Directory -ErrorAction Stop |
            Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending
    )
    $windowsSdkVersion = $null
    foreach ($candidate in $sdkVersions) {
        $version = $candidate.Name
        $required = @(
            (Join-Path $candidate.FullName 'um\windows.h'),
            (Join-Path $candidate.FullName 'ucrt\stdio.h'),
            (Join-Path $defaultWindowsSdkRoot "Lib\$version\um\x64\kernel32.lib"),
            (Join-Path $defaultWindowsSdkRoot "Lib\$version\ucrt\x64\ucrt.lib"),
            (Join-Path $defaultWindowsSdkRoot "bin\$version\x64\rc.exe"),
            (Join-Path $defaultWindowsSdkRoot "bin\$version\x64\mt.exe")
        )
        if (@($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) {
            $windowsSdkVersion = $version
            break
        }
    }
    if (-not $windowsSdkVersion) {
        throw "No complete x64 Windows SDK was found under: $defaultWindowsSdkRoot"
    }

    $msbuildVersion = (Get-Item -LiteralPath $msbuild -ErrorAction Stop).VersionInfo.FileVersion
    if ($msbuildVersion -notmatch '^17\.') {
        throw "Unsupported canonical Visual Studio/MSBuild version: $msbuildVersion"
    }

    $layout = [pscustomobject]@{
        VisualStudioRoot = $defaultVisualStudioRoot
        VisualStudioVersion = $msbuildVersion
        MsvcRoot = $msvcRoot
        MsvcVersion = $msvcVersion
        WindowsSdkRoot = $defaultWindowsSdkRoot
        WindowsSdkVersion = $windowsSdkVersion
        PortableProgramFilesX86 = $defaultPortableVswhereProgramFilesX86
        Vswhere = $defaultPortableVswhere
        Msbuild = $msbuild
        Cmake = $cmake
        Ninja = $ninja
        Cl = $cl
        Link = $link
        Lib = $lib
        Rc = Join-Path $defaultWindowsSdkRoot "bin\$windowsSdkVersion\x64\rc.exe"
        Mt = Join-Path $defaultWindowsSdkRoot "bin\$windowsSdkVersion\x64\mt.exe"
    }

    foreach ($property in @(
        'Vswhere', 'Msbuild', 'Cmake', 'Ninja', 'Cl', 'Link', 'Lib', 'Rc', 'Mt'
    )) {
        $path = $layout.$property
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Canonical Windows toolchain file is missing: $property=$path"
        }
        [void](Assert-UnderCanonicalSdkRoot `
            -Path (Resolve-Path -LiteralPath $path).Path `
            -DisplayName "Windows toolchain $property")
    }
    return $layout
}

function Set-WindowsToolchainEnvironment {
    $layout = Resolve-WindowsToolchainLayout
    $script:windowsToolchain = $layout
    $sdkVersion = $layout.WindowsSdkVersion

    $env:VSINSTALLDIR = $layout.VisualStudioRoot.TrimEnd('\') + '\'
    $env:VCINSTALLDIR = (Join-Path $layout.VisualStudioRoot 'VC').TrimEnd('\') + '\'
    $env:VCToolsInstallDir = $layout.MsvcRoot.TrimEnd('\') + '\'
    $env:VCToolsVersion = $layout.MsvcVersion
    $env:VisualStudioVersion = '17.0'
    $env:DevEnvDir = (Join-Path $layout.VisualStudioRoot 'Common7\IDE').TrimEnd('\') + '\'
    $env:WindowsSdkDir = $layout.WindowsSdkRoot.TrimEnd('\') + '\'
    $env:WindowsSDKVersion = "$sdkVersion\"
    $env:WindowsSDKLibVersion = "$sdkVersion\"
    $env:UniversalCRTSdkDir = $env:WindowsSdkDir
    $env:UCRTVersion = $sdkVersion
    $env:Platform = 'x64'
    $env:VSCMD_ARG_HOST_ARCH = 'x64'
    $env:VSCMD_ARG_TGT_ARCH = 'x64'
    $env:PreferredToolArchitecture = 'x64'
    $env:NEKOSTAR_VS_BUILD_VERSION = $layout.VisualStudioVersion
    $env:CMAKE_GENERATOR = 'Visual Studio 17 2022'
    $env:CMAKE_GENERATOR_INSTANCE = ('{0},version={1}' -f `
        $layout.VisualStudioRoot.Replace('\', '/'),
        $layout.VisualStudioVersion)
    [Environment]::SetEnvironmentVariable(
        'ProgramFiles(x86)',
        $layout.PortableProgramFilesX86,
        [EnvironmentVariableTarget]::Process
    )

    $env:INCLUDE = @(
        (Join-Path $layout.MsvcRoot 'include'),
        (Join-Path $layout.WindowsSdkRoot "Include\$sdkVersion\ucrt"),
        (Join-Path $layout.WindowsSdkRoot "Include\$sdkVersion\shared"),
        (Join-Path $layout.WindowsSdkRoot "Include\$sdkVersion\um"),
        (Join-Path $layout.WindowsSdkRoot "Include\$sdkVersion\winrt"),
        (Join-Path $layout.WindowsSdkRoot "Include\$sdkVersion\cppwinrt")
    ) -join ';'
    $env:LIB = @(
        (Join-Path $layout.MsvcRoot 'lib\x64'),
        (Join-Path $layout.WindowsSdkRoot "Lib\$sdkVersion\ucrt\x64"),
        (Join-Path $layout.WindowsSdkRoot "Lib\$sdkVersion\um\x64")
    ) -join ';'
    $env:LIBPATH = @(
        (Join-Path $layout.MsvcRoot 'lib\x64'),
        (Join-Path $layout.WindowsSdkRoot "UnionMetadata\$sdkVersion"),
        (Join-Path $layout.WindowsSdkRoot "References\$sdkVersion")
    ) -join ';'

    foreach ($path in @(
        (Split-Path -Parent $layout.Cl),
        (Split-Path -Parent $layout.Msbuild),
        (Split-Path -Parent $layout.Cmake),
        (Split-Path -Parent $layout.Ninja),
        (Split-Path -Parent $layout.Rc)
    )) {
        Add-PathEntry -Path $path
    }
}

function Get-WindowsToolchainCandidates {
    if (-not $script:windowsToolchain) {
        throw 'Canonical Windows toolchain environment was not initialized.'
    }
    return @(
        [pscustomobject]@{ Name = 'VisualStudio'; Path = $script:windowsToolchain.VisualStudioRoot },
        [pscustomobject]@{ Name = 'WindowsSdk'; Path = $script:windowsToolchain.WindowsSdkRoot },
        [pscustomobject]@{ Name = 'vswhere.exe'; Path = $script:windowsToolchain.Vswhere },
        [pscustomobject]@{ Name = 'MSBuild.exe'; Path = $script:windowsToolchain.Msbuild },
        [pscustomobject]@{ Name = 'cmake.exe'; Path = $script:windowsToolchain.Cmake },
        [pscustomobject]@{ Name = 'ninja.exe'; Path = $script:windowsToolchain.Ninja },
        [pscustomobject]@{ Name = 'cl.exe'; Path = $script:windowsToolchain.Cl },
        [pscustomobject]@{ Name = 'rc.exe'; Path = $script:windowsToolchain.Rc }
    )
}

function Invoke-WindowsToolchainSmoke {
    $probeBase = [IO.Path]::GetFullPath((Join-Path `
        $standardSdkRoot 'cache\toolchain-probe'))
    [void](Assert-UnderCanonicalSdkRoot `
        -Path $probeBase `
        -DisplayName 'Windows toolchain probe cache')
    New-Item -ItemType Directory -Force -Path $probeBase | Out-Null
    $probeRoot = [IO.Path]::GetFullPath((Join-Path `
        $probeBase ("lanzouyou-{0}-{1}" -f $PID, [guid]::NewGuid().ToString('N'))))
    if (-not $probeRoot.StartsWith(
        $probeBase.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Windows toolchain probe escaped its cache root: $probeRoot"
    }
    [void](Assert-UnderCanonicalSdkRoot `
        -Path $probeRoot `
        -DisplayName 'Windows toolchain probe')

    $source = Join-Path $probeRoot 'src'
    $build = Join-Path $probeRoot 'build'
    New-Item -ItemType Directory -Force -Path $source,$build | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $source 'CMakeLists.txt'),
        @'
cmake_minimum_required(VERSION 3.20)
project(canonical_toolchain_probe LANGUAGES CXX)
add_executable(canonical_toolchain_probe main.cpp app.rc)
'@,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $source 'main.cpp'),
        @'
#include <windows.h>
int main() { return GetCurrentProcessId() == 0 ? 1 : 0; }
'@,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $source 'app.rc'),
        @'
1 VERSIONINFO
FILEVERSION 1,0,0,0
PRODUCTVERSION 1,0,0,0
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
    END
    BLOCK "VarFileInfo"
    BEGIN
    END
END
'@,
        [Text.UTF8Encoding]::new($false)
    )

    try {
        $env:CMAKE_BUILD_PARALLEL_LEVEL = '1'
        $configureOutput = @(& $script:windowsToolchain.Cmake `
            -S $source `
            -B $build `
            -G 'Visual Studio 17 2022' `
            -A x64 `
            "-DCMAKE_GENERATOR_INSTANCE=$env:CMAKE_GENERATOR_INSTANCE" `
            "-DCMAKE_SYSTEM_VERSION=$($script:windowsToolchain.WindowsSdkVersion)" `
            "-DCMAKE_INSTALL_PREFIX=$($probeRoot.Replace('\', '/'))/install" `
            2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            throw "Canonical CMake configure probe failed. $($configureOutput -join ' ')"
        }

        $buildOutput = @(& $script:windowsToolchain.Cmake `
            --build $build --config Debug --parallel 1 `
            2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            throw "Canonical CMake build probe failed. $($buildOutput -join ' ')"
        }

        $probeExe = Join-Path $build 'Debug\canonical_toolchain_probe.exe'
        if (-not (Test-Path -LiteralPath $probeExe -PathType Leaf)) {
            throw "Canonical CMake probe executable is missing: $probeExe"
        }
        & $probeExe
        if ($LASTEXITCODE -ne 0) {
            throw "Canonical CMake probe executable failed: $LASTEXITCODE"
        }

        $cachePath = Join-Path $build 'CMakeCache.txt'
        $cache = Get-Content -LiteralPath $cachePath -Encoding utf8
        foreach ($expected in @(
            $script:windowsToolchain.VisualStudioRoot.Replace('\', '/'),
            $script:windowsToolchain.Link.Replace('\', '/'),
            $script:windowsToolchain.Rc.Replace('\', '/')
        )) {
            if (-not @($cache | Where-Object {
                $_.Replace('\', '/').Contains($expected, [StringComparison]::OrdinalIgnoreCase)
            })) {
                throw "Canonical CMake cache did not bind required toolchain path: $expected"
            }
        }
        Write-Host 'WindowsToolchainSmoke: pass'
    }
    finally {
        if (Test-Path -LiteralPath $probeRoot) {
            $resolvedProbe = [IO.Path]::GetFullPath($probeRoot)
            if (-not $resolvedProbe.StartsWith(
                $probeBase.TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "Refusing to clean a probe outside its cache root: $resolvedProbe"
            }
            Remove-Item -LiteralPath $resolvedProbe -Recurse -Force
        }
        Write-Host 'WindowsToolchainSmokeCacheCleanup: pass'
    }
}

function Invoke-WindowsToolchainPreflight {
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($entry in Get-WindowsToolchainCandidates) {
        if ([string]::IsNullOrWhiteSpace($entry.Path) -or
            -not (Test-Path -LiteralPath $entry.Path)) {
            $problems.Add("$($entry.Name)=missing")
            continue
        }
        try {
            [void](Assert-UnderCanonicalSdkRoot `
                -Path $entry.Path `
                -DisplayName "Windows toolchain $($entry.Name)")
        }
        catch {
            $problems.Add("$($entry.Name)=$($entry.Path)")
        }
    }
    if ($problems.Count -gt 0) {
        throw "Windows native build is blocked until its complete toolchain is under $standardSdkRoot. $($problems -join '; ')"
    }

    $reportedVisualStudio = (@(& $script:windowsToolchain.Vswhere `
        -latest -products * -property installationPath 2>$null) -join '').Trim().TrimEnd('\')
    if ($LASTEXITCODE -ne 0 -or
        -not $reportedVisualStudio.Equals(
            $script:windowsToolchain.VisualStudioRoot.TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Portable vswhere did not report the canonical Visual Studio root: $reportedVisualStudio"
    }

    $detailsJson = (@(& $script:windowsToolchain.Vswhere `
        -format json -products * -utf8 -latest -version 16 `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        Microsoft.VisualStudio.Component.VC.CMake.Project 2>$null) -join '')
    if ($LASTEXITCODE -ne 0) {
        throw 'Portable vswhere JSON probe failed.'
    }
    $details = @($detailsJson | ConvertFrom-Json)
    if ($details.Count -ne 1 -or
        -not "$($details[0].installationPath)".TrimEnd('\').Equals(
            $script:windowsToolchain.VisualStudioRoot.TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Portable vswhere JSON did not identify the canonical Visual Studio instance.'
    }

    Write-Host "VisualStudio: $($script:windowsToolchain.VisualStudioRoot)"
    Write-Host "VisualStudioVersion: $($script:windowsToolchain.VisualStudioVersion)"
    Write-Host "MsvcVersion: $($script:windowsToolchain.MsvcVersion)"
    Write-Host "WindowsSdk: $($script:windowsToolchain.WindowsSdkRoot)"
    Write-Host "WindowsSdkVersion: $($script:windowsToolchain.WindowsSdkVersion)"
    Write-Host "CmakeGeneratorInstance: $env:CMAKE_GENERATOR_INSTANCE"
    Write-Host "PortableVswhere: $($script:windowsToolchain.Vswhere)"
    Invoke-WindowsToolchainSmoke
    Write-Host 'WindowsToolchainCheck: pass'
}

function Ensure-AndroidRustTargets {
    $targets = @('aarch64-linux-android', 'x86_64-linux-android')
    $missing = @(
        foreach ($target in $targets) {
            $targetLib = Join-Path $script:rustToolchain.Root "lib\rustlib\$target\lib"
            $hasStandardLibrary = (Test-Path -LiteralPath $targetLib -PathType Container) -and
                (@(Get-ChildItem -LiteralPath $targetLib -Filter 'libstd-*.rlib' -File -ErrorAction SilentlyContinue).Count -gt 0)
            if (-not $hasStandardLibrary) {
                $target
            }
        }
    )
    if ($missing.Count -eq 0) {
        Write-Host "AndroidRustTargets: $($targets -join ', ')"
        return
    }

    $rustup = Join-Path (Split-Path -Parent $script:cargoCommand) 'rustup.exe'
    if (-not (Test-Path -LiteralPath $rustup -PathType Leaf)) {
        throw "Rust targets are missing ($($missing -join ', ')) and rustup is unavailable: $rustup"
    }
    $rustupIdentity = @(& $rustup --version 2>&1 | ForEach-Object { "$_" }) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or $rustupIdentity -notmatch '^rustup\s+\d') {
        throw "Rust targets are missing ($($missing -join ', ')) and the canonical rustup executable is invalid."
    }
    foreach ($target in $missing) {
        Write-Step -Message "Install Rust target $target."
        & $rustup target add $target
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install Rust target: $target"
        }
    }
}

function Invoke-FlutterChecked {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$FailureMessage = 'Flutter command failed.',
        [switch]$CaptureOutput
    )
    $commandLine = @($Arguments) + @($FlutterArgs)
    $resolvedFlutter = [IO.Path]::GetFullPath($script:flutterCommand)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    if ([IO.Path]::GetExtension($resolvedFlutter) -in @('.cmd', '.bat')) {
        $startInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        [void]$startInfo.ArgumentList.Add('/d')
        [void]$startInfo.ArgumentList.Add('/s')
        [void]$startInfo.ArgumentList.Add('/c')
        [void]$startInfo.ArgumentList.Add($resolvedFlutter)
    } else {
        $startInfo.FileName = $resolvedFlutter
    }
    foreach ($argument in $commandLine) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = [bool]$CaptureOutput
    $startInfo.WorkingDirectory = (Get-Location).Path
    if ($CaptureOutput) {
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
    }
    $childPath = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @([Environment]::SystemDirectory, (Join-Path $env:SystemRoot 'System32'))) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            $childPath.Add([IO.Path]::GetFullPath($candidate))
        }
    }
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gitCommand) { $childPath.Add((Split-Path -Parent $gitCommand.Source)) }
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwshCommand) { $childPath.Add((Split-Path -Parent $pwshCommand.Source)) }
    foreach ($entry in @($env:PATH -split [IO.Path]::PathSeparator)) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) { $childPath.Add($entry) }
    }
    $startInfo.Environment['PATH'] = (@($childPath | Select-Object -Unique) -join [IO.Path]::PathSeparator)
    $startInfo.Environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start Flutter command.' }
        $stdoutTask = if ($CaptureOutput) { $process.StandardOutput.ReadToEndAsync() } else { $null }
        $stderrTask = if ($CaptureOutput) { $process.StandardError.ReadToEndAsync() } else { $null }
        $process.WaitForExit()
        $stdout = if ($CaptureOutput) { $stdoutTask.GetAwaiter().GetResult() } else { '' }
        $stderr = if ($CaptureOutput) { $stderrTask.GetAwaiter().GetResult() } else { '' }
        if ($process.ExitCode -ne 0) {
            $detail = (@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
            if ($detail) { throw "$FailureMessage ExitCode=$($process.ExitCode) $($detail.Trim())" }
            throw "$FailureMessage ExitCode=$($process.ExitCode)"
        }
        if ($CaptureOutput) {
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                StdOut = $stdout
                StdErr = $stderr
            }
        }
    } finally {
        $process.Dispose()
    }
}

function Reset-ReleaseDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = [IO.Path]::GetFullPath($releaseRoot).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset a directory outside release root: $target"
    }
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    return $target
}

function Write-ArtifactEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName
    Write-Host "Artifact: $($item.FullName)"
    Write-Host "ArtifactBytes: $($item.Length)"
    Write-Host "ArtifactSha256: $($hash.Hash)"
}

function Build-Android {
    param([ValidateSet('debug', 'release')][string]$Mode)
    Ensure-AndroidRustTargets
    Write-Step -Message "Build Android $Mode APK with arm64-v8a and x86_64 Rust cores."
    Invoke-FlutterChecked -Arguments @(
        'build', 'apk', "--$Mode", '--target-platform', 'android-arm64,android-x64'
    ) -FailureMessage "Flutter Android $Mode build failed."
    $source = Join-Path $flutterProject "build\app\outputs\flutter-apk\app-$Mode.apk"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Android artifact was not found: $source"
    }
    $stage = Reset-ReleaseDirectory -Path (Join-Path $releaseRoot "LanzouYOU_Android\$Mode")
    $destination = Join-Path $stage "LanzouYOU-$Mode.apk"
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-ArtifactEvidence -Path $destination
    return $destination
}

function Get-WindowsBuildDirectory {
    param([ValidateSet('debug', 'release')][string]$Mode)
    $configuration = if ($Mode -eq 'debug') { 'Debug' } else { 'Release' }
    return Join-Path $flutterProject "build\windows\x64\runner\$configuration"
}

function Clear-WindowsBuildCache {
    param([Parameter(Mandatory = $true)][string]$Reason)
    $buildRoot = [IO.Path]::GetFullPath((Join-Path $flutterProject 'build'))
    $windowsBuild = [IO.Path]::GetFullPath((Join-Path $buildRoot 'windows'))
    if (-not $windowsBuild.StartsWith(
        $buildRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase
    ) -or (Split-Path -Leaf $windowsBuild) -cne 'windows') {
        throw "Refusing to clean an invalid Windows build cache path: $windowsBuild"
    }
    if (Test-Path -LiteralPath $windowsBuild) {
        Remove-Item -LiteralPath $windowsBuild -Recurse -Force
    }
    Write-Host "WindowsBuildCacheCleanup: pass ($Reason)"
}

function Build-Windows {
    param([ValidateSet('debug', 'release')][string]$Mode)
    Invoke-WindowsToolchainPreflight
    Clear-WindowsBuildCache -Reason 'canonical pre-build reset'
    Write-Step -Message "Build Windows $Mode bundle with the Rust core."
    Invoke-FlutterChecked -Arguments @('build', 'windows', "--$Mode") `
        -FailureMessage "Flutter Windows $Mode build failed."
    $sourceDirectory = Get-WindowsBuildDirectory -Mode $Mode
    $sourceExe = Join-Path $sourceDirectory $windowsExeName
    if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
        throw "Windows executable was not found: $sourceExe"
    }
    $stage = Reset-ReleaseDirectory -Path (Join-Path $releaseRoot "LanzouYOU_Windows\$Mode")
    Copy-Item -Path (Join-Path $sourceDirectory '*') -Destination $stage -Recurse -Force
    $destination = Join-Path $stage $windowsExeName
    $nativeDll = Join-Path $stage 'lanzouyou_core.dll'
    if (-not (Test-Path -LiteralPath $nativeDll -PathType Leaf)) {
        throw "Windows Rust core was not bundled: $nativeDll"
    }
    Write-ArtifactEvidence -Path $destination
    Write-ArtifactEvidence -Path $nativeDll
    Clear-WindowsBuildCache -Reason 'post-archive automatic cleanup'
    return $destination
}

function Resolve-Adb {
    $candidate = Join-Path $script:androidSdk 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    throw "adb was not found in the canonical Android SDK: $candidate"
}

function Resolve-AndroidSerial {
    param([Parameter(Mandatory = $true)][string]$Adb)
    if ($Serial) {
        return $Serial
    }
    $devices = @(& $Adb devices | ForEach-Object {
        if ($_ -match '^(\S+)\s+device\s*$') { $Matches[1] }
    })
    if ($devices.Count -eq 0) {
        throw 'No Android device or emulator is online. Start MuMu or pass -Serial.'
    }
    return $devices[0]
}

function Install-AndroidDebug {
    param([string]$RequestedPath)
    $adb = Resolve-Adb
    $device = Resolve-AndroidSerial -Adb $adb
    $apk = $RequestedPath
    if (-not $apk) {
        $apk = Join-Path $releaseRoot 'LanzouYOU_Android\debug\LanzouYOU-debug.apk'
    }
    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) {
        throw "Debug APK was not found: $apk"
    }
    Write-Step -Message "Install Android debug APK on $device."
    & $adb -s $device install -r $apk
    if ($LASTEXITCODE -ne 0) {
        throw "adb install failed for $device."
    }
    Write-Host "AndroidSerial: $device"
    Write-Host "AndroidInstall: succeeded"
}

function Launch-AndroidDebug {
    $adb = Resolve-Adb
    $device = Resolve-AndroidSerial -Adb $adb
    Write-Step -Message "Launch LanzouYOU on $device."
    & $adb -s $device shell monkey -p $androidPackage -c android.intent.category.LAUNCHER 1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Android launch failed for $device."
    }
    Write-Host "AndroidSerial: $device"
    Write-Host "AndroidLaunch: started"
}

function Resolve-WindowsExe {
    if ($ExePath) {
        return (Resolve-Path -LiteralPath $ExePath -ErrorAction Stop).Path
    }
    $staged = Join-Path $releaseRoot 'LanzouYOU_Windows\debug\lanzouyou.exe'
    if (Test-Path -LiteralPath $staged -PathType Leaf) {
        return $staged
    }
    $built = Join-Path (Get-WindowsBuildDirectory -Mode debug) $windowsExeName
    if (Test-Path -LiteralPath $built -PathType Leaf) {
        return $built
    }
    throw 'Windows debug executable was not found. Build it first.'
}

function Start-WindowsDebug {
    $executable = Resolve-WindowsExe
    $workingDirectory = Split-Path -Parent $executable
    if (-not (Test-Path -LiteralPath (Join-Path $workingDirectory 'lanzouyou_core.dll') -PathType Leaf)) {
        throw "Rust core DLL is missing next to the Windows executable: $workingDirectory"
    }
    Write-Step -Message 'Launch LanzouYOU Windows debug bundle.'
    $process = Start-Process -FilePath $executable -WorkingDirectory $workingDirectory -PassThru
    Start-Sleep -Seconds $LaunchWaitSeconds
    if ($process.HasExited) {
        throw "Windows launch smoke failed. ExitCode=$($process.ExitCode)"
    }
    Write-Host "WindowsExe: $executable"
    Write-Host "WindowsLaunchPid: $($process.Id)"
    Write-Host 'WindowsLaunch: started'
}

function Invoke-WithBuildLock {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)
    $lockDirectory = Join-Path $projectRoot '.locks'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    $lockPath = Join-Path $lockDirectory 'lanzouyou-client.lock'
    $stream = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        & $ScriptBlock
    }
    finally {
        $stream.Dispose()
    }
}

$androidActions = @(
    'EnvironmentCheck',
    'BuildAndroidDebug', 'BuildAndroidRelease', 'BuildAllDebug',
    'InstallAndroidDebug', 'LaunchAndroidDebug', 'BuildInstallAndroidDebug'
)
$windowsActions = @(
    'Test', 'WindowsToolchainCheck',
    'BuildWindowsDebug', 'BuildWindowsRelease', 'BuildAllDebug',
    'BuildRunWindowsDebug'
)

try {
    Initialize-Tools -RequireAndroid:($Action -in $androidActions)
    if ($Action -in $windowsActions) {
        Set-WindowsToolchainEnvironment
    }
    if ($Action -eq 'EnvironmentCheck') {
        Invoke-EnvironmentCheck
        Write-Host 'EnvironmentCheck: pass'
        exit 0
    }
    if ($Action -eq 'WindowsToolchainCheck') {
        Invoke-WindowsToolchainPreflight
        exit 0
    }
    Push-Location $flutterProject
    try {
        Invoke-WithBuildLock {
            switch ($Action) {
                'Analyze' {
                    Write-Step -Message 'Run Flutter analyze.'
                    Invoke-FlutterChecked -Arguments @('analyze')
                }
                'Test' {
                    Write-Step -Message 'Run Flutter tests.'
                    Invoke-FlutterChecked -Arguments @('test')
                }
                'PubGet' {
                    Write-Step -Message 'Resolve Flutter dependencies.'
                    Invoke-FlutterChecked -Arguments @('pub', 'get')
                }
                'BuildAndroidDebug' { Build-Android -Mode debug | Out-Null }
                'BuildAndroidRelease' { Build-Android -Mode release | Out-Null }
                'BuildWindowsDebug' { Build-Windows -Mode debug | Out-Null }
                'BuildWindowsRelease' { Build-Windows -Mode release | Out-Null }
                'BuildAllDebug' {
                    Build-Windows -Mode debug | Out-Null
                    Build-Android -Mode debug | Out-Null
                }
                'InstallAndroidDebug' { Install-AndroidDebug -RequestedPath $ApkPath }
                'LaunchAndroidDebug' { Launch-AndroidDebug }
                'BuildInstallAndroidDebug' {
                    $builtApk = Build-Android -Mode debug
                    Install-AndroidDebug -RequestedPath $builtApk
                    Launch-AndroidDebug
                }
                'RunWindowsDebug' { Start-WindowsDebug }
                'BuildRunWindowsDebug' {
                    $script:ExePath = Build-Windows -Mode debug
                    Start-WindowsDebug
                }
            }
        }
    }
    finally {
        Pop-Location
    }
}
catch {
    Write-Host ''
    Write-Host ("LanzouYOUError: {0}" -f $_.Exception.Message)
    exit 1
}
