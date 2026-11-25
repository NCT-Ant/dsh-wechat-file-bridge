# WechatBridge.ps1 -- Windows-side driver for the dsh-wechat-bridge plugin.
#
# Reads one JSON request from stdin, prints one JSON line to stdout.
# All human-readable strings come from the Node side, so this file stays
# pure ASCII; that avoids the Windows PowerShell 5.1 ANSI-vs-UTF8 trap.
#
# Actions:
#   status    -> wechat process / window / lock state / account dirs
#   list      -> newest received files under msg\file\<YYYY-MM>
#   snapshot  -> PrintWindow capture of the main window -> png path
#   focus     -> restore + bring the main window to the foreground
#   send-text -> send a text message to a chat (default: the helper chat)
#   send-file -> send one file to a chat via the clipboard file list
#
# The WeChat 4.x client is a Qt application with a self-drawn UI: there is no
# UI Automation tree and posted key messages are ignored, so sending requires
# a real foreground window plus injected input. All send actions therefore
# refuse to run while the workstation is locked.

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 ignores Console.InputEncoding when stdin is a pipe: it
# decodes the stream with the ANSI code page instead, so a UTF-8 chat name such
# as the default one arrives as mojibake. The search then matches nothing, Enter
# opens no conversation, and the following paste+Enter lands in whatever chat was
# open (this actually sent a file into a group chat). Read the raw stream as UTF-8.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
$stdinStream = [Console]::OpenStandardInput()
$stdinReader = New-Object System.IO.StreamReader($stdinStream, (New-Object System.Text.UTF8Encoding($false)))
$rawIn = $stdinReader.ReadToEnd()
$stdinReader.Dispose()
$req = @{}
if ($rawIn -and $rawIn.Trim().Length -gt 0) {
  $req = $rawIn | ConvertFrom-Json
}
$action = if ($req.action) { [string]$req.action } else { 'status' }
$action = $action -replace '_', '-'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Wxb {
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint f, bool inherit, uint access);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int idx, StringBuilder buf, int len, out int needed);
  [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out IntPtr res);
  public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

  public const uint ES_CONTINUOUS = 0x80000000;
  public const uint ES_SYSTEM_REQUIRED = 0x00000001;
  public const uint ES_DISPLAY_REQUIRED = 0x00000002;
  public const uint WM_SYSCOMMAND = 0x0112;
  public const uint SC_MONITORPOWER = 0xF170;
  public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);
  public const byte VK_SHIFT = 0x10;

  public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
  public const uint MOUSEEVENTF_LEFTUP = 0x0004;
  public const byte VK_CONTROL = 0x11;
  public const byte VK_RETURN = 0x0D;
  public const byte VK_A = 0x41;
  public const byte VK_V = 0x56;
  public const byte VK_ESCAPE = 0x1B;

  public static void Click(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(90);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(45);
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
  }

  public static void KeyTap(byte vk) {
    keybd_event(vk, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(35);
    keybd_event(vk, 0, 2, UIntPtr.Zero);
  }

  public static void Combo(byte modifier, byte key) {
    keybd_event(modifier, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(30);
    keybd_event(key, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(35);
    keybd_event(key, 0, 2, UIntPtr.Zero);
    System.Threading.Thread.Sleep(30);
    keybd_event(modifier, 0, 2, UIntPtr.Zero);
  }
}
'@

$script:MainHwnd = [IntPtr]::Zero

function Get-WeixinProcesses {
  @(Get-Process -Name Weixin -ErrorAction SilentlyContinue)
}

# The 4.x main window is a visible Qt top-level window owned by Weixin.exe.
# Older builds use class "WeChatMainWndForPC"; both are accepted.
function Find-WeixinWindow {
  $procs = Get-WeixinProcesses
  if (-not $procs -or $procs.Count -eq 0) { return [IntPtr]::Zero }
  $ids = @($procs | ForEach-Object { $_.Id })
  $script:MainHwnd = [IntPtr]::Zero
  $cb = [Wxb+EnumWindowsProc]{
    param($h, $l)
    $procId = 0
    [void][Wxb]::GetWindowThreadProcessId($h, [ref]$procId)
    if ($ids -notcontains $procId) { return $true }
    if (-not [Wxb]::IsWindowVisible($h)) { return $true }
    $cls = New-Object System.Text.StringBuilder 256
    [void][Wxb]::GetClassName($h, $cls, 256)
    $cn = $cls.ToString()
    if ($cn -eq 'WeChatMainWndForPC' -or $cn -match '^Qt\d+QWindowIcon$') {
      $script:MainHwnd = $h
      return $false
    }
    return $true
  }
  [void][Wxb]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:MainHwnd
}

function Test-Locked {
  # The modern lock screen is a CoreWindow owned by LockApp on the default
  # desktop, so OpenInputDesktop still reports "Default" while the session is
  # actually locked. The reliable signal is the foreground window owner.
  try {
    $fg = [Wxb]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return $true }
    $procId = 0
    [void][Wxb]::GetWindowThreadProcessId($fg, [ref]$procId)
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p -and ($p.ProcessName -in @('LockApp', 'LogonUI', 'Winlogon'))) { return $true }
    return $false
  } catch { return $true }
}

