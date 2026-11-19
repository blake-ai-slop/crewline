. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# Nhận phiên Codex mới sau /new khi chân không có 'Context N% left' (status_line của user, bị cắt '…') và hộp chọn /new
# vẽ dưới hội thoại cũ. Fixture chép từ màn hình thật Codex 0.166 (demo-win-w2, 2026-11-19). Không gọi hc thật.
$want = 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Get-InputBox', 'Test-SentInput', 'Send-CodexQueue', 'Get-ScreenDialog', 'Test-SessionReady', 'Test-AgentScreen'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($msg) { }
function Die($msg) { throw $msg }
function hc { throw 'gọi hc thật trong test' }

# Phiên cũ, rảnh: placeholder vẫn hiện dưới lịch sử, chân bị cắt '…' (không có Context).
$OldScreen = @'
• Ran git add -- src/neg.ps1 tests/Neg.Tests.ps1 context…
  └  create mode 100644 src/neg.ps1
    crew: đã gửi -> demo-win-planner (working)
    + 6 lines (ctrl+t to expand)

• XONG neg-num

  • Commit e665982: thêm Neg-Num([double]$a) và test.
  • Pester: 4 đạt, 0 lỗi; worktree sạch.

  Worked for 52s • 9:15 AM


› Ask Codex to do anything

  GPT-6.1-Sol medium · 5h 74% left · weekly 57% left · C…
  ? for shortcuts
'@

# Phiên mới thật sau /new + chọn worktree hiện tại: đầu phiên, logo chữ nổi, ô trống, chân cắt.
$FreshScreen = @'

  >_ OpenAI Codex (v0.166.0)
     D:\crewtest\demo-win\.crew\worktrees\w2
  permissions: YOLO mode


                      ⣀⣤⣴⣶⣶⣶⣶⣤⣀
                    ⢠⣾⣿⣿⠿⠟⠛⠻⣿⣿⣿⣿⣿⣿⣿⣿⣷⣦⡀
                  ⠈⠛⠿⣿⣿⣿⣿⣿⣿⣿⣯⣅⣀⣠⣤⣶⣿⣿⠟⠁
                        ⠈ ⠙⠿⢿⣿⣿⣿⣿⡿⠛⠉


› Ask Codex to do anything

  GPT-6.1-Sol medium · 5h 72% left · weekly 57% left · C…
  ? for shortcuts
'@

# Hộp chọn thật của /new dưới hội thoại cũ; mô tả mục bị gói xuống dòng.
$PickerTail = @'
  Where should the new conversation run?


› 1. Use current Git worktree  Keep using the current
                               working directory
  2. Create new Git worktree   Create a separate checkout
                               of this repository in
                               another directory

  enter select · esc back
'@
# Lịch sử có chữ giống hộp thoại (như task codex-warn): trước đây làm cả màn hình bị coi là hộp lạ.
$NoisyHistory = @'
› Thêm test: hộp 'Allow command (y/n)' và 'Do you want to proceed?' phải chặn,
  '› 1. Yes, proceed' không được bấm.

• Đã thêm fixture Allow command (y/n) và Yes, proceed.
  Do you want to proceed? -> chặn, 0 Enter.

  Worked for 3s • 3:17 PM

'@
# Here-string theo eol của file khi checkout (LF hoặc CRLF): chuẩn hóa về LF, ca CRLF tự dựng từ đây.
$OldScreen = $OldScreen.Replace("`r`n", "`n"); $FreshScreen = $FreshScreen.Replace("`r`n", "`n")
$PickerTail = $PickerTail.Replace("`r`n", "`n"); $NoisyHistory = $NoisyHistory.Replace("`r`n", "`n")
$Picker = "$NoisyHistory`n$PickerTail"

function New-Info([string]$status = 'idle') { [pscustomobject]@{ name = 'x-w1'; state = 'live'; status = [pscustomobject]@{ app = 'codex'; state = $status }; turn = 1 } }
function New-Ops($screens) {
  $st = @{ Screens = @($screens); Ri = 0; Keys = 0; Sent = [Collections.Generic.List[string]]::new() }
  @{
    State = $st
    Get   = { param($t) New-Info }
    Send  = { param($t, $x, $raw) $st.Sent.Add($x); @{ Code = 0; Text = '{"started":true}' } }.GetNewClosure()
    Keys  = { param($t) $st.Keys++ }.GetNewClosure()
    Sleep = { param($ms) }
    Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
  }
}

