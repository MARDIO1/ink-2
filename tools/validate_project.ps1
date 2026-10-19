param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$violations = [System.Collections.Generic.List[object]]::new()
$groupOrder = @('正式资源', '测试', '导入工具')
$fileCount = @{}
foreach ($group in $groupOrder) { $fileCount[$group] = 0 }

function Add-Violation([string]$group, [string]$message) {
    $violations.Add([pscustomobject]@{ Group = $group; Message = $message })
}

# 资源分组：正式资源、测试、导入源包工具分开统计。
# map/asset/imported/*.tscn 是正式地图的既有存放位置，仍算正式资源；
# actor/*/imported 的源包脚本与 tools 属于导入/校验工具，不参与旧迁移路径判定。
function Get-ResourceGroup([string]$relativePath) {
    $normalized = $relativePath.Replace('\', '/')
    if ($normalized -match '^test/') { return '测试' }
    if ($normalized -match '^tools/' -or $normalized -match '^actor/[^/]+/imported/') { return '导入工具' }
    return '正式资源'
}

if (-not (Test-Path -LiteralPath (Join-Path $root 'project.godot'))) {
    Add-Violation '正式资源' 'Missing project.godot'
}

# 只扫正式资源与测试；构建/备份副本是别的仓库快照，路径天然对不上，扫进来只会淹没真问题。
$scanRoots = @('actor', 'addons', 'blueprint', 'debug', 'ink', 'map', 'root', 'test', 'tools', 'ui', 'doc')
$skipDirs = '(^|[\\/])(\.upstream|\.staging|\.godot|\.codex-build|\.codex-tmp|\.merge-backup|\.level_backups|\.runtime_logs|\.acl-recovery|output|sites|blueprints)([\\/]|$)'
$textFiles = foreach ($scanRoot in $scanRoots) {
    $scanPath = Join-Path $root $scanRoot
    if (-not (Test-Path -LiteralPath $scanPath)) { continue }
    Get-ChildItem -LiteralPath $scanPath -Recurse -File |
        Where-Object {
            $relativePath = $_.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')
            $relativePath -notmatch $skipDirs -and
            $_.Extension -in @('.gd', '.tscn', '.tres', '.godot')
        }
}

# 路径里可以有空格（如 "Miniature Parade.ogg"），所以只以引号/换行作为边界。
$pattern = 'res://[^"''\r\n]+'

# 旧迁移路径：正式资源不得再引用；测试、文档、导入源包工具不计。
$legacyPaths = @(
    'res://debug/creative/src/map_dialogue_trigger.gd',
    'res://debug/creative/src/map_imported_image.gd',
    'res://blueprint/src/blueprint_place.gd'
)

# 运行时才生成、磁盘上此刻不该存在的引用。
$runtimeGenerated = @(
    'res://map/asset/baked_map.png',
    'res://test/transport_probe/pworld_probe.gd',
    'res://preview.png',
    'res://main.tscn',
    'res://missing.tscn'
)
function Test-RuntimeArtifact([string]$path) {
    if ($path -match '\.(tmp|snapshot)(\.|$)') { return $true }
    if ($path -match '^res://\.(godot|codex-tmp|level_backups|runtime_logs)/') { return $true }
    if ($path -match '^res://map/asset/imported/[^/]+\.tscn$') { return $true }
    if ($path -match '^res://map/asset/workshop/') { return $true }
    if ($path -match '^res://test/fixtures/maps/[^/]+\.tscn$') { return $true }
    return $false
}

# 路径后面常粘着标点或说明文字：从尾部逐字符回退，直到命中真实文件。
function Resolve-ExistingPath([string]$candidate) {
    $current = $candidate.TrimEnd()
    while ($current.Length -gt 'res://'.Length) {
        $relative = $current.Substring('res://'.Length).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $full = Join-Path $root $relative
        $exists = $false
        try { $exists = Test-Path -LiteralPath $full } catch { $exists = $false }
        if ($exists) { return $current }
        $last = [string]$current[$current.Length - 1]
        if ('.,;:)]}' -match [regex]::Escape($last)) {
            $current = $current.Substring(0, $current.Length - 1).TrimEnd()
            continue
        }
        # 命令行示例（"path --flag <arg>"）不是引用：退到最后一个空格再试。
        $space = $current.LastIndexOf(' ')
        if ($space -gt 'res://'.Length) {
            $current = $current.Substring(0, $space).TrimEnd()
            continue
        }
        break
    }
    return ''
}

foreach ($file in $textFiles) {
    $relativePath = $file.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')
    $group = Get-ResourceGroup $relativePath
    $fileCount[$group] += 1
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
    # 注释里的 "res://..." 只是说明文字，不是真引用（细则：不能对示例文本报架构错误）。
    # 行首的 ## 文档注释同样按注释处理，避免维护说明被当成架构违规。
    if ($file.Extension -eq '.gd') {
        $text = ($text -split "`n" | ForEach-Object { $_ -replace '(^|\s)#.*$', '$1' }) -join "`n"
    } else {
        $text = ($text -split "`n" | Where-Object { $_ -notmatch '^\s*;' }) -join "`n"
    }
    # 文档里的迁移说明是历史记录，不按架构违规处理。
    $isDocumentation = $relativePath -match '(^|[\\/])doc([\\/]|$)'
    if ($group -eq '正式资源' -and -not $isDocumentation) {
        foreach ($legacyPath in $legacyPaths) {
            if ($text.Contains($legacyPath)) {
                Add-Violation $group "Old migration path: $legacyPath <- $relativePath"
            }
        }
    }
    foreach ($match in [regex]::Matches($text, $pattern)) {
        $resourcePath = $match.Value.TrimEnd('.', ',', ';', ' ')
        if ($resourcePath -match '[%{}*]') { continue }
        if ($resourcePath -match '[^\x00-\x7F]') { continue }
        # GDScript 的 \uXXXX 转义要到运行时才还原，静态扫描无法解析这种路径。
        if ($resourcePath -match '\\u[0-9a-fA-F]{4}') { continue }
        if ($resourcePath -in $runtimeGenerated) { continue }
        if (Test-RuntimeArtifact $resourcePath) { continue }
        if ($resourcePath -like 'res://test/*' -and
            [IO.Path]::GetExtension($resourcePath) -in @('.png', '.json', '.jsonl', '.tres', '.gdextension')) {
            continue
        }
        if ((Resolve-ExistingPath $resourcePath) -ne '') { continue }
        Add-Violation $group "Missing reference: $resourcePath <- $relativePath"
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
        Add-Violation '正式资源' "Missing required file: $relative"
    }
}

# 架构规则：蓝图核心只能依赖 ink/general，不得反向依赖画布/界面/调试。
$coreDirectory = Join-Path $root 'blueprint/src'
if (Test-Path -LiteralPath $coreDirectory) {
    foreach ($file in Get-ChildItem -LiteralPath $coreDirectory -Filter '*.gd' -File) {
        $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
        foreach ($match in [regex]::Matches($text, 'preload\("res://([^"]+)"\)')) {
            $target = $match.Groups[1].Value
            if ($target -match '^(actor|ui|debug)/') {
                Add-Violation '正式资源' "Blueprint core dependency: blueprint/src/$($file.Name) -> res://$target"
            }
        }
    }
}

$config = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'project.godot')
if ($config -notmatch 'config/features=PackedStringArray\("4\.7"') {
    Add-Violation '正式资源' 'Godot feature version is not 4.7'
}

Write-Host 'Ink Attack static validation'
foreach ($group in $groupOrder) {
    $items = @($violations | Where-Object { $_.Group -eq $group })
    Write-Host ("[{0}] {1} 个文件，{2} 条违规" -f $group, $fileCount[$group], $items.Count)
}

if ($violations.Count -gt 0) {
    # Write-Error 在 Stop 偏好下第一条就抛异常，后面的错误永远看不到。
    $ErrorActionPreference = 'Continue'
    foreach ($group in $groupOrder) {
        foreach ($item in @($violations | Where-Object { $_.Group -eq $group })) {
            Write-Error ("[{0}] {1}" -f $group, $item.Message)
        }
    }
    exit 1
}

Write-Host "Ink Attack static validation passed: scanned $(@($textFiles).Count) text resources; all res:// references exist; no legacy migration paths in production resources."