function Get-IdleSeconds {
  $lii = New-Object Wxb+LASTINPUTINFO
  $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
  if ([Wxb]::GetLastInputInfo([ref]$lii)) {
    $now = [Environment]::TickCount
    $d = [int64]($now - [int64]$lii.dwTime)
    if ($d -lt 0) { $d += 4294967296 }
    return [math]::Round($d / 1000.0, 1)
  }
  return -1
}

function Wake-Screen {
  # Two independent wake paths: DPMS power-on, then a harmless SHIFT tap so the
  # input stack also registers activity (some panels ignore the first one).
  $out = [IntPtr]::Zero
  try {
    [void][Wxb]::SendMessageTimeout([Wxb]::HWND_BROADCAST, [Wxb]::WM_SYSCOMMAND, [IntPtr]0xF170, [IntPtr](-1), 0x0002, 500, [ref]$out)
  } catch { }
  try { [Wxb]::KeyTap([Wxb]::VK_SHIFT) } catch { }
}

function Sleep-Screen {
  $out = [IntPtr]::Zero
  try {
    [void][Wxb]::SendMessageTimeout([Wxb]::HWND_BROADCAST, [Wxb]::WM_SYSCOMMAND, [IntPtr]0xF170, [IntPtr]2, 0x0002, 500, [ref]$out)
  } catch { }
}

# Runs a send body with the panel temporarily lit. When the user has been away
# long enough that the display is probably off, the screen is woken first (which
# does NOT unlock a locked session) and turned back off afterwards, so a file can
# go out while nobody is sitting in front of the machine without leaving it lit.
$script:SEND_LEASE_FILE = Join-Path $env:TEMP 'dsh-wechat-send.lease'