Describe 'Codex sau /new: nhận phiên mới không cần Context N% left' {
  It 'màn hình phiên mới thật (chân cắt, không Context) -> sẵn sàng' {
    Test-SessionReady 'codex' (New-Info) $FreshScreen | Should Be $true
  }
  It 'phiên cũ còn lịch sử, ô trống placeholder -> chưa' {
    Test-SessionReady 'codex' (New-Info) $OldScreen | Should Be $false
  }
  It 'đầu phiên còn thấy nhưng đã có tin (› / •) -> chưa' {
    $short = $FreshScreen.Replace('› Ask Codex', "› làm task a`n`n• Xong.`n`n› Ask Codex")
    Test-SessionReady 'codex' (New-Info) $short | Should Be $false
    $ran = $FreshScreen.Replace('› Ask Codex', "  └ ok`n`n› Ask Codex")
    Test-SessionReady 'codex' (New-Info) $ran | Should Be $false
  }
  It 'ô nhập có chữ, đang chạy, hoặc có hộp thoại -> chưa' {
    Test-SessionReady 'codex' (New-Info) ($FreshScreen.Replace('Ask Codex to do anything', 'tin cũ')) | Should Be $false
    Test-SessionReady 'codex' (New-Info 'working') $FreshScreen | Should Be $false
    Test-SessionReady 'codex' (New-Info) "$FreshScreen`nAllow command (y/n)" | Should Be $false
  }
  It 'chân chỉ có ? for shortcuts (user bỏ status_line) -> vẫn nhận ô và phiên mới' {
    $bare = ($FreshScreen -split "`n" | Where-Object { $_ -notmatch 'GPT-6\.1-Sol' }) -join "`n"
    (Get-InputBox $bare).Kind | Should Be 'codex'
    Test-SessionReady 'codex' (New-Info) $bare | Should Be $true
    $other = $FreshScreen.Replace('GPT-6.1-Sol medium · 5h 72% left · weekly 57% left · C…', 'o9-mini high · ~\w2 · main')
    Test-SessionReady 'codex' (New-Info) $other | Should Be $true
  }
  It 'chân limit không có model (5h … · weekly …) vẫn là chân Codex' {
    $lim = $OldScreen.Replace('GPT-6.1-Sol medium · ', '').Replace("`n  ? for shortcuts", '')
    (Get-InputBox $lim).Kind | Should Be 'codex'
  }
  It 'Context vẫn quyết định khi có: 100 -> mới, khác -> chưa (dù có đầu phiên)' {
    Test-SessionReady 'codex' (New-Info) ($FreshScreen.Replace('· C…', '· Context 100% left')) | Should Be $true
    Test-SessionReady 'codex' (New-Info) ($FreshScreen.Replace('· C…', '· Context 63% left')) | Should Be $false
  }
  It 'Test-AgentScreen nhận TUI Codex khi chân không có Context' {
    Test-AgentScreen codex $OldScreen | Should Be $true
    Test-AgentScreen codex $FreshScreen | Should Be $true
    Test-AgentScreen codex "xong`nPS C:\w2>" | Should Be $false
  }
}

