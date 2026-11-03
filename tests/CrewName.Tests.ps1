# Tên crew duy nhất theo project: slug, sổ ~/.crewline/projects.json (HOME giả / file trong $TestDrive), kiểm chủ terminal theo cwd.
# Hàm trích bằng AST từ crew.ps1, hc giả — không gọi hc thật. Init chạy e2e qua Invoke-InTestHome (HOME giả).
. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
# Invoke-Up gọi; stub để không đọc stdin hay config git của máy chạy test (danh tính git test ở CrewGitIdentity).
function Confirm-GitIdentity { }
$want = 'Get-LegacySlug', 'Get-Slug', 'Test-CrewName', 'Get-CrewName', 'ConvertTo-RootKey', 'Test-SamePath', 'Test-TermOwner',
  'Get-ForeignTermError', 'Read-ProjectRegistry', 'Save-ProjectRegistry', 'Get-NameOwner', 'Resolve-CrewName', 'Register-CrewName',
  'Get-NameConflict', 'Update-ConfigName', 'Get-Config', 'Invoke-Up', 'Invoke-Send', 'Send-CrewMessage', 'Get-MainRoot',
  'Invoke-GitQuiet', 'Invoke-GitOrDie', 'Get-Tasks', 'Save-Tasks', 'Test-WorktreeListed', 'Get-WorkerTree', 'Initialize-WorkerTree',
  'Get-Flags', 'Quote', 'Get-AgentCommand', 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Get-WorkerMode', 'Get-TermShellState', 'Test-SessionReady',
  'Get-InputBox', 'Test-SentInput', 'Send-CodexQueue', 'Get-ScreenDialog', 'Get-TaskLine', 'Format-DirtyFiles', 'Initialize-TaskBranch', 'Send-WorkerTask', 'Start-WorkerTask', 'New-TaskRecord',
  'ConvertTo-IdKey', 'Get-LegacyIdKey', 'Test-IdKey', 'Get-CrewIdKey', 'Test-OtherAlive', 'Get-IdKeyOwner', 'Get-Ids',
  'Test-FolderOwner', 'Get-ForeignSpaceError', 'Get-TakenIdKeys'
$want += 'Get-SessionsFile', 'New-SessionBook', 'Test-SessionId', 'Read-SessionBook', 'Save-SessionBook', 'Set-SessionRecord', 'Get-NewSessionPlan', 'Get-SessionPlan', 'Format-SessionPlan', 'Test-AgentScreen', 'Get-ResumeState', 'Wait-ResumeStates'
$want += 'Get-SelfTerm', 'Get-SelfPaneState'
# Chạy test từ pane thật: địa chỉ giả có thể trùng HC_TERMINAL_ID.
$env:HC_TERMINAL_ID = $null
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
$script:Said = [Collections.Generic.List[string]]::new()
function Say($msg) { $script:Said.Add([string]$msg) }
function Die($msg) { throw $msg }
$script:HcCalls = 0
function hc { $script:HcCalls++; throw 'gọi hc thật trong test' }
# sổ tên crew trỏ vào $TestDrive, không bao giờ ~/.crewline thật
$script:RegFile = ''
function Get-ProjectsFile { $script:RegFile }

function New-RegFile { $script:RegFile = Join-Path $TestDrive "projects-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"; $script:RegFile }
function New-Dir([string]$rel) { $d = Join-Path $TestDrive $rel; New-Item -ItemType Directory -Force $d | Out-Null; (Resolve-Path $d).Path }
# project giả có .crew/config.json (name tùy chọn)
function New-Project([string]$rel, [string]$name = '') {
  $d = New-Dir $rel
  New-Item -ItemType Directory -Force (Join-Path $d '.crew') | Out-Null
  $cfg = [ordered]@{}
  if ($name) { $cfg.name = $name }
  $cfg.planner = 'claude'; $cfg.workers = @('claude'); $cfg.rev = 'none'; $cfg.review = 'lean'; $cfg.access = 'work'
  $cfg | ConvertTo-Json | Set-Content (Join-Path $d '.crew/config.json') -Encoding utf8
  $d
}
function New-Repo([string]$rel, [string]$name) {
  $root = New-Project $rel $name
  git -C $root init -q -b main
  git -C $root config user.name t; git -C $root config user.email t@t; git -C $root config core.autocrlf false
  '.crew/' | Set-Content (Join-Path $root '.gitignore')
  'a' | Set-Content (Join-Path $root 'a.txt')
  git -C $root add -A; git -C $root commit -q -m init
  $root
}
function New-Term([string]$name, [string]$cwd, [string]$app = 'claude-code') {
  [pscustomobject]@{ name = $name; address = 't1'; state = 'live'; cwd = $cwd; status = [pscustomobject]@{ app = $app; state = 'idle' }; turn = 1 }
}
# đổi hoa thường + dấu tách để kiểm so đường dẫn chuẩn hóa (Windows)
function Get-Variant([string]$p) { if ($OnWindows) { ($p.ToUpperInvariant() -replace '\\', '/') + '/' } else { "$p/" } }

