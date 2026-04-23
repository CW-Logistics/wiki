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

# Always include all rebuilt assets (gitignored, so git diff won't list them)
$assetFiles = Get-ChildItem -Path "$PSScriptRoot\assets" -Recurse -File |
    ForEach-Object { $_.FullName.Replace("$PSScriptRoot\", '').Replace('\', '/') }

$releaseFiles = @($releaseFiles) + @($assetFiles) | Sort-Object -Unique

if ($releaseFiles.Count -eq 0) {
    Write-Host "`nNo changed files found since '$Tag'. Nothing to export." -ForegroundColor Yellow
    exit 0
}

# --- Copy to output directory ---
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
    Copy-Item $src $dest -Force
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

Write-Host "`nChanged source files included:" -ForegroundColor DarkGray
$releaseFiles | Where-Object { $_ -notmatch '^assets/' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "  + $($assetFiles.Count) asset file(s) from assets/" -ForegroundColor DarkGray
