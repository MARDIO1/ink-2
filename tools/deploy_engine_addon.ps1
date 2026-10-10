#!/usr/bin/env pwsh
<#
.SYNOPSIS
把外部引擎仓库的 addon 部署进本工程。

.DESCRIPTION
本工程的 .gitignore 忽略 /addons/：引擎住在自己的仓库里（默认 ..\TapTap2026，
远端 Godot_2DVoxel_Addons），这里的 addons/pixel_destruction/ 只是它的**部署副本**。
新克隆、换机器、引擎更新之后都要跑一次本脚本，否则 res://addons/... 全部找不到，
GDExtension 也不会注册（扩展是靠编辑器扫描 .gdextension 写进 .godot/extension_list.cfg 的）。

本脚本只读引擎仓库，不改它。

.EXAMPLE
pwsh tools/deploy_engine_addon.ps1
pwsh tools/deploy_engine_addon.ps1 -Verify          # 部署后跑一遍引擎自检
pwsh tools/deploy_engine_addon.ps1 -Engine D:\other\engine_repo
#>
param(
    [string]$Engine = '',
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# ⚠️ Godot 往 stderr 打 WARNING 是常态（退出时的 ObjectDB 泄漏警告、.uid 从缓存重建等）。
#    $ErrorActionPreference='Stop' 下 native 命令的 stderr 会被当成**终止性错误** ——
#    实测脚本会在"扫描注册"之后直接死掉，-Verify 的自检根本不跑。
#    所以调用 Godot 一律走这个函数：临时把偏好调回 Continue 再收集输出。
function Invoke-Godot {
    param([string[]]$GodotArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Godot @GodotArgs 2>&1 } finally { $ErrorActionPreference = $prev }
    return $out
}
if (-not $Engine) { $Engine = (Resolve-Path (Join-Path $Project '..\TapTap2026')).Path }
$Engine = (Resolve-Path $Engine).Path

$SrcAddon = Join-Path $Engine 'addons\pixel_destruction'
# build_addon.py --verify 会把产物移到 ../_addon_build（住在引擎树里会让编辑器报
# class_name 重名并级联到编译失败），所以树里找不到就去树外找 —— 与 package_addon.py 同规则。
if (-not (Test-Path $SrcAddon)) {
    $Alt = Join-Path (Split-Path $Engine -Parent) '_addon_build'
    if (Test-Path $Alt) { $SrcAddon = $Alt }
}
$SrcGdext = Join-Path $Engine 'gdext'
$DstAddon = Join-Path $Project 'addons\pixel_destruction'
$Godot    = Join-Path $Project '..\Godot_v4.7.2-stable_win64_console.exe'

# ⚠️ 场景里已经写死的 UID，部署时必须钉住（值取自当前 .tscn 的 ext_resource 行）。
#    2026-10-06 拉取远程后这 4 个值正好等于 Godot 按路径确定性生成的结果
#    （pixel_world.gd 从旧的 c21vgjr7k5sgv 变成了 che8niruuu5nq）。
# 引擎仓库的 addon 是构建产物，不带 .uid（build_addon.py 故意剔除，避免重复 UID）；
# Godot 导入时**按路径确定性生成**，实测 5 个被 .tscn 引用的脚本里有 4 个能对上，
# 但 nodes/pixel_world.gd 对不上（引擎里这个文件的历史路径/版本不同）。
# 不钉住就会每次加载都报：
#   ext_resource, invalid UID: uid://c21vgjr7k5sgv - using text path instead
# 而改场景等于改用户已提交的文件，所以反过来钉住 .uid。
$UidPins = [ordered]@{
    'nodes\pixel_world.gd'     = 'uid://bxeqry66jsq28'
    'nodes\pixel_body_2d.gd'   = 'uid://cjoigmrhvvtvx'
    'nodes\pixel_material.gd'  = 'uid://chdh46srdqdtn'
    'nodes\pixel_shape_2d.gd'  = 'uid://x40v3fmcjbnm'
}

if (-not (Test-Path $SrcAddon)) {
    throw "找不到 $SrcAddon —— 先在引擎仓库跑 python tools/build_addon.py（它由 src/ + gdext/ + addon_src/ 拼出来）"
}
if (-not (Test-Path (Join-Path $SrcGdext 'fastphys.dll'))) {
    throw "找不到 $($SrcGdext)\fastphys.dll —— 引擎仓库带预编译的 Windows 库；没有它就只剩 GDScript 回退路径（引擎已删除回退路径）"
}
if (-not (Test-Path $Godot)) { throw "找不到 Godot 可执行文件：$Godot" }

# 重建部署副本。删除前先确认路径确实是本工程的 addons\pixel_destruction。
if (Test-Path $DstAddon) {
    $resolved = (Resolve-Path $DstAddon).Path
    if ($resolved -ne (Join-Path $Project 'addons\pixel_destruction')) {
        throw "拒绝删除意外路径：$resolved"
    }
    Remove-Item -Recurse -Force $resolved
}
New-Item -ItemType Directory -Force -Path (Split-Path $DstAddon) | Out-Null
Copy-Item -Recurse -Force $SrcAddon $DstAddon

# .gdignore 是引擎仓库内部用的（addon 与 src/ 同树会让 class_name/UID 重名）；
# 使用方的项目里没有 src/，留着它会让 Godot **整个忽略 addon**，症状是脚本全部找不到。
Remove-Item -Force (Join-Path $DstAddon '.gdignore')

# 原生加速：两个库必须并排 —— fastphys.dll 按自身目录找 rapier_bridge.dll。
# 少一个的症状是"物理完全不动"，而不是报错。
$Native = Join-Path $DstAddon 'native'
Copy-Item -Force (Join-Path $SrcGdext 'fastphys.dll')      (Join-Path $Native 'fastphys.dll')
Copy-Item -Force (Join-Path $SrcGdext 'rapier_bridge.dll') (Join-Path $Native 'rapier_bridge.dll')

# 模板的 .template 后缀是故意的（包里没有编译好的 .dll 时，编辑器每次导入都会报
# "GDExtension dynamic library not found"）。这里已经有 .dll，所以去掉后缀启用它。
$Template = Join-Path $Native 'fastphys.gdextension.template'
if (-not (Test-Path $Template)) { throw "找不到 $Template" }
Copy-Item -Force $Template (Join-Path $Native 'fastphys.gdextension')

foreach ($rel in $UidPins.Keys) {
    $uidFile = Join-Path $DstAddon "$rel.uid"
    Set-Content -Path $uidFile -Value $UidPins[$rel] -NoNewline -Encoding ascii
    Add-Content -Path $uidFile -Value '' -NoNewline
}

$files = (Get-ChildItem -Recurse -File $DstAddon).Count
Write-Output "已部署 $files 个文件 -> addons/pixel_destruction（含 native/fastphys.dll + rapier_bridge.dll）"

# 注册扩展：GDExtension 靠编辑器扫描写进 .godot/extension_list.cfg，
# 这个缓存不进仓库。不跑这一步，--headless --script 里扩展不会加载。
Write-Output '编辑器扫描注册 GDExtension……'
# 这一步之后 .godot/extension_list.cfg 才会写进 fastphys.gdextension。
# （部署副本里没有 .uid 的脚本，Godot 会按路径确定性生成，或从 .godot 缓存重建。）
Invoke-Godot -GodotArgs @('--headless', '--editor', '--quit', '--path', $Project) |
    Select-String -Pattern 'FastPhys|RapierPhys|invalid UID|ERROR' | ForEach-Object { "  " + $_.Line }

if ($Verify) {
    Write-Output '引擎自检（examples/minimal.gd，8 项断言）……'
    Invoke-Godot -GodotArgs @('--headless', '--path', $Project,
            '--script', 'res://addons/pixel_destruction/examples/minimal.gd') |
        Select-String -Pattern 'PASS|FAIL|passed' | ForEach-Object { "  " + $_.Line }
}
Write-Output '完成。'