function New-FakeOps($info, $screens = @('')) {
  $st = @{ Info = $info; Screens = @($screens); Ri = 0; Keys = 0; Sent = [Collections.Generic.List[string]]::new() }
  @{
    State = $st
    Get   = { param($t) $st.Info }.GetNewClosure()
    Send  = { param($t, $x, $sh) $st.Sent.Add($x); @{ Code = 0; Text = '{"started":true}' } }.GetNewClosure()
    Keys  = { param($t) $st.Keys++ }.GetNewClosure()
    Sleep = { param($ms) }
    Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
  }
}

Describe 'Get-Slug (project mới) và Get-LegacySlug (project cũ)' {
  $cases = @(
    @{ Dir = 'work/app'; New = 'app'; Old = 'app' },
    @{ Dir = 'client/app'; New = 'app'; Old = 'app' },
    @{ Dir = 'customer-portal-v1'; New = 'customer-por'; Old = 'customer-por' },
    @{ Dir = 'customer-portal-v2'; New = 'customer-por'; Old = 'customer-por' },
    @{ Dir = 'My_App'; New = 'my-app'; Old = 'my-app' },
    @{ Dir = 'my-app'; New = 'my-app'; Old = 'my-app' },
    @{ Dir = 'Dự án Web'; New = 'du-an-web'; Old = 'd-n-web' },
    @{ Dir = 'Đồ Án Tốt Nghiệp'; New = 'do-an-tot-ng'; Old = 'n-t-t-nghi-p' },
    @{ Dir = '--A__b--'; New = 'a-b'; Old = 'a-b' }
  )
  foreach ($c in $cases) {
    It "$($c.Dir) -> mới '$($c.New)', cũ '$($c.Old)'" {
      $root = Join-Path $TestDrive $c.Dir
      Get-Slug $root | Should BeExactly $c.New
      Get-LegacySlug $root | Should BeExactly $c.Old
      Test-CrewName (Get-Slug $root) | Should Be $true
    }
  }
  It '项目 -> cũ rỗng, mới crew-<6 hex> theo hash root (cố định, khác nhau giữa 2 root)' {
    $a = Join-Path $TestDrive 'x/项目'; $b = Join-Path $TestDrive 'y/项目'
    Get-LegacySlug $a | Should BeExactly ''
    Get-Slug $a | Should Match '^crew-[0-9a-f]{6}$'
    Get-Slug $a | Should BeExactly (Get-Slug $a)
    Get-Slug $a | Should Not Be (Get-Slug $b)
    Test-CrewName (Get-Slug $a) | Should Be $true
  }
}

Describe 'Test-CrewName' {
  foreach ($ok in 'a', 'app', 'app-2', 'a1-b2-c3-d4e', '123456789012') { It "hợp lệ: $ok" { Test-CrewName $ok | Should Be $true } }
  foreach ($bad in '', '-app', 'app-', 'App', 'my_app', 'du án', '1234567890123', 'a/b') { It "không hợp lệ: '$bad'" { Test-CrewName $bad | Should Be $false } }
}

Describe 'Get-CrewName' {
  It 'config có name -> dùng name' {
    Get-CrewName (Join-Path $TestDrive 'Dự án Web') ([pscustomobject]@{ name = 'shop' }) | Should BeExactly 'shop'
  }
  It 'project cũ không có name -> slug cũ y hệt (kể cả tiếng Việt)' {
    Get-CrewName (Join-Path $TestDrive 'Dự án Web') ([pscustomobject]@{ planner = 'claude' }) | Should BeExactly 'd-n-web'
    Get-CrewName (Join-Path $TestDrive 'customer-portal-v2') ([pscustomobject]@{ planner = 'claude' }) | Should BeExactly 'customer-por'
  }
  It 'name sai -> dừng, nêu cách sửa' {
    { Get-CrewName $TestDrive ([pscustomobject]@{ name = 'Bad_Name' }) } | Should Throw 'crew init -Name'
  }
  It 'không name và slug cũ rỗng -> dừng, gợi ý upgrade/-Name' {
    { Get-CrewName (Join-Path $TestDrive '项目') ([pscustomobject]@{}) } | Should Throw 'crew upgrade'
  }
}

Describe 'Test-TermOwner / Get-ForeignTermError' {
  It 'root, worktree w1, khác hoa thường/dấu gạch -> của project; project khác, w-lạ, cha của root -> không' {
    $root = New-Dir 'own/app'
    $wt = Join-Path $root '.crew/worktrees/w1'
    Test-TermOwner (New-Term 'app-planner' $root) $root | Should Be $true
    Test-TermOwner (New-Term 'app-w1' $wt) $root | Should Be $true
    Test-TermOwner (New-Term 'app-w1' (Get-Variant $wt)) $root | Should Be $true
    Test-TermOwner (New-Term 'app-planner' (Get-Variant $root)) $root | Should Be $true
    Test-TermOwner (New-Term 'app-planner' (Join-Path $TestDrive 'other/app')) $root | Should Be $false
    Test-TermOwner (New-Term 'app-w1' (Join-Path $root '.crew/worktrees/task-a')) $root | Should Be $false
    Test-TermOwner (New-Term 'app-w1' (Join-Path $root 'src')) $root | Should Be $false
    Test-TermOwner (New-Term 'app-w1' (Split-Path $root -Parent)) $root | Should Be $false
  }
  It 'Get-ForeignTermError: chỉ báo khi live + có cwd + khác project' {
    $root = New-Dir 'own2/app'
    Get-ForeignTermError 'app-w1' (New-Term 'app-w1' $root) $root | Should BeExactly ''
    Get-ForeignTermError 'app-w1' $null $root | Should BeExactly ''
    Get-ForeignTermError 'app-w1' ([pscustomobject]@{ state = 'live' }) $root | Should BeExactly ''
    $dead = New-Term 'app-w1' 'C:\khac'; $dead.state = 'finished'
    Get-ForeignTermError 'app-w1' $dead $root | Should BeExactly ''
    $msg = Get-ForeignTermError 'app-w1' (New-Term 'app-w1' (Join-Path $TestDrive 'b/app')) $root
    $msg | Should Match 'app-w1 đang chạy ở project khác'
    $msg | Should Match 'crew init -Name'
  }
}