# Hand the lock-screen guard a lease while a send is in flight, so it holds off
# on blanking or locking the display for the duration of the operation.
function Enter-SendLease([int]$Seconds = 240) {
  try {
    $payload = [ordered]@{
      pid     = $PID
      expires = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [int64]($Seconds * 1000)
      note    = ('wechat ' + $action)
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($script:SEND_LEASE_FILE, $payload, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Exit-SendLease {
  try { Remove-Item -LiteralPath $script:SEND_LEASE_FILE -Force -ErrorAction SilentlyContinue } catch { }
}

function Invoke-WithScreen([scriptblock]$Body, [int]$IdleWakeSec = 300) {
  $woke = $false
  Enter-SendLease
  try {
    # A locked session is a hard stop: injected input goes to the logon desktop
    # and is dropped, so waking the display would only surface the login screen.
    # Report the state instead, and let the caller queue the send.
    if (Test-Locked) {
      return [ordered]@{
        ok        = $false
        locked    = $true
        errorCode = 'locked'
        message   = 'the workstation is locked; the send is queued and replays after unlock'
      }
    }
    $idle = Get-IdleSeconds
    $woke = ($idle -lt 0 -or $idle -ge $IdleWakeSec)
    if ($woke) {
      try { [void][Wxb]::SetThreadExecutionState([Wxb]::ES_CONTINUOUS -bor [Wxb]::ES_SYSTEM_REQUIRED -bor [Wxb]::ES_DISPLAY_REQUIRED) } catch { }
      Wake-Screen
      Start-Sleep -Milliseconds 1200
      # The wake can surface a lock screen that was already engaged, so re-check
      # before driving any input at it.
      if (Test-Locked) {
        return [ordered]@{
          ok        = $false
          locked    = $true
          errorCode = 'locked'
          message   = 'the display woke up but the workstation is locked; the send is queued'
        }
      }
    }
    return (& $Body)
  } finally {
    Exit-SendLease
    if ($woke) {
      # Let the display blank again right away; the session stays unlocked on
      # purpose, otherwise the next run would need a password.
      try { [void][Wxb]::SetThreadExecutionState([Wxb]::ES_CONTINUOUS) } catch { }
      Sleep-Screen
    }
  }
}

function Get-AccountRoot {
  $base = Join-Path $env:USERPROFILE 'Documents\xwechat_files'
  if (-not (Test-Path $base)) { return $null }
  $dirs = @(Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'wxid_*' })
  if ($dirs.Count -eq 0) { return $null }
  # The logged-in account is the one still being written to. Directory mtimes
  # are unreliable on Windows, so sample the newest *file* inside each account:
  # the -wal sidecar of the session store is touched on every session change.
  $best = $null
  $bestStamp = [datetime]::MinValue
  foreach ($d in $dirs) {
    $probes = @()
    $sessDir = Join-Path $d.FullName 'db_storage\session'
    if (Test-Path $sessDir) { $probes += @(Get-ChildItem $sessDir -File -ErrorAction SilentlyContinue) }
    $fileDir = Join-Path $d.FullName 'msg\file'
    if (Test-Path $fileDir) { $probes += @(Get-ChildItem $fileDir -Recurse -File -ErrorAction SilentlyContinue) }
    $stamp = [datetime]::MinValue
    foreach ($p in $probes) { if ($p.LastWriteTime -gt $stamp) { $stamp = $p.LastWriteTime } }
    if ($stamp -eq [datetime]::MinValue) { $stamp = $d.LastWriteTime }
    if ($stamp -gt $bestStamp) { $bestStamp = $stamp; $best = $d }
  }
  return [pscustomobject]@{ Path = $best.FullName; Wxid = $best.Name; LastWrite = $bestStamp }
}

function Get-WeixinVersion {
  $exe = 'C:\Program Files\Tencent\Weixin\Weixin.exe'
  if (Test-Path $exe) { return (Get-Item $exe).VersionInfo.FileVersion }
  return $null
}

function Get-WindowRectOrNull([IntPtr]$h) {
  $r = New-Object Wxb+RECT
  if ([Wxb]::GetWindowRect($h, [ref]$r)) {
    return [pscustomobject]@{ L = $r.L; T = $r.T; Width = $r.R - $r.L; Height = $r.B - $r.T }
  }
  return $null
}

function Invoke-Status {
  $procs = Get-WeixinProcesses
  $hwnd = Find-WeixinWindow
  $acct = Get-AccountRoot
  $locked = Test-Locked
  $rect = if ($hwnd -ne [IntPtr]::Zero) { Get-WindowRectOrNull $hwnd } else { $null }
  $fg = [Wxb]::GetForegroundWindow()
  return [ordered]@{
    ok            = ($procs.Count -gt 0)
    weixinRunning = ($procs.Count -gt 0)
    processCount  = $procs.Count
    pid           = if ($procs.Count -gt 0) { $procs[0].Id } else { 0 }
    version       = Get-WeixinVersion
    windowHandle  = [int64]$hwnd
    windowRect    = $rect
    minimized     = if ($hwnd -ne [IntPtr]::Zero) { [Wxb]::IsIconic($hwnd) } else { $false }
    foreground    = ($fg -eq $hwnd)
    locked        = $locked
    accountDir    = if ($acct) { $acct.Path } else { $null }
    wxid          = if ($acct) { $acct.Wxid } else { $null }
    inboxDir      = if ($acct) { Join-Path $acct.Path ('msg\file\' + (Get-Date -Format 'yyyy-MM')) } else { $null }
    canSend       = (($procs.Count -gt 0) -and ($hwnd -ne [IntPtr]::Zero) -and (-not $locked))
  }
}

function Invoke-List {
  $acct = Get-AccountRoot
  if (-not $acct) { return [ordered]@{ ok = $false; message = 'xwechat_files account directory not found'; files = @() } }
  $root = Join-Path $acct.Path 'msg\file'
  if (-not (Test-Path $root)) { return [ordered]@{ ok = $false; message = 'msg\file not found'; files = @() } }

  $limit = if ($req.limit) { [int]$req.limit } else { 20 }
  $sinceDays = if ($null -ne $req.sinceDays) { [int]$req.sinceDays } else { 0 }
  $sinceIso = [string]$req.since
  $cutoff = $null
  if ($sinceIso) {
    try { $cutoff = [datetime]::Parse($sinceIso) } catch { $cutoff = $null }
  }
  if (-not $cutoff -and $sinceDays -gt 0) { $cutoff = (Get-Date).AddDays(-$sinceDays) }

  $files = @(Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '*.db*' } |
    Sort-Object LastWriteTime -Descending)
  if ($cutoff) { $files = @($files | Where-Object { $_.LastWriteTime -ge $cutoff }) }
  $files = @($files | Select-Object -First $limit)

  $items = @()
  foreach ($f in $files) {
    $items += [ordered]@{
      name     = $f.Name
      path     = $f.FullName
      size     = $f.Length
      sizeText = if ($f.Length -ge 1MB) { '{0:N1} MB' -f ($f.Length / 1MB) }
                 elseif ($f.Length -ge 1KB) { '{0:N1} KB' -f ($f.Length / 1KB) }
                 else { "$($f.Length) B" }
      receivedAt = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
      monthDir = $f.Directory.Name
    }
  }
  return [ordered]@{
    ok         = $true
    accountDir = $acct.Path
    inboxDir   = Join-Path $acct.Path 'msg\file'
    count      = $items.Count
    files      = $items
    note       = 'WeChat stores files from every chat in this tree; use the filename and time to pick the ones that came from the file-transfer helper.'
  }
}

function Invoke-Snapshot {
  $hwnd = Find-WeixinWindow
  if ($hwnd -eq [IntPtr]::Zero) { return [ordered]@{ ok = $false; message = 'WeChat main window not found' } }
  $rect = Get-WindowRectOrNull $hwnd
  if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) {
    return [ordered]@{ ok = $false; message = 'WeChat window has no usable size' }
  }
  $dir = Join-Path $env:TEMP 'dsh-wechat-bridge'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $file = Join-Path $dir ('wx-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
  $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
  $mode = if ($req.mode) { [string]$req.mode } else { 'window' }
  $ok = $false
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    if ($mode -eq 'screen') {
      # Real on-screen pixels: the conversation pane is GPU-composited, so
      # PrintWindow renders it blank. This only works when the window is
      # visible and in front.
      $g.CopyFromScreen($rect.L, $rect.T, 0, 0, (New-Object System.Drawing.Size $rect.Width, $rect.Height))
      $ok = $true
    } else {
      $dc = $g.GetHdc()
      $ok = [Wxb]::PrintWindow($hwnd, $dc, 2)
      $g.ReleaseHdc($dc)
    }
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $bmp.Dispose()
  }
  return [ordered]@{ ok = [bool]$ok; path = $file; mode = $mode; width = $rect.Width; height = $rect.Height }
}

function Invoke-Focus {
  $hwnd = Find-WeixinWindow
  if ($hwnd -eq [IntPtr]::Zero) { return [ordered]@{ ok = $false; message = 'WeChat main window not found' } }
  if (Test-Locked) { return [ordered]@{ ok = $false; locked = $true; message = 'workstation is locked; foreground input is not possible' } }

  [void][Wxb]::ShowWindow($hwnd, 9)   # SW_RESTORE
  Start-Sleep -Milliseconds 250
  $myThread = [Wxb]::GetCurrentThreadId()
  $procId = 0
  $targetThread = [Wxb]::GetWindowThreadProcessId($hwnd, [ref]$procId)
  $fg = [IntPtr]::Zero
  $attempts = 0
  # Windows only honours SetForegroundWindow from the current foreground app, so
  # retry a few times: each round is cheap and the first one often loses the race.
  while ($attempts -lt 4 -and $fg -ne $hwnd) {
    $attempts++
    [void][Wxb]::AttachThreadInput($myThread, $targetThread, $true)
    [void][Wxb]::SetForegroundWindow($hwnd)
    [void][Wxb]::AttachThreadInput($myThread, $targetThread, $false)
    Start-Sleep -Milliseconds 220
    $fg = [Wxb]::GetForegroundWindow()
  }
  return [ordered]@{ ok = ($fg -eq $hwnd); foreground = ($fg -eq $hwnd); attempts = $attempts; rect = (Get-WindowRectOrNull $hwnd) }
}

# Hard gate: every synthetic click and keystroke below goes to whatever window
# owns the foreground. If we could not actually give WeChat the foreground (a
# fullscreen game, an elevated window, a UAC prompt), the input would be typed
# into that other program instead. Never let that happen.
function Assert-Foreground([IntPtr]$hwnd) {
  $fg = [Wxb]::GetForegroundWindow()
  if ($fg -ne $hwnd) {
    throw ("refusing to drive the UI: WeChat is not the foreground window (foreground hwnd=$fg). " +
      'Another program owns the foreground - bring WeChat up manually, then retry.')
  }
}

function Assert-Focus([IntPtr]$hwnd) {
  $f = Invoke-Focus
  if (-not $f.ok) {
    throw ('refusing to drive the UI: could not bring WeChat to the foreground ' +
      "(tried $($f.attempts) times). Another program is holding the focus.")
  }
  Assert-Foreground $hwnd
}

# Bring the window to a known geometry so the relative click targets below are
# stable. Returns the previous rectangle so the caller can restore it.
function Enter-KnownGeometry([IntPtr]$hwnd) {
  $prev = Get-WindowRectOrNull $hwnd
  [void][Wxb]::ShowWindow($hwnd, 9)
  Start-Sleep -Milliseconds 200
  $x = 60; $y = 40; $w = 1000; $h = 800
  # HWND_TOPMOST (-1): while the script drives the UI the window must actually be
  # on top, otherwise the synthetic clicks land on whatever covers it.
  [void][Wxb]::SetWindowPos($hwnd, [IntPtr](-1), $x, $y, $w, $h, 0x0040)
  Start-Sleep -Milliseconds 400
  return $prev
}

function Restore-Geometry([IntPtr]$hwnd, $prev) {
  # Drop the topmost pin first, then put the window back where the user had it.
  [void][Wxb]::SetWindowPos($hwnd, [IntPtr](-2), 0, 0, 0, 0, 0x0013)
  if (-not $prev) { return }
  [void][Wxb]::SetWindowPos($hwnd, [IntPtr]::Zero, $prev.L, $prev.T, $prev.Width, $prev.Height, 0x0040)
}

# SHA-256 of the window as PrintWindow renders it. The left conversation list is
# rendered by the CPU, so this changes whenever a chat gets a new last message --
# a cheap "did anything actually happen" check for send operations.
function Get-WindowHash([IntPtr]$hwnd) {
  $rect = Get-WindowRectOrNull $hwnd
  if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $null }
  $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc()
    [void][Wxb]::PrintWindow($hwnd, $dc, 2)
    $g.ReleaseHdc($dc)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash($ms.ToArray())).Replace('-', '')
    $sha.Dispose(); $ms.Dispose()
    return $hash
  } finally {
    $bmp.Dispose()
  }
}

