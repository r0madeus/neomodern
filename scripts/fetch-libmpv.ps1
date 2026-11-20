<#
.SYNOPSIS
  Downloads the LGPL libmpv build for Windows into src-tauri/lib.

.DESCRIPTION
  Downloads one PINNED "mpv-dev-lgpl-x86_64-<date>-git-<hash>.7z" asset from
  zhongfly/mpv-winbuild (the plain x86_64 build, not "v3", which needs newer
  CPU instructions), verifies its SHA-256 against the value pinned in this
  script (it throws on mismatch, before extraction), extracts libmpv-2.dll
  and creates the MSVC import library mpv.lib that the Rust build links
  against.

  Supply chain: the DLL ships inside every Windows installer, so the release
  tag, asset name and hash are pinned in $Pins below. CI never uses -Latest.

  To bump: run with -Latest, review the release, then paste the printed
  Tag / Asset / Sha256 into $Pins and commit. Pin a release that is at
  least two days old: mpv-winbuild rebuilds and re-uploads the newest tag
  under the same name (seen on 2026-11-20: same tag and file name, different
  file), which the hash check rightly refuses.

  Works with Windows PowerShell 5.1 and PowerShell 7. Needs the MSVC build
  tools (already required by Rust on Windows) and either the built-in
  tar.exe with 7z support or 7-Zip (winget install 7zip.7zip).

.PARAMETER Latest
  Maintainer opt-in: resolve the newest release instead of the pin, download
  it, print its tag, asset name and SHA-256 for pasting into $Pins, and stop
  (nothing is extracted or installed). Never use this in CI.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/fetch-libmpv.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/fetch-libmpv.ps1 -Latest
#>
param(
    [string]$Dest = (Join-Path $PSScriptRoot '..\src-tauri\lib'),
    [string]$Arch = 'x86_64',
    [switch]$Force,
    [switch]$Latest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Pinned libmpv builds, one entry per architecture (bump with -Latest).
$Pins = @{
    'x86_64' = @{
        Tag    = '2026-11-18-f92afa75cd'
        Asset  = 'mpv-dev-lgpl-x86_64-20261118-git-f92afa75cd.7z'
        Sha256 = 'b1378ebcc4b52325723343fc0c1330e56bd388166667f340f1ef249a3ded9773'
    }
}

$Dest = [IO.Path]::GetFullPath($Dest)
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$dllOut = Join-Path $Dest 'libmpv-2.dll'
$libOut = Join-Path $Dest 'mpv.lib'
if ((Test-Path $dllOut) -and (Test-Path $libOut) -and -not $Force -and -not $Latest) {
    Write-Host "libmpv already present in $Dest (use -Force to re-download)."
    exit 0
}

# --- 1. Find the release asset -------------------------------------------
$headers = @{ 'User-Agent' = 'neomodern-fetch-libmpv'; 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
$repoApi = 'https://api.github.com/repos/zhongfly/mpv-winbuild/releases'
$pattern = "^mpv-dev-lgpl-$Arch-\d{8}-git-[0-9a-f]+\.7z$"
$expectedSha = $null
if ($Latest) {
    $release = Invoke-RestMethod -Headers $headers -Uri "$repoApi/latest"
    $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
} else {
    $pin = $Pins[$Arch]
    if (-not $pin -or $pin.Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "No valid libmpv pin for architecture '$Arch'. Run with -Latest and paste the result into `$Pins."
    }
    # The pinned file is fetched by its fixed URL (no API call, no rate
    # limit); the hash check below is what makes it trustworthy.
    $release = [pscustomobject]@{ tag_name = $pin.Tag; assets = @() }
    $asset = [pscustomobject]@{
        name                 = $pin.Asset
        browser_download_url = "https://github.com/zhongfly/mpv-winbuild/releases/download/$($pin.Tag)/$($pin.Asset)"
    }
    $expectedSha = $pin.Sha256
}
if (-not $asset) {
    Write-Host "Assets in release $($release.tag_name):"
    $release.assets | ForEach-Object { Write-Host "  $($_.name)" }
    throw "No matching libmpv asset found in release $($release.tag_name)"
}
Write-Host "Using $($asset.name) from release $($release.tag_name)"

# --- 2. Download and extract ---------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) ("neomodern-libmpv-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $archive = Join-Path $work $asset.name
    Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'neomodern-fetch-libmpv' } -Uri $asset.browser_download_url -OutFile $archive
    $actualSha = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
    if ($Latest) {
        Write-Host ''
        Write-Host 'Paste into $Pins (after reviewing the release):'
        Write-Host "  Tag    = '$($release.tag_name)'"
        Write-Host "  Asset  = '$($asset.name)'"
        Write-Host "  Sha256 = '$actualSha'"
        exit 0
    }
    if ($actualSha -ne $expectedSha.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $($asset.name): expected $expectedSha, got $actualSha. Refusing to extract."
    }
    Write-Host "SHA-256 verified: $actualSha"
    $extract = Join-Path $work 'x'
    New-Item -ItemType Directory -Force -Path $extract | Out-Null

    $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
    if (-not $sevenZip -and (Test-Path "$env:ProgramFiles\7-Zip\7z.exe")) { $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe" }
    if ($sevenZip) {
        & $sevenZip x -y "-o$extract" $archive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with exit code $LASTEXITCODE" }
    } else {
        & tar.exe -xf $archive -C $extract
        if ($LASTEXITCODE -ne 0) { throw "tar.exe could not extract the .7z archive. Install 7-Zip (winget install 7zip.7zip) and run again." }
    }

    $dll = Get-ChildItem -Path $extract -Recurse -Filter 'libmpv-2.dll' | Select-Object -First 1
    if (-not $dll) { throw "libmpv-2.dll not found in $($asset.name)" }

    # --- 3. MSVC tools -----------------------------------------------------
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found; install the Visual Studio C++ build tools (needed by Rust anyway)." }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "MSVC x64 build tools not found." }
    $toolsBin = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC') -Directory |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64' }
    $libExe = Join-Path $toolsBin 'lib.exe'
    $dumpbin = Join-Path $toolsBin 'dumpbin.exe'

    # --- 4. Import library -------------------------------------------------
    $def = Get-ChildItem -Path $extract -Recurse -Filter '*.def' | Select-Object -First 1
    if ($def) {
        $defPath = $def.FullName
    } else {
        # No .def shipped: build one from the DLL's export table.
        $defPath = Join-Path $work 'mpv.def'
        $names = & $dumpbin /nologo /exports $dll.FullName |
            ForEach-Object { if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)') { $Matches[1] } }
        if (-not $names) { throw "dumpbin found no exports in libmpv-2.dll" }
        (@('LIBRARY libmpv-2', 'EXPORTS') + $names) | Set-Content -Encoding ASCII -Path $defPath
    }
    & $libExe /nologo "/def:$defPath" /name:libmpv-2.dll "/out:$libOut" /machine:x64 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "lib.exe failed with exit code $LASTEXITCODE" }

    Copy-Item -Force $dll.FullName $dllOut
    @(
        "asset: $($asset.name)",
        "release: $($release.tag_name)",
        "url: $($asset.browser_download_url)",
        "license: LGPL-2.1-or-later (mpv LGPL build); source: https://github.com/mpv-player/mpv"
    ) | Set-Content -Encoding UTF8 -Path (Join-Path $Dest 'SOURCE.txt')
    Write-Host "libmpv ready in $Dest"
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