Describe 'sổ tên crew + chọn tên' {
  BeforeEach { New-RegFile | Out-Null; $script:Said.Clear() }

  It 'tên đã thuộc root khác còn tồn tại -> -2, -3; root cũ không còn -> dùng lại tên; giữ ≤12 ký tự' {
    $a = New-Project 'r1/app' 'app'; $b = New-Project 'r2/app' 'app-2'
    $c = New-Dir 'r3/app'
    $map = [ordered]@{ app = @{ Root = $a; IdKey = 'app' }; 'app-2' = @{ Root = $b; IdKey = 'appzd2' } }
    Resolve-CrewName 'app' $c $map | Should BeExactly 'app-3'
    Resolve-CrewName 'app' $a $map | Should BeExactly 'app'
    $map.app = @{ Root = (Join-Path $TestDrive 'mat/app'); IdKey = 'app' }
    Resolve-CrewName 'app' $c $map | Should BeExactly 'app'
    $long = New-Project 'r4/customer-portal-v1' 'customer-por'
    $n = Resolve-CrewName 'customer-por' (New-Dir 'r5/customer-portal-v2') ([ordered]@{ 'customer-por' = @{ Root = $long; IdKey = 'customerzdpor' } })
    $n | Should BeExactly 'customer-p-2'
    $n.Length -le 12 | Should Be $true
  }

  It 'Register-CrewName ghi sổ, bỏ tên cũ của cùng root; sổ hỏng -> cảnh báo, không ghi đè' {
    $a = New-Project 'g1/app' 'app'
    Register-CrewName 'app' $a 'app' | Out-Null
    Register-CrewName 'shop' $a 'shop' | Out-Null
    $j = Get-Content $script:RegFile -Raw | ConvertFrom-Json
    @($j.PSObject.Properties.Name) -join ',' | Should Be 'shop'
    $j.shop.root | Should Be (ConvertTo-RootKey $a)
    $j.shop.idKey | Should Be 'shop'
    'không phải json {' | Set-Content $script:RegFile
    (Read-ProjectRegistry).Ok | Should Be $false
    Register-CrewName 'app' $a 'app' | Out-Null
    (Get-Content $script:RegFile -Raw) | Should Match 'không phải json'
    ($script:Said -join '|') | Should Match 'sổ tên crew .* hỏng'
  }

  It 'Get-NameConflict: config chép nguyên thư mục (cùng name, root khác còn tồn tại) -> báo, gợi ý đổi name' {
    $a = New-Project 'c1/app' 'app'; $b = New-Project 'c2/app-copy' 'app'
    Register-CrewName 'app' $a 'app' | Out-Null
    Get-NameConflict $a (Get-Config $a) | Should BeExactly ''
    $msg = Get-NameConflict $b (Get-Config $b)
    $msg | Should Match "tên crew 'app'"
    $msg | Should Match ([regex]::Escape($a))
    $msg | Should Match 'crew init -Name'
  }
}

Describe 'crew upgrade ghi name cho project cũ (Update-ConfigName)' {
  BeforeEach { New-RegFile | Out-Null; $script:Said.Clear() }

  It 'chưa có name -> ghi name = slug cũ (không đổi tên), giữ các khóa khác, ghi sổ' {
    $root = New-Project 'u1/Dự án Web'
    Update-ConfigName $root $false
    $cfg = Get-Config $root
    $cfg.name | Should BeExactly 'd-n-web'
    $cfg.planner | Should Be 'claude'
    @($cfg.workers).Count | Should Be 1
    (Get-Content $script:RegFile -Raw | ConvertFrom-Json).'d-n-web'.root | Should Be (ConvertTo-RootKey $root)
    $cfg.idKey | Should BeExactly 'dnweb'
    Get-CrewName $root $cfg | Should BeExactly 'd-n-web'
  }
  It '-DryRun -> chỉ in, không ghi config/sổ' {
    $root = New-Project 'u2/app'
    $before = Get-Content (Join-Path $root '.crew/config.json') -Raw
    Update-ConfigName $root $true
    Get-Content (Join-Path $root '.crew/config.json') -Raw | Should BeExactly $before
    Test-Path $script:RegFile | Should Be $false
    ($script:Said -join '|') | Should Match "sẽ ghi name 'app'"
  }
  It 'đã có name + idKey -> không đổi' {
    $root = New-Project 'u3/app' 'shop'
    $c = Get-Config $root; $c | Add-Member idKey 'shop'; $c | ConvertTo-Json | Set-Content (Join-Path $root '.crew/config.json') -Encoding utf8
    $before = Get-Content (Join-Path $root '.crew/config.json') -Raw
    Update-ConfigName $root $false
    Get-Content (Join-Path $root '.crew/config.json') -Raw | Should BeExactly $before
  }
  It 'tên cũ đã thuộc project khác trong sổ -> vẫn ghi name (không đổi tên), không ghi đè sổ, cảnh báo' {
    $a = New-Project 'u4/app' 'app'; Register-CrewName 'app' $a 'app' | Out-Null
    $b = New-Project 'u5/app'
    Update-ConfigName $b $false
    (Get-Config $b).name | Should BeExactly 'app'
    (Get-Content $script:RegFile -Raw | ConvertFrom-Json).app.root | Should Be (ConvertTo-RootKey $a)
    ($script:Said -join '|') | Should Match 'đã thuộc project'
  }
}