function Assert-SendReady {
  $procs = Get-WeixinProcesses
  if ($procs.Count -eq 0) { throw 'WeChat is not running.' }
  if (Test-Locked) { throw 'The workstation is locked. Sending needs an unlocked desktop: the WeChat 4.x UI cannot be driven from a locked session.' }
  $hwnd = Find-WeixinWindow
  if ($hwnd -eq [IntPtr]::Zero) { throw 'WeChat main window not found.' }
  return $hwnd
}

# Open a chat by typing its name into the global search box.
# Coordinates are relative to the fixed 1000x800 geometry.
#
# This used to be fire-and-forget: if the search never landed (a damaged chat
# name, a failed paste, a window that never took focus) the following paste+Enter
# went into whatever conversation happened to be open -- a file once went to a
# group chat. Every step that can silently no-op is therefore checked, and a
# failed check aborts the whole send.
function Open-Chat([IntPtr]$hwnd, [string]$chatName) {
  Assert-Foreground $hwnd
  $rect = Get-WindowRectOrNull $hwnd
  $ox = $rect.L; $oy = $rect.T
  $before = Get-WindowHash $hwnd
  # Global search box: left column is ~130px wide, the box starts right after it.
  [Wxb]::Click(($ox + 380), ($oy + 113))
  Start-Sleep -Milliseconds 450
  [Wxb]::Combo([Wxb]::VK_CONTROL, [Wxb]::VK_A)
  Start-Sleep -Milliseconds 120
  Set-Clipboard -Value $chatName
  Start-Sleep -Milliseconds 200
  # Guard against encoding/clipboard damage: the name must survive the round trip
  # byte for byte, otherwise the search below would look for a different string.
  $echo = Get-Clipboard -Raw
  if ($echo -ne $chatName) {
    throw ("chat name did not survive the clipboard round trip (got '" + $echo + "'); refusing to send")
  }
  [Wxb]::Combo([Wxb]::VK_CONTROL, [Wxb]::VK_V)
  Start-Sleep -Milliseconds 900
  [Wxb]::KeyTap([Wxb]::VK_RETURN)
  Start-Sleep -Milliseconds 1300
  # A successful switch repaints the conversation pane; an unchanged window means
  # the search or the Enter did nothing and the open chat is still the old one.
  $after = Get-WindowHash $hwnd
  if ($after -eq $before) {
    throw ("could not confirm the switch to '" + $chatName + "'; refusing to send")
  }
}