Describe 'Codex /new: hộp chọn worktree dưới hội thoại cũ' {
  It 'hộp thật, mục 1 đang chọn, lịch sử có chữ giống hộp thoại -> codex-new' {
    Get-ScreenDialog $Picker | Should Be 'codex-new'
    Get-ScreenDialog $PickerTail | Should Be 'codex-new'
    Get-ScreenDialog ($Picker.Replace("`r`n", "`n").Replace("`n", "`r`n")) | Should Be 'codex-new'
    Test-SessionReady 'codex' (New-Info) ($FreshScreen.Replace("`r`n", "`n").Replace("`n", "`r`n")) | Should Be $true
  }
  It 'mục đang chọn là 2 (Create new) -> other, không bấm' {
    Get-ScreenDialog ($Picker.Replace('› 1. Use current', '  1. Use current').Replace('  2. Create new', '› 2. Create new')) | Should Be 'other'
  }
  It 'hộp lạ dưới hoặc sát lề trên hộp chọn vẫn thắng' {
    Get-ScreenDialog "$Picker`nAllow command?" | Should Be 'other'
    Get-ScreenDialog "Do you want to proceed?`n$PickerTail" | Should Be 'other'
    Get-ScreenDialog "$NoisyHistory`nAllow command?`n  git push`n$PickerTail" | Should Be 'other'
  }
  It 'luồng /new: hộp chọn -> 1 Enter -> phiên mới thật -> ok' {
    $ops = New-Ops @($Picker, $Picker, $Picker, $FreshScreen)
    $r = Invoke-SendFlow 'x-w1' '/new' $ops 'codex' 10
    $r.Ok | Should Be $true
    $ops.State.Keys | Should Be 1
  }
  It 'luồng /new: không thấy phiên mới -> lỗi nói điều user thấy, không nhắc Context' {
    $ops = New-Ops @($OldScreen)
    $r = Invoke-SendFlow 'x-w1' '/new' $ops 'codex' 3
    $r.Ok | Should Be $false
    $r.Message | Should Match 'phiên Codex mới trống'
    $r.Message | Should Not Match 'Context'
  }
}

# Phiên mới thật khi limit <50%: Codex vẽ '⚠ 5h limit: 47% left' ngay trên ô nhập (demo-win w2, 2026-11-19, reuse-fix).
# Fixture chép nguyên màn hình; checkout LF hay CRLF đều chuẩn hóa về LF, ca CRLF tự dựng.
$WarnFresh = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/codex-v0.166/new-session-limit-warn.txt')) -replace "`r`n", "`n").TrimEnd("`n")

Describe 'Codex sau /new: cảnh báo limit trên ô nhập không phải hội thoại' {
  It 'màn hình thật có ⚠ 5h limit -> phiên mới sẵn sàng (LF và CRLF)' {
    $WarnFresh | Should Match '⚠ 5h limit: 47% left'
    Test-SessionReady 'codex' (New-Info) $WarnFresh | Should Be $true
    Test-SessionReady 'codex' (New-Info) ($WarnFresh.Replace("`n", "`r`n")) | Should Be $true
  }
  It 'các dạng cảnh báo đã biết (weekly, resets at, /status, N warnings) cũng bỏ qua' {
    foreach ($w in '⚠ weekly limit: 9% left', '⚠ 5h limit: 47% left · resets at 3:15 PM', '⚠ weekly limit: 20% left · resets at 9:00 AM on 21 Nov · /status', '⚠ 2 warnings · f2 to view') {
      Test-SessionReady 'codex' (New-Info) ($WarnFresh.Replace('⚠ 5h limit: 47% left', $w)) | Should Be $true
    }
  }
  It '⚠ khác (lỗi/cảnh báo của hội thoại) vẫn tính -> chưa' {
    Test-SessionReady 'codex' (New-Info) ($WarnFresh.Replace('⚠ 5h limit: 47% left', '⚠ Command failed: git push')) | Should Be $false
    Test-SessionReady 'codex' (New-Info) ($WarnFresh.Replace('⚠ 5h limit: 47% left', '⚠ 5h limit: 47% left — đã sửa xong')) | Should Be $false
    $talk = $WarnFresh.Replace('› Ask Codex', "• Xong.`n`n› Ask Codex")
    Test-SessionReady 'codex' (New-Info) $talk | Should Be $false
  }
  It 'luồng /new: phiên mới có ⚠ limit -> ok' {
    $ops = New-Ops @($Picker, $WarnFresh)
    $r = Invoke-SendFlow 'x-w1' '/new' $ops 'codex' 10
    $r.Ok | Should Be $true
  }
  It 'mẫu cảnh báo trong Test-SessionReady trùng mẫu của Get-InputBox' {
    $pats = foreach ($fn in 'Get-InputBox', 'Test-SessionReady') {
      $f = Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $fn } -Recurse:$false | Select-Object -First 1
      @($f.FindAll({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $a.Value -like '^\s*⚠\s+(?:*' }, $true))[0].Value
    }
    $pats[0] | Should Not BeNullOrEmpty
    $pats[1] | Should Be $pats[0]
  }
}
