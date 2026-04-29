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

# assets/ and server/views/ are gitignored so git diff won't list their files.
# Compare file hashes against the tagged version via git archive to find what actually changed.
# server/views/ contains webpack-generated pug templates with asset fingerprint URLs —
# without them the browser loads stale JS/CSS filenames and the layout breaks.
Write-Host "`n==> Comparing built assets and views against '$Tag'..." -ForegroundColor Cyan

$changedAssets = @()
$tagFileHashes = @{}

# Extract assets/ and server/views/ from the tag into a temp dir to compare
$tempTag = Join-Path ([System.IO.Path]::GetTempPath()) "wiki-tag-assets-$Tag"
if (Test-Path $tempTag) { Remove-Item $tempTag -Recurse -Force }
New-Item -ItemType Directory -Path $tempTag -Force | Out-Null

git archive $Tag -- assets/ server/views/ | tar -x -C $tempTag 2>$null

foreach ($folder in @('assets', 'server\views')) {
    $fullFolder = Join-Path $tempTag $folder
    if (Test-Path $fullFolder) {
        Get-ChildItem -Path $fullFolder -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Replace("$tempTag\", '').Replace('\', '/')
            $tagFileHashes[$rel] = (Get-FileHash $_.FullName -Algorithm MD5).Hash
        }
    }
}

# Compare current assets/ and server/views/ against tag
foreach ($folder in @('assets', 'server\views')) {
    $fullFolder = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path $fullFolder)) { continue }
    Get-ChildItem -Path $fullFolder -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Replace("$PSScriptRoot\", '').Replace('\', '/')
        $currentHash = (Get-FileHash $_.FullName -Algorithm MD5).Hash
        if (-not $tagFileHashes.ContainsKey($rel) -or $tagFileHashes[$rel] -ne $currentHash) {
            $changedAssets += $rel
        }
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

# --- Detect changed node_modules packages and copy them ---
Write-Host "`n==> Detecting changed node_modules packages..." -ForegroundColor Cyan

# Get package versions at the tag
$tagPkgJson = git show "${Tag}:package.json" | ConvertFrom-Json
$curPkgJson = Get-Content (Join-Path $PSScriptRoot 'package.json') -Raw | ConvertFrom-Json

# Merge dependencies + devDependencies for both
function Get-AllDeps($pkg) {
    $d = @{}
    if ($pkg.dependencies)    { $pkg.dependencies.PSObject.Properties    | ForEach-Object { $d[$_.Name] = $_.Value } }
    if ($pkg.devDependencies) { $pkg.devDependencies.PSObject.Properties  | ForEach-Object { $d[$_.Name] = $_.Value } }
    return $d
}

$tagDeps = Get-AllDeps $tagPkgJson
$curDeps = Get-AllDeps $curPkgJson

$changedPackages = @()
foreach ($pkg in $curDeps.Keys) {
    if (-not $tagDeps.ContainsKey($pkg) -or $tagDeps[$pkg] -ne $curDeps[$pkg]) {
        $changedPackages += $pkg
    }
}

$copiedPkgs = 0
$missingPkgs = 0
foreach ($pkg in $changedPackages) {
    $src = Join-Path $PSScriptRoot "node_modules\$pkg"
    if (-not (Test-Path $src)) {
        Write-Warning "  MISSING node_modules package: $pkg"
        $missingPkgs++
        continue
    }
    $dest = Join-Path $OutputDir "node_modules\$pkg"
    Write-Host "  + $pkg  ($($tagDeps[$pkg] ?? 'new') -> $($curDeps[$pkg]))" -ForegroundColor DarkGray
    Copy-Item $src $dest -Recurse -Force
    $copiedPkgs++
}

# --- Detect new transitive packages via yarn.lock diff ---
# Changed top-level packages may pull in new sub-packages (e.g. @simple-git/args-pathspec
# added as a dependency of simple-git) that are hoisted to node_modules but not listed in
# our own package.json. yarn.lock records every resolved package, so diffing it against the
# tag's lockfile tells us exactly which packages are new.
Write-Host "`n==> Checking for new transitive packages not in tag..." -ForegroundColor Cyan

function Get-LockfilePackageNames($lockfileLines) {
    # yarn.lock entry headers look like: "name@version": or name@version:
    # Extract just the package name (strip version specifier and quotes).
    $names = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $lockfileLines) {
        if ($line -match '^"?(@?[^@"]+)@') {
            $names.Add($Matches[1]) | Out-Null
        }
    }
    return $names
}

