param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$errors = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath (Join-Path $root 'project.godot'))) {
    $errors.Add('Missing project.godot')
}

$textFiles = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object {
        $relativePath = $_.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')
        $relativePath -notmatch '(^|[\\/])(\.upstream|\.staging|\.godot)([\\/]|$)' -and
        $_.Extension -in @('.gd', '.tscn', '.tres', '.godot')
    }

$pattern = 'res://[^"''\s\)\]`]+'
# 运行时才生成的 res:// 引用（磁盘上没有也不该报错）。res://test/* 的 .png/.json/.jsonl/.tres/.gdextension
# 已由下面的通用规则放行，这里只列通用规则盖不住的。
$runtimeGenerated = @(
    'res://map/asset/baked_map.png',
    'res://test/transport_probe/pworld_probe.gd'
)
foreach ($file in $textFiles) {
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
    foreach ($match in [regex]::Matches($text, $pattern)) {
        $resourcePath = $match.Value.TrimEnd('.', ',', ';')
        if ($resourcePath -match '[%{}*]') {
            continue
        }
        if ($resourcePath -in $runtimeGenerated) {
            continue
        }
        if ($resourcePath -like 'res://test/*' -and
            [IO.Path]::GetExtension($resourcePath) -in @('.png', '.json', '.jsonl', '.tres', '.gdextension')) {
            continue
        }
        $relative = $resourcePath.Substring('res://'.Length).Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) {
            $errors.Add("Missing reference: $resourcePath <- $($file.FullName.Substring($root.Length + 1))")
        }
    }
}

$required = @(
    'addons\pixel_destruction\native\fastphys.dll',
    'addons\pixel_destruction\native\rapier_bridge.dll',
    'addons\pixel_destruction\native\fastphys.gdextension',
    'ui\menu\menu.tscn',
    'ui\hud\hud.tscn',
    'ui\esc\esc.tscn',
    'ui\theme\asset\ink_attack_theme.tres',
    'ui\hud\asset\health_hud.tres',
    'ui\asset\brush.tres'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) {
        $errors.Add("Missing required file: $relative")
    }
}

$config = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'project.godot')
if ($config -notmatch 'config/features=PackedStringArray\("4\.7"') {
    $errors.Add('Godot feature version is not 4.7')
}

if ($errors.Count -gt 0) {
    # Write-Error 在 Stop 偏好下第一条就抛异常，后面的错误永远看不到。
    $ErrorActionPreference = 'Continue'
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Ink Attack static validation passed: scanned $($textFiles.Count) text resources; all res:// references exist."