function Send-TextBody([IntPtr]$hwnd, [string]$text) {
  $rect = Get-WindowRectOrNull $hwnd
  $ox = $rect.L; $oy = $rect.T
  # Message composer sits at the bottom of the right-hand conversation pane.
  $cx = $ox + [int]($rect.Width * 0.85)
  $cy = $oy + [int]($rect.Height * 0.90)
  [Wxb]::Click($cx, $cy)
  Start-Sleep -Milliseconds 350
  # Re-check right before pasting: focus can be stolen while we sleep between
  # the click and the keystroke (a game taking exclusive fullscreen, a toast).
  Assert-Foreground $hwnd
  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 200
  [Wxb]::Combo([Wxb]::VK_CONTROL, [Wxb]::VK_V)
  Start-Sleep -Milliseconds 500
  [Wxb]::KeyTap([Wxb]::VK_RETURN)
  Start-Sleep -Milliseconds 700
}

function Send-FileBody([IntPtr]$hwnd, [string]$filePath) {
  $rect = Get-WindowRectOrNull $hwnd
  $ox = $rect.L; $oy = $rect.T
  $cx = $ox + [int]($rect.Width * 0.85)
  $cy = $oy + [int]($rect.Height * 0.90)
  [Wxb]::Click($cx, $cy)
  Start-Sleep -Milliseconds 400
  Assert-Foreground $hwnd
  Set-Clipboard -Path $filePath
  Start-Sleep -Milliseconds 500
  [Wxb]::Combo([Wxb]::VK_CONTROL, [Wxb]::VK_V)
  # A paste of a file list needs noticeably longer than text: WeChat has to
  # build the file card before Enter means "send".
  Start-Sleep -Milliseconds 1600
  [Wxb]::KeyTap([Wxb]::VK_RETURN)
  Start-Sleep -Milliseconds 1400
}