$tagLockLines   = git show "${Tag}:yarn.lock" 2>$null
$curLockLines   = Get-Content (Join-Path $PSScriptRoot 'yarn.lock')
$tagLockNames   = Get-LockfilePackageNames $tagLockLines
$curLockNames   = Get-LockfilePackageNames $curLockLines

$newTransitive = @()
foreach ($pkg in $curLockNames) {
    if (-not $tagLockNames.Contains($pkg)) {
        # Only include packages that are actually installed in node_modules
        $src = Join-Path $PSScriptRoot "node_modules\$($pkg.Replace('/', '\'))"
        if (Test-Path $src) {
            $newTransitive += $pkg
        }
    }
}

if ($newTransitive.Count -gt 0) {
    Write-Host "  Found $($newTransitive.Count) new transitive package(s) not present at tag:" -ForegroundColor Yellow
    foreach ($pkg in $newTransitive | Sort-Object) {
        $src = Join-Path $PSScriptRoot "node_modules\$($pkg.Replace('/', '\'))"
        $dest = Join-Path $OutputDir "node_modules\$($pkg.Replace('/', '\'))"
        # Skip if already copied as a direct dependency
        if (Test-Path $dest) { continue }
        Write-Host "  + $pkg  (transitive, new since $Tag)" -ForegroundColor DarkGray
        $destParent = Split-Path $dest -Parent
        if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
        Copy-Item $src $dest -Recurse -Force
        $copiedPkgs++
    }
} else {
    Write-Host "  No new transitive packages detected." -ForegroundColor DarkGray
}

# --- Validate the output: require the server entry point to catch missing modules ---
Write-Host "`n==> Validating delta: checking require() resolution from output directory..." -ForegroundColor Cyan
$validateScript = @'
process.chdir(process.argv[2])
// Patch WIKI global so modules that reference it during require don't throw
global.WIKI = { logger: { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} }, config: {} }
const failures = []
const toCheck = [
    './server/core/db',
    './server/core/auth',
    './server/core/mail',
    './server/models/pages',
    './server/models/assets',
    './server/modules/storage/git/storage',
    './server/modules/storage/disk/common',
]
for (const m of toCheck) {
    try { require(m) } catch (e) {
        if (e.code === 'MODULE_NOT_FOUND') failures.push(m + ': ' + e.message)
    }
}
if (failures.length) {
    console.error('MISSING MODULES:\n' + failures.join('\n'))
    process.exit(1)
} else {
    console.log('All checked modules resolved OK.')
}
'@
$validateScript | node - $OutputDir
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  Validation found missing modules in the delta output (see above)."
    Write-Warning "  You may need to copy additional packages manually before deploying."
} else {
    Write-Host "  Validation passed." -ForegroundColor Green
}

# --- Summary ---
Write-Host "`n==> Done." -ForegroundColor Green
Write-Host "    Tag       : $Tag"
Write-Host "    Output    : $OutputDir"
Write-Host "    Copied    : $copied file(s)"
Write-Host "    Packages  : $copiedPkgs node_modules package(s) copied ($($changedPackages.Count) direct, $($newTransitive.Count) transitive)"
if ($missing -gt 0) {
    Write-Host "    Missing   : $missing file(s) (listed above as warnings)" -ForegroundColor Yellow
}
if ($missingPkgs -gt 0) {
    Write-Host "    Missing pkg: $missingPkgs package(s) not found in node_modules (listed above)" -ForegroundColor Yellow
}

Write-Host "`nChanged files included:" -ForegroundColor DarkGray
$releaseFiles | Where-Object { $_ -notmatch '^assets/' -and $_ -notmatch '^server/views/' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
$assetCount = @($changedAssets | Where-Object { $_ -match '^assets/' }).Count
$viewCount  = @($changedAssets | Where-Object { $_ -match '^server/views/' }).Count
Write-Host "  + $assetCount changed asset file(s) from assets/" -ForegroundColor DarkGray
Write-Host "  + $viewCount changed view file(s) from server/views/" -ForegroundColor DarkGray