Describe 'crew up chặn terminal cùng tên của project khác' {
  BeforeEach {
    New-RegFile | Out-Null
    $script:Started = [Collections.Generic.List[string]]::new(); $script:Stopped = 0; $script:Said.Clear()
    $script:Restart = ''; $script:Force = $false
    function Get-Root($p) { $p }
    function Get-MainBranch($p) { 'main' }
    $script:Herdr = @{ Ok = $true; Spaces = @() }
    function Get-HerdrSpaces { $script:Herdr }
    function Initialize-WorkerTree($r, $n, $m) { Join-Path $r ".crew/worktrees/w$n" }
    function Start-Term($n, $cwd, $sp, $tab, $cmd) { $script:Started.Add($n); @{ address = 'tx' } }
    function Start-WorkerTerm($r, $c, $ids, $slug, $n, $m) { $script:Started.Add("$slug-w$n"); @{ address = "t$n" } }
    function Stop-Term($a) { $script:Stopped++ }
    function Wait-Tab($t) { $false }
    function Show-StartupTrust($r, $o) { }
    function New-HcOps { @{ Get = { param($t) $null }; Read = { param($t) '' }; Sleep = { param($ms) } } }
  }

  It 'app-planner đang chạy ở project khác -> dừng, nêu tên + cwd kia, 0 bật/kill' {
    $root = New-Project 'up1/app' 'app'; $script:Path = $root
    $other = New-Project 'up2/app' 'app-2'
    function Get-LiveTerminals { @(New-Term 'app-planner' $other) }
    { Invoke-Up } | Should Throw 'app-planner đang chạy ở project khác'
    try { Invoke-Up } catch { $_.Exception.Message | Should Match ([regex]::Escape($other)) }
    $script:Started.Count | Should Be 0
    $script:Stopped | Should Be 0
  }

  It '-Restart không kill terminal của project khác' {
    $root = New-Project 'up3/app' 'app'; $script:Path = $root
    $script:Restart = 'all'
    function Get-LiveTerminals { @(New-Term 'app-w1' (Join-Path $TestDrive 'up4/app/.crew/worktrees/w1')) }
    { Invoke-Up } | Should Throw 'project khác'
    $script:Stopped | Should Be 0
    $script:Started.Count | Should Be 0
  }

  It 'cùng project (root + w1, khác hoa thường/dấu gạch) -> bỏ qua terminal đang chạy, không dừng' {
    $root = New-Project 'up5/app' 'app'; $script:Path = $root
    function Get-LiveTerminals { @((New-Term 'app-planner' (Get-Variant $root)), (New-Term 'app-w1' (Get-Variant (Join-Path $root '.crew/worktrees/w1')))) }
    Invoke-Up
    $script:Started.Count | Should Be 0
    ($script:Said -join '|') | Should Match 'app-planner đã chạy, bỏ qua'
    ($script:Said -join '|') | Should Match 'app-w1 đã chạy, bỏ qua'
  }

  It 'terminal cùng tên khác project nhưng không thuộc vai của config (vd app-rev khi rev=none) -> không chặn' {
    $root = New-Project 'up6/app' 'app'; $script:Path = $root
    function Get-LiveTerminals { @(New-Term 'app-rev' (Join-Path $TestDrive 'khac/app')) }
    Invoke-Up
    @($script:Started) -join ',' | Should Be 'app-planner,app-w1'
  }

  It 'config chép nguyên thư mục (name trùng sổ của root khác còn tồn tại) -> dừng, gợi ý đổi name' {
    $a = New-Project 'up7/app' 'app'; Register-CrewName 'app' $a 'app' | Out-Null
    $root = New-Project 'up8/app-copy' 'app'; $script:Path = $root
    function Get-LiveTerminals { @() }
    { Invoke-Up } | Should Throw 'crew init -Name'
    $script:Started.Count | Should Be 0
  }
}