# Full-screen PNG of the whole virtual desktop, used to trace what the send
# sequence actually looks like while it runs.
function Save-ScreenShot([string]$tag) {
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $dir = Join-Path $env:TEMP 'dsh-wechat-bridge'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $file = Join-Path $dir ('trace-' + $tag + '-' + (Get-Date -Format 'HHmmss') + '.png')
  $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, (New-Object System.Drawing.Size $vs.Width, $vs.Height))
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $bmp.Dispose()
  }
  return $file
}

function Invoke-TraceSendFile {
  $hwnd = Assert-SendReady
  $chat = if ($req.chat) { [string]$req.chat } else { $null }
  if (-not $chat) { throw 'chat name is required' }
  $p = [string]$req.path
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { throw "file not found: $p" }

  $prev = Enter-KnownGeometry $hwnd
  $shots = @()
  try {
    Assert-Focus $hwnd
    Open-Chat $hwnd $chat
    $rect = Get-WindowRectOrNull $hwnd
    $cx = $rect.L + [int]($rect.Width * 0.85)
    $cy = $rect.T + [int]($rect.Height * 0.90)
    [Wxb]::Click($cx, $cy)
    Start-Sleep -Milliseconds 400
    $shots += (Save-ScreenShot 'a-clicked')
    Set-Clipboard -Path $p
    Start-Sleep -Milliseconds 500
    $shots += (Save-ScreenShot 'b-clipboard')
    [Wxb]::Combo([Wxb]::VK_CONTROL, [Wxb]::VK_V)
    Start-Sleep -Milliseconds 1600
    $shots += (Save-ScreenShot 'c-pasted')
    [Wxb]::KeyTap([Wxb]::VK_RETURN)
    Start-Sleep -Milliseconds 1400
    $shots += (Save-ScreenShot 'd-entered')
    return [ordered]@{ ok = $true; focused = $true; shots = $shots }
  } finally {
    Restore-Geometry $hwnd $prev
  }
}

