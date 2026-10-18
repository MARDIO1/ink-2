# 批量跑测试：每个测试独立进程、超时自动终止，避免一个挂住的用例吃光整轮时间。
#
# 用法：
#   pwsh -File test/tools/run_tests.ps1                        # 跑默认清单
#   pwsh -File test/tools/run_tests.ps1 -Tests test_blueprints,test_ui_interactions
#   pwsh -File test/tools/run_tests.ps1 -TimeoutSec 90 -Verbose
#
# 判定：进程超时 = TIMEOUT（多半是脚本错误中断协程、永远到不了 quit）；
#       退出码 0 且没有 FAIL 行 = PASS。
param(
    [string[]] $Tests,
    [int] $TimeoutSec = 120,
    [string] $Godot = 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe',
    [string] $ProjectPath = 'D:\Ink'
)

$default = @(
    'test_creative_editor', 'test_editor_layout_tools', 'test_editor_control_picking',
    'test_editor_ink_quota', 'test_monster_editor_drag', 'test_monster_resize',
    'test_blueprints', 'test_blueprint_ui', 'test_editor_player_absence',
    'test_ui_interactions', 'test_map_sequence', 'test_title_level_entry'
)
if (-not $Tests -or $Tests.Count -eq 0) { $Tests = $default }

$results = @()
foreach ($name in $Tests) {
    $script = "res://test/$name.gd"
    if (-not (Test-Path (Join-Path $ProjectPath "test/$name.gd"))) {
        $results += [pscustomobject]@{ Test = $name; Status = 'MISSING'; Seconds = 0; Detail = '' }
        continue
    }
    $log = Join-Path $env:TEMP "dsh-test-$name.log"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $Godot -ArgumentList @('--headless', '--path', $ProjectPath, '--script', $script) `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    $sw.Stop()
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        $results += [pscustomobject]@{ Test = $name; Status = 'TIMEOUT'; Seconds = [int]$sw.Elapsed.TotalSeconds; Detail = '' }
        continue
    }
    $text = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + (Get-Content "$log.err" -Raw -ErrorAction SilentlyContinue)
    $fails = @([regex]::Matches($text, '(?m)^.*\bFAIL\b.*$')) | ForEach-Object { $_.Value.Trim() }
    $checks = [regex]::Match($text, '(\d+) checks, (\d+) failures')
    # -PassThru + WaitForExit 之后 ExitCode 可能还是 $null，按 0 处理。
    $exitCode = if ($null -eq $proc.ExitCode) { 0 } else { [int]$proc.ExitCode }
    $status = if ($fails.Count -gt 0 -or $exitCode -ne 0) { 'FAIL' } else { 'PASS' }
    $detail = if ($fails.Count -gt 0) { $fails[0] } elseif ($checks.Success) { "$($checks.Groups[1].Value) checks" } else { '' }
    $results += [pscustomobject]@{ Test = $name; Status = $status; Seconds = [int]$sw.Elapsed.TotalSeconds; Detail = $detail }
}

$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Status -ne 'PASS' })
"总计 $($results.Count) 个：PASS $(@($results | Where-Object { $_.Status -eq 'PASS' }).Count)，其余 $($failed.Count)"
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
