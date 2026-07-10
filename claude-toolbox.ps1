# ============================================================================
#  Claude Desktop Toolbox
#  A small menu app to run several Claude Desktop accounts and move chats
#  between them. Works on any Windows PC (uses only environment paths).
#
#  WHAT YOU CAN DO
#    1. Set up extra Claude accounts  - separate logins, each its own window,
#                                       survives Claude updates.
#    2. Copy a chat into another account.
#    3. Replace a chat with another chat's history.
#    4. Restart an account window     - needed so a moved chat shows up.
#
#  HOW MOVING A CHAT WORKS (plain version)
#    Every account keeps a small list file per chat (a "pointer").
#    The real conversation is stored once and shared by all accounts.
#    Copying a chat just writes a new pointer in the other account - fast,
#    and it never duplicates or damages the original conversation.
#
#  IMPORTANT
#    Claude reads its chat list only when an account starts. A moved chat
#    appears only after you RESTART that account window. This app can do
#    that for you (option 4), or you can quit and reopen it yourself.
#
#  Just double-click claude-toolbox.bat. No arguments needed.
# ============================================================================

$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'Claude-Profiles'

# ---- low level helpers ------------------------------------------------------

function Pause-Menu { Write-Host ""; Read-Host "Press Enter to go back to the menu" | Out-Null }

function Read-Json([string]$path) {
    $raw = [System.IO.File]::ReadAllText($path)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }  # tolerate BOM
    return ($raw | ConvertFrom-Json)
}

function Write-JsonNoBom([string]$path, $obj) {
    # MUST be UTF-8 without BOM, or Claude fails to read the file and the chat vanishes.
    $json = $obj | ConvertTo-Json -Depth 40 -Compress
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextNoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Select-Menu([string]$prompt, [array]$items, [scriptblock]$label) {
    if ($items.Count -eq 0) { return $null }
    if ($items.Count -eq 1) { return $items[0] }
    Write-Host ""
    Write-Host $prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), (& $label $items[$i])) }
    while ($true) {
        $sel = Read-Host "Type a number (1-$($items.Count)), or Q to cancel"
        if ($sel -match '^(?i)q$') { return $null }
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $items.Count) { return $items[[int]$sel - 1] }
        Write-Host "Please type one of the numbers." -ForegroundColor Yellow
    }
}

function Find-ClaudeExe {
    # Works whether Claude is installed as MSIX (Store style) or a normal app.
    $pkg = Get-AppxPackage -Name *Claude* -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        foreach ($p in @((Join-Path $pkg.InstallLocation 'app\Claude.exe'), (Join-Path $pkg.InstallLocation 'Claude.exe'))) {
            if (Test-Path $p) { return $p }
        }
    }
    foreach ($p in @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
                     "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
                     "$env:ProgramFiles\Claude\Claude.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ---- account / session discovery -------------------------------------------

function Get-Accounts {
    if (-not (Test-Path $Root)) { return @() }
    Get-ChildItem $Root -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName 'claude-code-sessions')
    } | ForEach-Object {
        $cnt = (Get-ChildItem (Join-Path $_.FullName 'claude-code-sessions') -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        [pscustomobject]@{ Name = $_.Name; Dir = $_.FullName; Count = $cnt }
    }
}

function Get-Leaf([string]$profileDir) {
    $base = Join-Path $profileDir 'claude-code-sessions'
    if (-not (Test-Path $base)) { throw "That account has no chats yet. Open it once and sign in first." }
    $leaf = Get-ChildItem $base -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory } |
        Sort-Object { (Get-ChildItem $_.FullName -Filter 'local_*.json' -File).Count } -Descending | Select-Object -First 1
    if (-not $leaf) { throw "That account has no chat store yet. Open it once and sign in first." }
    return $leaf.FullName
}

function Get-Chats([string]$profileDir) {
    $base = Join-Path $profileDir 'claude-code-sessions'
    if (-not (Test-Path $base)) { return @() }
    Get-ChildItem $base -Recurse -Filter 'local_*.json' -File | ForEach-Object {
        try { $o = Read-Json $_.FullName } catch { return }
        if ($o.title) {
            [pscustomobject]@{ Title=$o.title; cliSessionId=$o.cliSessionId; Path=$_.FullName; Obj=$o; When=$_.LastWriteTime }
        }
    } | Sort-Object When -Descending
}

function Pick-Account([string]$prompt) {
    $accts = @(Get-Accounts)
    if ($accts.Count -eq 0) { Write-Host "No accounts found. Use option 1 to set them up first." -ForegroundColor Yellow; return $null }
    Select-Menu $prompt $accts { param($x) "{0}  ({1} chats)" -f $x.Name, $x.Count }
}