function Invoke-OpenChat {
  $hwnd = Assert-SendReady
  $chat = if ($req.chat) { [string]$req.chat } else { $null }
  if (-not $chat) { throw 'chat name is required' }
  $prev = Enter-KnownGeometry $hwnd
  try {
    Assert-Focus $hwnd
    Open-Chat $hwnd $chat
    Start-Sleep -Milliseconds 400
    $shot = Invoke-Snapshot
    return [ordered]@{ ok = $true; chat = $chat; screenshot = $shot.path }
  } finally {
    Restore-Geometry $hwnd $prev
  }
}

function Invoke-SendText {
  $chat = if ($req.chat) { [string]$req.chat } else { $null }
  if (-not $chat) { throw 'chat name is required' }
  $text = [string]$req.text
  if (-not $text) { throw 'text is required' }

  return Invoke-WithScreen {
    $hwnd = Assert-SendReady
    $prev = Enter-KnownGeometry $hwnd
    try {
      Assert-Focus $hwnd
      Open-Chat $hwnd $chat
      Send-TextBody $hwnd $text
      Start-Sleep -Milliseconds 500
      $shot = Invoke-Snapshot
      return [ordered]@{ ok = $true; chat = $chat; textLength = $text.Length; screenshot = $shot.path }
    } finally {
      Restore-Geometry $hwnd $prev
    }
  }
}

function Invoke-SendFile {
  $chat = if ($req.chat) { [string]$req.chat } else { $null }
  if (-not $chat) { throw 'chat name is required' }
  $p = [string]$req.path
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { throw "file not found: $p" }
  $item = Get-Item -LiteralPath $p

  return Invoke-WithScreen {
    $hwnd = Assert-SendReady
    $prev = Enter-KnownGeometry $hwnd
    try {
      Assert-Focus $hwnd
      Open-Chat $hwnd $chat
      $before = Get-WindowHash $hwnd
      Send-FileBody $hwnd $item.FullName
      Start-Sleep -Milliseconds 600
      $after = Get-WindowHash $hwnd
      $shot = Invoke-Snapshot
      $sent = ($before -ne $after)
      return [ordered]@{
        ok            = $true
        chat          = $chat
        path          = $item.FullName
        size          = $item.Length
        focused       = $true
        windowChanged = $sent
        screenshot    = $shot.path
        # The window hash is only a hint: WeChat repaints its list lazily, so an
        # unchanged hash does NOT mean the file was not sent.
        message       = $(if ($sent) { 'file sent' } else { 'send sequence executed; on-screen confirmation was unavailable' })
      }
    } finally {
      Restore-Geometry $hwnd $prev
    }
  }
}

$result = $null
try {
  switch ($action) {
    'status'    { $result = Invoke-Status }
    'list'      { $result = Invoke-List }
    'snapshot'  { $result = Invoke-Snapshot }
    'focus'     { $result = Invoke-Focus }
    'open-chat' { $result = Invoke-OpenChat }
    'send-text' { $result = Invoke-SendText }
    'send-file' { $result = Invoke-SendFile }
    'trace-send-file' { $result = Invoke-TraceSendFile }
    default     { $result = [ordered]@{ ok = $false; message = "unknown action: $action" } }
  }
} catch {
  $result = [ordered]@{ ok = $false; error = $_.Exception.Message }
  # Callers use this to tell "locked" apart from real errors and queue the work.
  if (Test-Locked) { $result.locked = $true }
}

$json = $result | ConvertTo-Json -Depth 8 -Compress
$stdout = [Console]::OpenStandardOutput()
$writer = New-Object System.IO.StreamWriter($stdout, (New-Object System.Text.UTF8Encoding($false)))
$writer.WriteLine($json)
$writer.Flush()
