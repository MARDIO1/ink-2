param(
    [string]$Godot = "T:\GODOT\tool\Godot_v4.7.2-stable_win64_console.exe",
    [switch]$Packaged,
    [string]$Pack = "",
    [switch]$Inspect,
    [switch]$ExternalContent,
    [string]$LevelsCsv = "",
    [string[]]$Levels = @(
        "res://map/asset/imported/扉页.tscn",
        "res://map/asset/imported/第一页.tscn",
        "res://map/asset/imported/第三页.tscn",
        "res://map/asset/imported/peak.tscn",
        "res://map/asset/imported/新地图3.tscn",
        "res://map/asset/imported/新地图4.tscn",
        "res://map/asset/imported/无画布挑战！.tscn",
        "res://map/asset/imported/第二关（基本完成）.tscn",
        "res://map/asset/imported/蓝色攀升.tscn",
        "res://map/asset/imported/黄色2.tscn",
        "res://map/second/第三关·墨泉边.tscn"
    )
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot
if ($LevelsCsv.Length -gt 0) {
    $Levels = @($LevelsCsv.Split(",") | Where-Object { $_.Length -gt 0 })
}
if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: $Godot"
}
if ($Packaged -and $Pack.Length -eq 0) {
    $Pack = Join-Path $project "game\ink_fffight_v0.10.pck"
}
if ($Packaged -and -not (Test-Path -LiteralPath $Pack)) {
    throw "PCK not found: $Pack"
}

$results = @()
foreach ($level in $Levels) {
    $arguments = @("--headless")
    if ($Packaged) {
        $arguments += @("--main-pack", $Pack)
    } else {
        $arguments += @("--path", $project)
    }
    $arguments += @("--script", "res://test/test_level_playability.gd", "--", "--level=$level")
    if ($Inspect) {
        $arguments += "--inspect"
    }
    if ($ExternalContent) {
        $arguments += "--external-content"
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $Godot @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    $detail = ($output | Select-String "\[LevelPlayability\] walk=" | Select-Object -Last 1).Line
    $results += [pscustomobject]@{
        Level = $level
        Exit = $exitCode
        Detail = $detail
    }
    if ($exitCode -ne 0) {
        foreach ($line in $output) {
            Write-Host $line
        }
    }
}

$results | Select-Object Level, Exit, Detail | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$failed = @($results | Where-Object { $_.Exit -ne 0 })
if ($failed.Count -gt 0) {
    Write-Error ("Level playability failed for {0} map(s)." -f $failed.Count)
    exit 1
}
Write-Host ("Level playability PASS: {0} maps." -f $results.Count)