function Pick-Chat([string]$prompt, [string]$profileDir) {
    $chats = @(Get-Chats $profileDir)
    if ($chats.Count -eq 0) { Write-Host "That account has no chats." -ForegroundColor Yellow; return $null }
    # let the user filter by typing part of a title (optional)
    $flt = Read-Host "Type part of the chat name to filter (or just Enter to list all)"
    if ($flt) { $chats = @($chats | Where-Object { $_.Title -like "*$flt*" }) }
    if ($chats.Count -eq 0) { Write-Host "Nothing matched '$flt'." -ForegroundColor Yellow; return $null }
    Select-Menu $prompt $chats { param($x) $x.Title }
}

# ---- action: set up accounts (from your account-duplication script) ---------

function Invoke-SetupAccounts {
    Write-Host ""
    Write-Host "Set up extra Claude accounts" -ForegroundColor Green
    Write-Host "Each name becomes its own Start Menu shortcut with a separate login."
    Write-Host "These shortcuts keep working after Claude updates."
    $exe = Find-ClaudeExe
    if (-not $exe) { Write-Host "Could not find Claude.exe. Install the Claude desktop app first." -ForegroundColor Red; return }

    $namesRaw = Read-Host "Enter account names separated by commas (example: main,dev)"
    if (-not $namesRaw) { $namesRaw = 'main,dev' }
    $names = $namesRaw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    # launcher finds the current Claude version at click time (survives updates)
    $launcher = Join-Path $Root 'launch-claude.ps1'
    $launcherText = @'
param([Parameter(Mandatory)][string]$DataDir)
$pkg = Get-AppxPackage -Name *Claude* | Select-Object -First 1
if ($pkg) {
    $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path $pkg.InstallLocation 'Claude.exe' }
} else {
    $exe = "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe"
}
if (-not (Test-Path $exe)) { exit 1 }
Start-Process -FilePath $exe -ArgumentList ('--user-data-dir="{0}"' -f $DataDir)
'@
    Write-TextNoBom $launcher $launcherText

    # extract the icon once so shortcuts keep it after updates
    $ico = Join-Path $Root 'claude.ico'
    try {
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
        $fs = [System.IO.File]::Open($ico, 'Create'); $icon.Save($fs); $fs.Close()
        $iconRef = $ico
    } catch { $iconRef = "$exe,0" }

    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($n in $names) {
        $data = Join-Path $Root $n
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        $lnk = $wsh.CreateShortcut((Join-Path $startMenu ("Claude - $n.lnk")))
        $lnk.TargetPath       = $psExe
        $lnk.Arguments        = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -DataDir "{1}"' -f $launcher, $data
        $lnk.WorkingDirectory = $Root
        $lnk.IconLocation     = $iconRef
        $lnk.WindowStyle      = 7
        $lnk.Description       = "Claude - $n"
        $lnk.Save()
        Write-Host ("  created shortcut: Claude - {0}" -f $n) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "Done. Open each from the Start Menu and sign in once." -ForegroundColor Green
    Write-Host "After signing in, that account will show up here for moving chats."
}

# ---- action: copy a chat ----------------------------------------------------

function Invoke-CopyChat {
    Write-Host ""
    Write-Host "Copy a chat into another account" -ForegroundColor Green
    $srcAcct = Pick-Account "Which account is the chat in now?"; if (-not $srcAcct) { return }
    $chat    = Pick-Chat "Pick the chat to copy:" $srcAcct.Dir;   if (-not $chat) { return }
    if (-not $chat.cliSessionId) { Write-Host "This chat has no history to point at." -ForegroundColor Red; return }
    $dstAcct = Pick-Account "Copy it INTO which account?";        if (-not $dstAcct) { return }

    $rename = Read-Host "New name for the copy (or Enter to keep '$($chat.Title)')"
    $o = $chat.Obj
    $o.sessionId = 'local_' + [guid]::NewGuid().ToString()
    if ($rename) { $o.title = $rename; if ($o.PSObject.Properties['titleSource']) { $o.titleSource = 'user' } }
    foreach ($k in 'enabledMcpTools','remoteMcpServersConfig','alwaysAllowedReasons','sessionPermissionUpdates') {
        if ($o.PSObject.Properties[$k]) { $o.PSObject.Properties.Remove($k) }
    }
    $dst = Join-Path (Get-Leaf $dstAcct.Dir) ("{0}.json" -f $o.sessionId)
    Write-JsonNoBom $dst $o
    Write-Host ""
    Write-Host ("Copied '{0}' into account '{1}'." -f $o.title, $dstAcct.Name) -ForegroundColor Green
    Offer-Restart $dstAcct
}

# ---- action: replace a chat -------------------------------------------------

