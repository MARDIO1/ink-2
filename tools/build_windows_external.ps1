param(
    [string]$Godot = "T:\GODOT\tool\Godot_v4.7.2-stable_win64_console.exe",
    [string]$Preset = "Windows Desktop",
    [string]$Output = "game",
    [string]$ExeName = "ink_fffight_v0.10.exe",
    [switch]$OverwriteContent,
    [switch]$NoExport
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot
if (-not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path $project $Output
}
New-Item -ItemType Directory -Path $Output -Force | Out-Null

if (-not $NoExport) {
    if (-not (Test-Path -LiteralPath $Godot)) {
        throw "Godot executable not found: $Godot"
    }
    $presetPath = Join-Path $project "export_presets.cfg"
    if (-not (Test-Path -LiteralPath $presetPath)) {
        throw "Export preset missing: $presetPath"
    }
    $presetText = Get-Content -LiteralPath $presetPath -Raw -Encoding UTF8
    $requiredPatterns = @(
        "map/asset/imported/*.tscn",
        "map/second/*.tscn",
        "blueprints/*.inkbp",
        "game/*"
    )
    foreach ($pattern in $requiredPatterns) {
        if (-not $presetText.Contains($pattern)) {
            throw "Export preset must exclude '$pattern' from the PCK. Update export_presets.cfg."
        }
    }
    $exe = Join-Path $Output $ExeName
    $exportArgs = @(
        "--headless",
        "--path", $project,
        "--export-release", $Preset, $exe
    )
    $exportOutput = @(& $Godot @exportArgs 2>&1)
    $exitCode = $LASTEXITCODE
    $log = Join-Path $Output "export.log"
    $exportOutput | Set-Content -LiteralPath $log -Encoding UTF8
    if ($exitCode -ne 0) {
        $exportOutput | Select-Object -Last 80 | Write-Host
        throw "Godot export failed with exit code $exitCode. Log: $log"
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Export completed without executable: $exe"
    }
    $pck = [System.IO.Path]::ChangeExtension($exe, ".pck")
    if (-not (Test-Path -LiteralPath $pck)) {
        throw "Export completed without PCK: $pck"
    }
}

function Copy-ContentFile {
    param(
        [string]$Source,
        [string]$Relative
    )
    $destination = Join-Path $Output $Relative
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if ($OverwriteContent -or -not (Test-Path -LiteralPath $destination)) {
        Copy-Item -LiteralPath $Source -Destination $destination -Force
        return 1
    }
    return 0
}

$copied = 0
$nativeDependencies = @(
    "addons\pixel_destruction\native\rapier_bridge.dll"
)
foreach ($relative in $nativeDependencies) {
    $source = Join-Path $project $relative
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Native runtime dependency not found: $source"
    }
    $destination = Join-Path $Output (Split-Path -Leaf $relative)
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

$mapRoots = @(
    "map\asset\imported",
    "map\second"
)
foreach ($relativeRoot in $mapRoots) {
    $sourceRoot = Join-Path $project $relativeRoot
    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        continue
    }
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter "*.tscn")
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($project.Length + 1)
        $copied += Copy-ContentFile -Source $file.FullName -Relative $relative
    }
}

$extraMapFiles = @(
    "map\asset\blank_level.tscn"
)
foreach ($relative in $extraMapFiles) {
    $source = Join-Path $project $relative
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required map template not found: $source"
    }
    $copied += Copy-ContentFile -Source $source -Relative $relative
}

$blueprintRoot = Join-Path $project "blueprints"
$blueprintOutput = Join-Path $Output "blueprints"
New-Item -ItemType Directory -Path $blueprintOutput -Force | Out-Null
if (Test-Path -LiteralPath $blueprintRoot) {
    $blueprints = @(Get-ChildItem -LiteralPath $blueprintRoot -File -Filter "*.inkbp")
    foreach ($file in $blueprints) {
        $relative = Join-Path "blueprints" $file.Name
        $copied += Copy-ContentFile -Source $file.FullName -Relative $relative
    }
}

Write-Host ("External content ready: {0} file(s) copied to {1}" -f $copied, $Output)