Describe 'crew up chặn space/tab herdr trùng khóa id (project chưa vào sổ)' {
  BeforeEach {
    New-RegFile | Out-Null
    $script:Started = [Collections.Generic.List[string]]::new(); $script:Stopped = 0; $script:Said.Clear()
    $script:Restart = ''; $script:Force = $false
    function Get-Root($p) { $p }
    function Get-MainBranch($p) { 'main' }
    function Initialize-WorkerTree($r, $n, $m) { Join-Path $r ".crew/worktrees/w$n" }
    function Start-Term($n, $cwd, $sp, $tab, $cmd) { $script:Started.Add($n); @{ address = 'tx' } }
    function Start-WorkerTerm($r, $c, $ids, $slug, $n, $m) { $script:Started.Add("$slug-w$n"); @{ address = "t$n" } }
    function Stop-Term($a) { $script:Stopped++ }
    function Wait-Tab($t) { $false }
    function Show-StartupTrust($r, $o) { }
    function New-HcOps { @{ Get = { param($t) $null }; Read = { param($t) '' }; Sleep = { param($ms) } } }
    function Get-HerdrSpaces { $script:Herdr }
    # project mới myapp: name myapp, idKey myapp (mã hóa mới) — sổ chỉ biết nó
    $script:New = New-Project "sp-$([guid]::NewGuid().ToString('N').Substring(0, 6))/myapp" 'myapp'
    $c = Get-Config $script:New; $c | Add-Member idKey 'myapp'; $c | ConvertTo-Json | Set-Content (Join-Path $script:New '.crew/config.json') -Encoding utf8
    Register-CrewName 'myapp' $script:New 'myapp' | Out-Null
    $script:Path = $script:New
  }
  function New-Space([string]$id, [string]$folder, $tabs = @()) { [pscustomobject]@{ id = $id; folder = $folder; tabs = @($tabs) } }
  function New-Tab([string]$id, [string[]]$addrs = @()) { [pscustomobject]@{ id = $id; terminals = @($addrs | ForEach-Object { [pscustomobject]@{ terminal = $_ } }) } }

  It 'repro Rev: my-app cũ đang live (chưa name/idKey, chưa vào sổ, khóa cũ myapp) + myapp mới -> up dừng, 0 Start/kill' {
    $old = New-Project 'sp-old/my-app'
    Get-CrewIdKey $old (Get-Config $old) | Should BeExactly 'myapp'
    Get-NameConflict $script:New (Get-Config $script:New) | Should BeExactly ''
    $script:Herdr = @{ Ok = $true; Spaces = @(New-Space 'spcrewmyapp' $old @((New-Tab 'tbcrewmyappplanner' @('t9')))) }
    function Get-LiveTerminals { @([pscustomobject]@{ name = 'my-app-planner'; address = 't9'; state = 'live'; cwd = $old }) }
    { Invoke-Up } | Should Throw 'space spcrewmyapp của herdr đang thuộc thư mục'
    try { Invoke-Up } catch { $_.Exception.Message | Should Match 'crew init -Name' ; $_.Exception.Message | Should Match ([regex]::Escape($old)) }
    $script:Started.Count | Should Be 0
    $script:Stopped | Should Be 0
  }

  It 'space không có folder nhưng terminal trong đó có cwd ở project khác -> dừng' {
    $old = New-Project 'sp-old2/my-app'
    $script:Herdr = @{ Ok = $true; Spaces = @(New-Space 'spcrewmyapp' '' @((New-Tab 'x' @('t9')))) }
    function Get-LiveTerminals { @([pscustomobject]@{ name = 'my-app-w1'; address = 't9'; state = 'live'; cwd = (Join-Path $old '.crew/worktrees/w1') }) }
    { Invoke-Up } | Should Throw 'có terminal my-app-w1'
    $script:Started.Count | Should Be 0
  }

  It 'chỉ tab id tbcrewmyapp… nằm trong space khác của project khác -> dừng' {
    $old = New-Project 'sp-old3/x'
    $script:Herdr = @{ Ok = $true; Spaces = @(New-Space 'spkhac' $old @((New-Tab 'tbcrewmyappworkers1'))) }
    function Get-LiveTerminals { @() }
    { Invoke-Up } | Should Throw 'tab tbcrewmyappworkers1'
    $script:Started.Count | Should Be 0
  }

  It 'space của chính project (folder = root, khác hoa thường/dấu gạch; hoặc worktree w1) -> chạy bình thường' {
    $script:Herdr = @{ Ok = $true; Spaces = @(New-Space 'spcrewmyapp' (Get-Variant $script:New) @((New-Tab 'tbcrewmyappplanner'))) }
    function Get-LiveTerminals { @() }
    Invoke-Up
    @($script:Started) -join ',' | Should Be 'myapp-planner,myapp-w1'
    $script:Started.Clear()
    $script:Herdr = @{ Ok = $true; Spaces = @(New-Space 'spcrewmyapp' (Join-Path $script:New '.crew/worktrees/w1')) }
    Invoke-Up
    $script:Started.Count | Should Be 2
  }

  It 'herdr-app ls hỏng/không có -> cảnh báo, không chặn (vẫn kiểm terminal cùng tên)' {
    $script:Herdr = @{ Ok = $false; Spaces = @(); Error = 'herdr-app ls lỗi (mã 1)' }
    function Get-LiveTerminals { @() }
    Invoke-Up
    $script:Started.Count | Should Be 2
    ($script:Said -join '|') | Should Match 'không kiểm được space herdr'
  }

  It 'init: khóa đang bị space live của project khác dùng -> tự chọn -2; space của chính mình -> giữ tên' {
    $old = New-Project 'sp-old4/my-app'
    $b = New-Dir 'sp-new4/myapp'
    $spaces = @((New-Space 'spcrewmyapp' $old), (New-Space 'spcrewcrewline' $b))
    $taken = Get-TakenIdKeys $spaces $b
    @($taken) -join ',' | Should Be 'myapp'
    Resolve-CrewName 'myapp' $b ([ordered]@{}) $taken | Should BeExactly 'myapp-2'
    Resolve-CrewName 'myapp' $old ([ordered]@{}) (Get-TakenIdKeys $spaces $old) | Should BeExactly 'myapp'
  }
}