function Invoke-ReplaceChat {
    Write-Host ""
    Write-Host "Replace a chat with another chat's history" -ForegroundColor Green
    Write-Host "The chosen chat keeps its name but will show the other chat's messages."
    $srcAcct = Pick-Account "Which account holds the history you want to show?"; if (-not $srcAcct) { return }
    $src     = Pick-Chat "Pick the chat whose history to use (source):" $srcAcct.Dir; if (-not $src) { return }
    if (-not $src.cliSessionId) { Write-Host "That source chat has no history." -ForegroundColor Red; return }
    $dstAcct = Pick-Account "Which account has the chat to overwrite?"; if (-not $dstAcct) { return }
    $tgt     = Pick-Chat "Pick the chat to OVERWRITE (its name stays, content changes):" $dstAcct.Dir; if (-not $tgt) { return }

    Write-Host ""
    Write-Host ("This will make '{0}' show the history of '{1}'." -f $tgt.Title, $src.Title) -ForegroundColor Yellow
    if ((Read-Host "Type YES to confirm") -ne 'YES') { Write-Host "Cancelled."; return }

    Copy-Item $tgt.Path ("{0}.bak" -f $tgt.Path) -Force   # backup for undo
    $o = $tgt.Obj
    $o.cliSessionId = $src.cliSessionId
    Write-JsonNoBom $tgt.Path $o
    Write-Host ("Done. Backup saved next to the file (.bak) in case you want to undo." ) -ForegroundColor Green
    Offer-Restart $dstAcct
}

# ---- action: restart an account (so changes show up) ------------------------

function Get-AccountProcs([string]$acctDir) {
    Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains($acctDir.ToLower()) }
}

function Restart-Account($acct) {
    $procs = @(Get-AccountProcs $acct.Dir)
    Write-Host ""
    Write-Host ("WARNING: this closes the '{0}' Claude window." -f $acct.Name) -ForegroundColor Yellow
    Write-Host "Finish anything you are typing there first. A running task will be interrupted."
    if ($procs.Count -eq 0) { Write-Host "(That account is not running right now - it will just be started.)" }
    if ((Read-Host "Type YES to restart it now") -ne 'YES') { Write-Host "Left it alone."; return }

    foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }
    # wait until they are gone (max ~10s)
    for ($i = 0; $i -lt 40 -and (@(Get-AccountProcs $acct.Dir).Count -gt 0); $i++) { Start-Sleep -Milliseconds 250 }

    $launcher = Join-Path $Root 'launch-claude.ps1'
    if (Test-Path $launcher) {
        Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -DataDir "{1}"' -f $launcher, $acct.Dir)
    } else {
        $exe = Find-ClaudeExe
        if ($exe) { Start-Process $exe -ArgumentList ('--user-data-dir="{0}"' -f $acct.Dir) }
        else { Write-Host "Could not find Claude.exe to relaunch. Start '$($acct.Name)' from the Start Menu." -ForegroundColor Red; return }
    }
    Write-Host ("Restarted '{0}'. Your changes should be visible now." -f $acct.Name) -ForegroundColor Green
}

function Offer-Restart($acct) {
    Write-Host ""
    Write-Host "Claude only sees this after the account restarts." -ForegroundColor Cyan
    if ((Read-Host "Restart '$($acct.Name)' now? (Y/N)") -match '^(?i)y') { Restart-Account $acct }
    else { Write-Host "OK. Quit and reopen '$($acct.Name)' yourself when ready, or use menu option 4." }
}

function Invoke-RestartMenu {
    $acct = Pick-Account "Which account do you want to restart?"; if (-not $acct) { return }
    Restart-Account $acct
}

# ---- main menu --------------------------------------------------------------

while ($true) {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host "            Claude Desktop Toolbox            " -ForegroundColor White
    Write-Host "==============================================" -ForegroundColor DarkCyan
    $accts = @(Get-Accounts)
    if ($accts.Count) { Write-Host ("Accounts: " + (($accts | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join "   ")) -ForegroundColor DarkGray }
    else { Write-Host "No accounts set up yet - start with option 1." -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "  [1] Set up extra Claude accounts"
    Write-Host "  [2] Copy a chat into another account"
    Write-Host "  [3] Replace a chat with another chat's history"
    Write-Host "  [4] Restart an account window (make changes show up)"
    Write-Host "  [5] Exit"
    Write-Host ""
    switch (Read-Host "Choose") {
        '1' { try { Invoke-SetupAccounts } catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '2' { try { Invoke-CopyChat }      catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '3' { try { Invoke-ReplaceChat }   catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '4' { try { Invoke-RestartMenu }   catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '5' { break }
        default { }
    }
}
