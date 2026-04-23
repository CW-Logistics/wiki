# build-delta.ps1
# Builds the frontend assets and exports all files that changed since a given git tag.
#
# Usage:
#   .\build-delta.ps1 -Tag v2.5.128
#   .\build-delta.ps1 -Tag v2.5.128 -OutputDir C:\releases\delta
#   .\build-delta.ps1 -Tag v2.5.128 -SkipBuild

param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [string]$OutputDir = "$PSScriptRoot\..\wiki-delta",

    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# --- Validate tag exists ---
$tagExists = git tag --list $Tag
if (-not $tagExists) {
    Write-Error "Git tag '$Tag' not found. Available tags:`n$(git tag --list | Select-Object -Last 20 | Out-String)"
    exit 1
}

# --- Build ---
if (-not $SkipBuild) {
    Write-Host "`n==> Building frontend assets..." -ForegroundColor Cyan
    $env:NODE_OPTIONS = '--openssl-legacy-provider'
    yarn build
    if ($LASTEXITCODE -ne 0) {
        Write-Error "yarn build failed (exit code $LASTEXITCODE)"
        exit 1
    }
} else {
    Write-Host "`n==> Skipping build (-SkipBuild specified)" -ForegroundColor Yellow
}

# --- Collect changed files ---
Write-Host "`n==> Collecting files changed since '$Tag'..." -ForegroundColor Cyan

# Files tracked by git that changed since the tag
$gitChanged = git diff --name-only $Tag HEAD
# Untracked files (new, not yet committed)
$gitUntracked = git ls-files --others --exclude-standard

# Combine and deduplicate
$allRelative = @($gitChanged) + @($gitUntracked) | Where-Object { $_ } | Sort-Object -Unique

# Exclude files that shouldn't go into a release package
$excludePatterns = @(
    '^client/',       # source only, compiled into assets/
    '^dev/',          # build tooling
    '^patches/',      # build-time only
    '^\.github/',
    '^\.devcontainer/',
    '^\.vscode/',
    '^\.webpack-cache/',
    '^node_modules/', # handled separately
    '^cypress\.json$',
    '^\.eslint',
    '^\.babel',
    '^\.editor',
    '^\.nvmrc',
    '^\.npmrc',
    '^yarn\.lock$',
    '^build-delta\.ps1$'
)

$releaseFiles = $allRelative | Where-Object {
    $f = $_
    -not ($excludePatterns | Where-Object { $f -match $_ })
}

# assets/ is gitignored so git diff won't list individual files.
# Compare file hashes against the tagged version via git archive to find what actually changed.
Write-Host "`n==> Comparing built assets against '$Tag'..." -ForegroundColor Cyan

$changedAssets = @()
$tagAssetHashes = @{}

# Extract assets from the tag into a temp dir to compare
$tempTag = Join-Path ([System.IO.Path]::GetTempPath()) "wiki-tag-assets-$Tag"
if (Test-Path $tempTag) { Remove-Item $tempTag -Recurse -Force }
New-Item -ItemType Directory -Path $tempTag -Force | Out-Null

# git archive only contains tracked files — assets/ was tracked at release time
git archive $Tag -- assets/ | tar -x -C $tempTag 2>$null

if (Test-Path "$tempTag\assets") {
    # Build hash map of tag's assets
    Get-ChildItem -Path "$tempTag\assets" -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Replace("$tempTag\", '').Replace('\', '/')
        $tagAssetHashes[$rel] = (Get-FileHash $_.FullName -Algorithm MD5).Hash
    }
}

# Compare current assets against tag
$currentAssets = Get-ChildItem -Path "$PSScriptRoot\assets" -Recurse -File
foreach ($file in $currentAssets) {
    $rel = $file.FullName.Replace("$PSScriptRoot\", '').Replace('\', '/')
    $currentHash = (Get-FileHash $file.FullName -Algorithm MD5).Hash
    if (-not $tagAssetHashes.ContainsKey($rel) -or $tagAssetHashes[$rel] -ne $currentHash) {
        $changedAssets += $rel
    }
}

Remove-Item $tempTag -Recurse -Force

$releaseFiles = @($releaseFiles) + @($changedAssets) | Sort-Object -Unique

if ($releaseFiles.Count -eq 0) {
    Write-Host "`nNo changed files found since '$Tag'. Nothing to export." -ForegroundColor Yellow
    exit 0
}

# --- Copy to output directory, patching package.json ---
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
Write-Host "`n==> Copying $($releaseFiles.Count) files to: $OutputDir" -ForegroundColor Cyan

if (Test-Path $OutputDir) {
    Remove-Item $OutputDir -Recurse -Force
}

$copied = 0
$missing = 0

foreach ($rel in $releaseFiles) {
    $src = Join-Path $PSScriptRoot $rel.Replace('/', '\')
    if (-not (Test-Path $src)) {
        Write-Warning "  MISSING: $rel"
        $missing++
        continue
    }
    $dest = Join-Path $OutputDir $rel.Replace('/', '\')
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    if ($rel -eq 'package.json') {
        # Strip the "dev": true flag so the release doesn't show the dev warning
        # and uses production telemetry / Let's Encrypt endpoints
        $pkg = Get-Content $src -Raw | ConvertFrom-Json
        $pkg.PSObject.Properties.Remove('dev')
        $pkg | ConvertTo-Json -Depth 32 | Set-Content $dest -Encoding UTF8
    } else {
        Copy-Item $src $dest -Force
    }
    $copied++
}

# --- Summary ---
Write-Host "`n==> Done." -ForegroundColor Green
Write-Host "    Tag       : $Tag"
Write-Host "    Output    : $OutputDir"
Write-Host "    Copied    : $copied file(s)"
if ($missing -gt 0) {
    Write-Host "    Missing   : $missing file(s) (listed above as warnings)" -ForegroundColor Yellow
}

Write-Host "`nChanged files included:" -ForegroundColor DarkGray
$releaseFiles | Where-Object { $_ -notmatch '^assets/' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "  + $($changedAssets.Count) changed asset file(s) from assets/" -ForegroundColor DarkGray