Describe 'crew task chặn worker của project khác (Start-WorkerTask)' {
  BeforeEach { $script:HcCalls = 0 }

  It 'app-w1 cwd ở project khác -> dừng trước khi đụng git, 0 Send/Keys, không ghi task' {
    $root = New-Repo 'tk1/app' 'app'
    $prompt = Join-Path $TestDrive 'p1.md'; 'việc' | Set-Content $prompt -Encoding utf8
    $ops = New-FakeOps (New-Term 'app-w1' (Join-Path $TestDrive 'tk2/app/.crew/worktrees/w1'))
    $wt = Get-WorkerTree $root 1
    $tasks = @(New-TaskRecord 'a' 'crew/a' $wt 1 'app-w1' 'claude' '')
    { Start-WorkerTask $root 'main' 1 'claude' 'work' 'app-w1' 'a' $prompt $tasks $ops } | Should Throw 'project khác'
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    git -C $root show-ref --verify --quiet 'refs/heads/crew/a'; $LASTEXITCODE | Should Not Be 0
    Test-Path (Join-Path $root '.crew/tasks.json') | Should Be $false
    $script:HcCalls | Should Be 0
  }

  It 'app-w1 cwd = w1 của chính project (khác hoa thường/dấu gạch) -> giao việc bình thường' {
    $root = New-Repo 'tk3/app' 'app'
    $prompt = Join-Path $TestDrive 'p3.md'; 'việc' | Set-Content $prompt -Encoding utf8
    $wt = Get-WorkerTree $root 1
    $cleared = "❯ /clear`n  ⎿  (no content)`n────`n❯`n────"
    $ops = New-FakeOps (New-Term 'app-w1' (Get-Variant $wt)) @($cleared)
    $tasks = @(New-TaskRecord 'a' 'crew/a' $wt 1 'app-w1' 'claude' '')
    $res = Start-WorkerTask $root 'main' 1 'claude' 'work' 'app-w1' 'a' $prompt $tasks $ops
    $res.Ok | Should Be $true
    @($ops.State.Sent) -join '|' | Should Be ('/clear|' + (Get-TaskLine $wt 'crew/a'))
    $script:HcCalls | Should Be 0
  }
}

Describe 'crew send chặn terminal mang tên crew này nhưng của project khác' {
  BeforeEach { $script:Said.Clear() }

  It 'app-w1 ở project khác -> dừng, 0 Send/Keys; terminal tên khác (không mang tên crew) vẫn gửi' {
    $root = New-Repo 'sd1/app' 'app'
    $script:Ops = New-FakeOps (New-Term 'app-w1' (Join-Path $TestDrive 'sd2/app'))
    function New-HcOps { $script:Ops }
    $Raw = [switch]$false; $PromptFile = 'xin chào'
    Push-Location $root
    try {
      $Name = 'app-w1'
      { Invoke-Send } | Should Throw 'project khác'
      $script:Ops.State.Sent.Count | Should Be 0
      $script:Ops.State.Keys | Should Be 0
      $Name = 'kho-planner'
      Invoke-Send
      $script:Ops.State.Sent.Count | Should Be 1
    } finally { Pop-Location }
  }

  It 'app-w1 là w1 của chính project, gọi từ trong worktree -> gửi bình thường' {
    $root = New-Repo 'sd3/app' 'app'
    $wt = Initialize-WorkerTree $root 1 'main'
    $script:Ops = New-FakeOps (New-Term 'app-w1' (Get-Variant $wt))
    function New-HcOps { $script:Ops }
    $Raw = [switch]$false; $PromptFile = 'xin chào'; $Name = 'app-w1'
    Push-Location $wt
    try { Invoke-Send } finally { Pop-Location }
    @($script:Ops.State.Sent) -join '|' | Should Be 'xin chào'
  }
}

