# Starts the till, the kitchen screen and the customer order board together,
# and puts them where you can see all three.
#
# The positioning is the point. All three are the same binary, and Flutter opens
# every window at the same default place and size — so without this they land
# exactly on top of one another and it looks as though only one started. That
# has been mistaken for "it will not run" more than once.
#
#     .\run-three-screens.ps1              tiled: till left, KDS and CDS right
#     .\run-three-screens.ps1 -Cascade     overlapping, each fully sized
#     .\run-three-screens.ps1 -Stop        close all three
#
# Roles come from the device database, not from this script: --profile picks
# which database to open, and each one was enrolled as pos, kds or cds.

[CmdletBinding()]
param(
    [switch]$Cascade,
    [switch]$Stop,
    [string]$Exe = "$PSScriptRoot\build\windows\x64\runner\Debug\pos_app.exe"
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PosWin {
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@

if ($Stop) {
    $running = Get-Process pos_app -ErrorAction SilentlyContinue
    if (-not $running) { Write-Host 'Nothing running.'; return }
    $running | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 3
    # CloseMainWindow lets the app close its database properly. Only force what
    # ignored it — a killed process is how the device database got corrupted
    # three times before the lock existed.
    Get-Process pos_app -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host 'Closed.'
    return
}

if (-not (Test-Path $Exe)) {
    throw "$Exe not found. Build it first:  flutter build windows --debug"
}

Add-Type -AssemblyName System.Windows.Forms
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

# The till carries the menu and the cart and needs the width; the kitchen rail
# and the order board are lists and do not.
$tillW = [int]($area.Width * 0.58)
$sideW = $area.Width - $tillW
$halfH = [int]($area.Height / 2)

# Every arithmetic element is parenthesised on purpose. PowerShell binds the
# comma tighter than +, so @($a + $b, $c) means $a + ($b, $c) — an integer plus
# an array, which fails with a message about op_Addition that names neither.
$screens = @(
    @{ Name = 'Till'
       Args = @()
       Rect = @($area.X, $area.Y, $tillW, $area.Height) },
    @{ Name = 'Kitchen (KDS)'
       Args = @('--profile=kitchen')
       Rect = @(($area.X + $tillW), $area.Y, $sideW, $halfH) },
    @{ Name = 'Order board (CDS)'
       Args = @('--profile=board', '--demo')
       Rect = @(($area.X + $tillW), ($area.Y + $halfH), $sideW, ($area.Height - $halfH)) }
)

$started = @()
$i = 0
foreach ($s in $screens) {
    $already = Get-CimInstance Win32_Process -Filter "Name='pos_app.exe'" |
        Where-Object {
            $a = ($_.CommandLine -replace '.*pos_app\.exe', '')
            if ($s.Args.Count -eq 0) { $a -notmatch '--profile' }
            else { $a -match [regex]::Escape($s.Args[0]) }
        }
    if ($already) {
        Write-Host ("  {0,-18} already running (PID {1})" -f $s.Name, $already.ProcessId) -ForegroundColor Yellow
        $started += [pscustomobject]@{ Name = $s.Name; Proc = (Get-Process -Id $already.ProcessId); Rect = $s.Rect; Index = $i }
    } else {
        # -ArgumentList rejects an empty array, and the till takes no arguments.
        $p = if ($s.Args.Count) { Start-Process $Exe -ArgumentList $s.Args -PassThru }
             else               { Start-Process $Exe -PassThru }
        Write-Host ("  {0,-18} started (PID {1})" -f $s.Name, $p.Id) -ForegroundColor Green
        $started += [pscustomobject]@{ Name = $s.Name; Proc = $p; Rect = $s.Rect; Index = $i }
        # Staggered because three copies opening SQLite at the same moment used
        # to be how databases got damaged.
        Start-Sleep -Seconds 4
    }
    $i++
}

# The window does not exist the instant the process does.
Write-Host 'Waiting for windows...'
foreach ($s in $started) {
    for ($try = 0; $try -lt 25; $try++) {
        $s.Proc.Refresh()
        if ($s.Proc.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 400
    }
}

foreach ($s in $started) {
    $h = $s.Proc.MainWindowHandle
    if ($h -eq 0) {
        Write-Host ("  {0,-18} no window yet — check it is not on the enrolment screen" -f $s.Name) -ForegroundColor Yellow
        continue
    }
    [PosWin]::ShowWindow($h, 9) | Out-Null       # SW_RESTORE, in case it opened maximised
    if ($Cascade) {
        $off = 46 * $s.Index
        [PosWin]::MoveWindow($h, ($area.X + $off), ($area.Y + $off),
                             [int]($area.Width * 0.86), [int]($area.Height * 0.9), $true) | Out-Null
    } else {
        [PosWin]::MoveWindow($h, $s.Rect[0], $s.Rect[1], $s.Rect[2], $s.Rect[3], $true) | Out-Null
    }
}

Write-Host ''
Write-Host 'All three are up. Alt+Tab still switches between them.' -ForegroundColor Cyan
Write-Host 'The backend must be running too, or every screen will sit there empty:'
Write-Host '  http://127.0.0.1:8100/office' -ForegroundColor Cyan