Describe 'khóa id herdr (idKey) đơn ánh' {
  BeforeEach { New-RegFile | Out-Null; $script:Said.Clear() }

  It 'mã hóa: z->zz, - ->zd; my-app/myapp, app-2/app2 khác khóa, khác space + mọi tab id' {
    ConvertTo-IdKey 'my-app' | Should BeExactly 'myzdapp'
    ConvertTo-IdKey 'myapp' | Should BeExactly 'myapp'
    ConvertTo-IdKey 'app-2' | Should BeExactly 'appzd2'
    ConvertTo-IdKey 'app2' | Should BeExactly 'app2'
    ConvertTo-IdKey 'pizza' | Should BeExactly 'pizzzza'
    $names = 'my-app', 'myapp', 'app-2', 'app2', 'a-zd', 'azzd', 'a-d', 'azd', 'z-', 'zzd', 'zd'
    $keys = @($names | ForEach-Object { ConvertTo-IdKey $_ })
    @($keys | Select-Object -Unique).Count | Should Be $names.Count
    foreach ($pair in @(@('my-app', 'myapp'), @('app-2', 'app2'))) {
      $x = Get-Ids (ConvertTo-IdKey $pair[0]); $y = Get-Ids (ConvertTo-IdKey $pair[1])
      $x.Space | Should Not Be $y.Space
      $ix = @($x.Space, $x.Planner, $x.Rev) + @(1..3 | ForEach-Object { & $x.Workers $_ })
      $iy = @($y.Space, $y.Planner, $y.Rev) + @(1..3 | ForEach-Object { & $y.Workers $_ })
      @($ix | Where-Object { $iy -contains $_ }).Count | Should Be 0
    }
  }

  It 'Get-CrewIdKey: config idKey > khóa cũ từ name > khóa cũ từ slug cũ (project cũ giữ space cũ)' {
    Get-CrewIdKey $TestDrive ([pscustomobject]@{ name = 'my-app'; idKey = 'myzdapp' }) | Should BeExactly 'myzdapp'
    Get-CrewIdKey $TestDrive ([pscustomobject]@{ name = 'my-app' }) | Should BeExactly 'myapp'
    Get-CrewIdKey (Join-Path $TestDrive 'My_App') ([pscustomobject]@{ planner = 'claude' }) | Should BeExactly 'myapp'
    { Get-CrewIdKey $TestDrive ([pscustomobject]@{ name = 'a'; idKey = 'My-Key' }) } | Should Throw 'idKey'
  }

  It 'upgrade project cũ my-app: name my-app, idKey = khóa cũ myapp (space spcrewmyapp không đổi), sổ lưu idKey' {
    $root = New-Project 'ik1/my-app'
    $before = (Get-Ids (Get-CrewIdKey $root (Get-Config $root))).Space
    Update-ConfigName $root $false
    $cfg = Get-Config $root
    $cfg.name | Should BeExactly 'my-app'
    $cfg.idKey | Should BeExactly 'myapp'
    (Get-Ids (Get-CrewIdKey $root $cfg)).Space | Should BeExactly $before
    $before | Should BeExactly 'spcrewmyapp'
    (Get-Content $script:RegFile -Raw | ConvertFrom-Json).'my-app'.idKey | Should BeExactly 'myapp'
  }

  It 'upgrade: đã có name nhưng thiếu idKey -> idKey = name bỏ -, giữ name' {
    $root = New-Project 'ik2/x' 'app-2'
    Update-ConfigName $root $false
    (Get-Config $root).idKey | Should BeExactly 'app2'
    (Get-Config $root).name | Should BeExactly 'app-2'
  }

  It 'sổ kiểu cũ (tên -> root) vẫn đọc được, idKey = khóa cũ' {
    $a = New-Project 'ik3/my-app'
    @{ 'my-app' = $a } | ConvertTo-Json | Set-Content $script:RegFile
    $reg = Read-ProjectRegistry
    $reg.Ok | Should Be $true
    $reg.Map.'my-app'.IdKey | Should BeExactly 'myapp'
    $reg.Map.'my-app'.Root | Should Be $a
  }

  It 'tên mới myapp mà khóa myapp đã thuộc project cũ my-app còn tồn tại -> chọn myapp-2' {
    $old = New-Project 'ik4/my-app'
    Update-ConfigName $old $false
    Resolve-CrewName 'myapp' (New-Dir 'ik5/myapp') (Read-ProjectRegistry).Map | Should BeExactly 'myapp-2'
  }

  It 'project cũ trùng khóa cũ với project khác còn tồn tại -> Get-NameConflict báo khóa id, không tự đổi' {
    $a = New-Project 'ik6/myapp' 'myapp'
    Register-CrewName 'myapp' $a 'myapp' | Out-Null
    $b = New-Project 'ik7/my-app'
    $before = Get-Content (Join-Path $b '.crew/config.json') -Raw
    $msg = Get-NameConflict $b (Get-Config $b)
    $msg | Should Match "khóa id herdr 'myapp'"
    $msg | Should Match ([regex]::Escape($a))
    $msg | Should Match 'crew init -Name'
    Get-Content (Join-Path $b '.crew/config.json') -Raw | Should BeExactly $before
  }

  It 'Register-CrewName: tên đã thuộc root khác còn tồn tại -> giữ chủ cũ, không ghi, cảnh báo' {
    $a = New-Project 'ik8/app' 'app'; $b = New-Project 'ik9/app-copy' 'app'
    Register-CrewName 'app' $a 'app' | Should Be $true
    Register-CrewName 'app' $b 'app' | Should Be $false
    (Get-Content $script:RegFile -Raw | ConvertFrom-Json).app.root | Should Be (ConvertTo-RootKey $a)
    ($script:Said -join '|') | Should Match 'giữ nguyên chủ cũ'
  }
}

Describe 'crew init: tên crew + sổ (HOME giả)' {
  $savedEncoding = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  try {
    BeforeEach {
      $h = New-CrewTestHome
      Set-Content (Join-Path $h.Home 'gitconfig') "[user]`n`tname = test`n`temail = test@example.invalid`n[core]`n`tautocrlf = false"
      $env1 = @{}
      if ($OnWindows) { $env1.Path = (($env:Path -split ';') | Where-Object { $_ -and ($PSHOME -notmatch '\\WindowsApps\\' -or $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\')) }) -join ';' }
      $reg = Join-Path $h.Home '.crewline/projects.json'
    }
    function Invoke-CrewInit([string]$dir, [string[]]$extra = @()) {
      New-Item -ItemType Directory -Force $dir | Out-Null
      Invoke-InTestHome -TestHome $h -File $crewScript -Env $env1 -Arguments (@('init', '-Path', $dir, '-GitInit', '-NoCommit') + $extra)
    }
    function Read-Name([string]$dir) { (Get-Content (Join-Path $dir '.crew/config.json') -Raw | ConvertFrom-Json).name }

    It '2 project cùng tên thư mục -> app, app-2; sổ ghi đúng root; init lại giữ tên' {
      $a = Join-Path $h.Home 'work/app'; $b = Join-Path $h.Home 'client/app'
      $r1 = Invoke-CrewInit $a
      $r1.ExitCode | Should Be 0
      Read-Name $a | Should BeExactly 'app'
      $r2 = Invoke-CrewInit $b
      $r2.ExitCode | Should Be 0
      Read-Name $b | Should BeExactly 'app-2'
      $r2.Output | Should Match "tên 'app' .*đã thuộc project .* dùng tên 'app-2'"
      $r2.Output | Should Match 'tên crew: app-2'
      $j = Get-Content $reg -Raw | ConvertFrom-Json
      (@($j.PSObject.Properties.Name) | Sort-Object) -join ',' | Should Be 'app,app-2'
      Test-SamePath $j.app.root $a | Should Be $true
      Test-SamePath $j.'app-2'.root $b | Should Be $true
      $j.'app-2'.idKey | Should BeExactly 'appzd2'
      $r3 = Invoke-CrewInit $b
      $r3.ExitCode | Should Be 0
      Read-Name $b | Should BeExactly 'app-2'
    }

    It 'thư mục tiếng Việt -> tên bỏ dấu' {
      $d = Join-Path $h.Home 'Dự án Web'
      (Invoke-CrewInit $d).ExitCode | Should Be 0
      Read-Name $d | Should BeExactly 'du-an-web'
    }

    It '-Name hợp lệ -> dùng đúng tên; -Name đã thuộc project khác -> dừng' {
      $a = Join-Path $h.Home 'p/app'; $b = Join-Path $h.Home 'q/app'
      (Invoke-CrewInit $a @('-Name', 'shop-web')).ExitCode | Should Be 0
      Read-Name $a | Should BeExactly 'shop-web'
      $r = Invoke-CrewInit $b @('-Name', 'shop-web')
      $r.ExitCode | Should Be 1
      $r.Output | Should Match "tên crew 'shop-web' đã thuộc project"
      Test-Path (Join-Path $b '.crew/config.json') | Should Be $false
    }

    It 'my-app và myapp -> idKey myzdapp / myapp (space khác nhau); -Name app-2 / app2 -> appzd2 / app2' {
      $a = Join-Path $h.Home 'm1/my-app'; $b = Join-Path $h.Home 'm2/myapp'
      (Invoke-CrewInit $a).ExitCode | Should Be 0
      (Invoke-CrewInit $b).ExitCode | Should Be 0
      $ca = Get-Content (Join-Path $a '.crew/config.json') -Raw | ConvertFrom-Json
      $cb = Get-Content (Join-Path $b '.crew/config.json') -Raw | ConvertFrom-Json
      $ca.idKey | Should BeExactly 'myzdapp'
      $cb.name | Should BeExactly 'myapp'
      $cb.idKey | Should BeExactly 'myapp'
      $c = Join-Path $h.Home 'm3/x'; $d = Join-Path $h.Home 'm4/y'
      (Invoke-CrewInit $c @('-Name', 'app-2')).ExitCode | Should Be 0
      (Invoke-CrewInit $d @('-Name', 'app2')).ExitCode | Should Be 0
      (Get-Content (Join-Path $c '.crew/config.json') -Raw | ConvertFrom-Json).idKey | Should BeExactly 'appzd2'
      (Get-Content (Join-Path $d '.crew/config.json') -Raw | ConvertFrom-Json).idKey | Should BeExactly 'app2'
    }

    It 'bản sao (chép nguyên .crew/config.json) init lại -> không ghi đè chủ cũ trong sổ, báo + gợi ý -Name' {
      $a = Join-Path $h.Home 'c1/app'; $b = Join-Path $h.Home 'c2/app-copy'
      (Invoke-CrewInit $a).ExitCode | Should Be 0
      New-Item -ItemType Directory -Force (Join-Path $b '.crew') | Out-Null
      Copy-Item (Join-Path $a '.crew/config.json') (Join-Path $b '.crew/config.json')
      $r = Invoke-CrewInit $b
      $r.ExitCode | Should Be 1
      $r.Output | Should Match 'bản chép.*bản sao'
      $r.Output | Should Match 'crew init -Name'
      $j = Get-Content $reg -Raw | ConvertFrom-Json
      Test-SamePath $j.app.root $a | Should Be $true
      @($j.PSObject.Properties.Name) -join ',' | Should Be 'app'
    }

    It '-Name không hợp lệ -> dừng trước khi đụng git/context' {
      foreach ($bad in 'Shop', '-shop', 'shop-', 'quá-dài-tên-crew', 'a_b') {
        $d = Join-Path $h.Home "bad$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $r = Invoke-CrewInit $d @('-Name', $bad)
        $r.ExitCode | Should Be 1
        $r.Output | Should Match '-Name .* không hợp lệ'
        Test-Path (Join-Path $d '.git') | Should Be $false
        Test-Path (Join-Path $d 'context') | Should Be $false
      }
      Test-Path $reg | Should Be $false
    }
  } finally {
    [Console]::OutputEncoding = $savedEncoding
  }
}
