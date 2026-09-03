$ErrorActionPreference = 'Stop'
$ProfileRoot = Join-Path $env:LOCALAPPDATA 'Claude-Profiles'

function Pause-Menu { Write-Host ""; Read-Host "Press Enter to go back to the menu" | Out-Null }

function Read-Json([string]$path) {
    $raw = [System.IO.File]::ReadAllText($path)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonNoBom([string]$path, $obj) {
    # Must be UTF-8 without BOM, or Claude cannot read the file.
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
    try { $pkg = Get-AppxPackage -Name *Claude* -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $pkg = $null }
    if ($pkg) {
        foreach ($p in @((Join-Path $pkg.InstallLocation 'app\Claude.exe'), (Join-Path $pkg.InstallLocation 'Claude.exe'))) {
            if (Test-Path $p) { return $p }
        }
    }
    foreach ($p in @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
                     "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
                     "$env:LOCALAPPDATA\Programs\claude\Claude.exe",
                     "$env:ProgramFiles\Claude\Claude.exe",
                     "${env:ProgramFiles(x86)}\Claude\Claude.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    # Direct-download (Squirrel) install: %LOCALAPPDATA%\AnthropicClaude\app-<version>\Claude.exe (use newest)
    foreach ($base in @("$env:LOCALAPPDATA\AnthropicClaude", "$env:LOCALAPPDATA\Programs\claude")) {
        if (Test-Path $base) {
            $exe = Get-ChildItem $base -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending |
                   ForEach-Object { Join-Path $_.FullName 'Claude.exe' } |
                   Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($exe) { return $exe }
        }
    }
    return $null
}

# The plain install stores its data in one of these, depending on how Claude was installed:
#  - direct .exe download: %APPDATA%\Claude
#  - Microsoft Store / MSIX: %LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Roaming (or Local)\Claude
function Resolve-RealDir([string]$p) {
    try {
        $it = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if ($it.Target) { $t = @($it.Target)[0]; if ($t) { return $t } }  # follow a junction/symlink to its target
        return $it.FullName
    } catch { return $p }
}

function Get-DefaultAccountDirs {
    # %APPDATA%\Claude is often a junction to the Store package cache, so resolve and de-dupe.
    $cands = @( (Join-Path $env:APPDATA 'Claude') )
    try { $pkgs = @(Get-AppxPackage -Name *Claude* -ErrorAction SilentlyContinue) } catch { $pkgs = @() }
    foreach ($p in $pkgs) {
        $lc = Join-Path $env:LOCALAPPDATA ('Packages\{0}\LocalCache' -f $p.PackageFamilyName)
        $cands += (Join-Path $lc 'Roaming\Claude')
        $cands += (Join-Path $lc 'Local\Claude')
    }
    $seen = @{}; $out = @()
    foreach ($c in $cands) {
        if (-not (Test-Path (Join-Path $c 'claude-code-sessions'))) { continue }
        $key = (Resolve-RealDir $c).ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true; $out += $c
    }
    $out
}

# Every Claude window is a data dir. The plain install is found by Get-DefaultAccountDirs;
# extra accounts made by this tool live under %LOCALAPPDATA%\Claude-Profiles\<name>.
function Get-Accounts {
    $dirs = @()
    foreach ($d in @(Get-DefaultAccountDirs)) {
        $nm = if ($d -like '*\Packages\*') { 'default (store)' } else { 'default' }
        $dirs += [pscustomobject]@{ Name=$nm; Dir=$d; IsDefault=$true }
    }
    if (Test-Path $ProfileRoot) {
        Get-ChildItem $ProfileRoot -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName 'claude-code-sessions')
        } | ForEach-Object {
            $dirs += [pscustomobject]@{ Name=$_.Name; Dir=$_.FullName; IsDefault=$false }
        }
    }
    $dirs | ForEach-Object {
        $cnt = (Get-ChildItem (Join-Path $_.Dir 'claude-code-sessions') -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        $_ | Add-Member NoteProperty Count $cnt -PassThru
    }
}

# One account can be signed into more than one org, giving several store folders.
function Resolve-Leaf([string]$accountDir) {
    $base = Join-Path $accountDir 'claude-code-sessions'
    if (-not (Test-Path $base)) { throw "That account has no chats yet. Open it once and sign in first." }
    $leaves = @(Get-ChildItem $base -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory })
    if ($leaves.Count -eq 0) { throw "That account has no chat store yet. Open it once and sign in first." }
    if ($leaves.Count -eq 1) { return $leaves[0].FullName }
    $pick = Select-Menu "This account has more than one workspace. Pick where to put it:" $leaves {
        param($x) "{0}  ({1} chats)" -f $x.Name, (Get-ChildItem $x.FullName -Filter 'local_*.json' -File).Count
    }
    if (-not $pick) { throw "Cancelled." }
    return $pick.FullName
}

function Get-Chats([string]$accountDir) {
    $base = Join-Path $accountDir 'claude-code-sessions'
    if (-not (Test-Path $base)) { return @() }
    Get-ChildItem $base -Recurse -Filter 'local_*.json' -File | ForEach-Object {
        try { $o = Read-Json $_.FullName } catch { return }
        if ($o.title) {
            [pscustomobject]@{ Title=$o.title; cliSessionId=$o.cliSessionId; Path=$_.FullName; Obj=$o; When=$_.LastWriteTime }
        }
    } | Sort-Object When -Descending
}

function Get-TranscriptRoot {
    if ($env:CLAUDE_CONFIG_DIR) { return (Join-Path $env:CLAUDE_CONFIG_DIR 'projects') }
    return (Join-Path $env:USERPROFILE '.claude\projects')
}

function Find-TranscriptPath([string]$cli) {
    if (-not $cli) { return $null }
    $r = Get-TranscriptRoot
    if (-not (Test-Path $r)) { return $null }
    (Get-ChildItem $r -Recurse -Filter "$cli.jsonl" -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}

function Test-Transcript([string]$cli) { [bool](Find-TranscriptPath $cli) }

function Get-DownloadsDir {
    $d = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path $d) { return $d }
    return $null
}

function Sanitize-Name([string]$s) {
    $s = ($s -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80).Trim() }
    if (-not $s) { $s = 'chat' }
    return $s
}

# Turn a raw transcript into a readable markdown conversation (user/assistant text only).
function Render-Readable([string]$jsonlPath, [string]$title) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# $title")
    [void]$sb.AppendLine()
    foreach ($line in [System.IO.File]::ReadLines($jsonlPath)) {
        if (-not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $msg = $o.message
        if (-not $msg -or -not $msg.role) { continue }
        $text = ''
        if ($msg.content -is [string]) {
            $text = $msg.content
        } elseif ($msg.content) {
            $parts = @()
            foreach ($b in $msg.content) {
                if ($b.type -eq 'text' -and $b.text) { $parts += $b.text }
                elseif ($b.type -eq 'tool_use') { $parts += "_(used tool: $($b.name))_" }
            }
            $text = ($parts -join "`n")
        }
        if (-not $text) { continue }
        $who = switch ($msg.role) { 'user' { 'User' } 'assistant' { 'Assistant' } default { $msg.role } }
        [void]$sb.AppendLine("## $who")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine($text)
        [void]$sb.AppendLine()
    }
    $sb.ToString()
}

# Claude sorts the sidebar by these timestamps, so bumping them puts the chat at the top of the list.
function Bump-ChatTimestamps($o, [switch]$IncludeCreated) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $fields = @('lastActivityAt', 'lastFocusedAt'); if ($IncludeCreated) { $fields += 'createdAt' }
    foreach ($t in $fields) { if ($o.PSObject.Properties[$t]) { $o.$t = $now } }
}

function Pick-Account([string]$prompt) {
    $accts = @(Get-Accounts)
    if ($accts.Count -eq 0) { Write-Host "No Claude accounts found. Use option 1 to set them up first." -ForegroundColor Yellow; return $null }
    Select-Menu $prompt $accts { param($x) "{0}  ({1} chats)" -f $x.Name, $x.Count }
}

function Pick-Chat([string]$prompt, [string]$accountDir) {
    $chats = @(Get-Chats $accountDir)
    if ($chats.Count -eq 0) { Write-Host "That account has no chats." -ForegroundColor Yellow; return $null }
    $flt = Read-Host "Type part of the chat name to filter (or just Enter to list all)"
    if ($flt) { $chats = @($chats | Where-Object { $_.Title -like "*$flt*" }) }
    if ($chats.Count -eq 0) { Write-Host "Nothing matched '$flt'." -ForegroundColor Yellow; return $null }
    Select-Menu $prompt $chats { param($x) $x.Title }
}

function Invoke-SetupAccounts {
    Write-Host ""
    Write-Host "Set up extra Claude accounts" -ForegroundColor Green
    Write-Host "Each name becomes its own Start Menu shortcut with a separate login."
    $exe = Find-ClaudeExe
    if (-not $exe) { Write-Host "Could not find Claude.exe. Install the Claude desktop app first." -ForegroundColor Red; return }

    $namesRaw = Read-Host "Enter account names separated by commas (example: main,dev)"
    if (-not $namesRaw) { $namesRaw = 'main,dev' }
    $names = $namesRaw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '[\\/:*?"<>|]' }
    if ($names.Count -eq 0) { Write-Host "No valid names." -ForegroundColor Red; return }

    New-Item -ItemType Directory -Force -Path $ProfileRoot | Out-Null

    $launcher = Join-Path $ProfileRoot 'launch-claude.ps1'
    $launcherText = @'
param([Parameter(Mandatory)][string]$DataDir)
$pkg = Get-AppxPackage -Name *Claude* | Select-Object -First 1
if ($pkg) {
    $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path $pkg.InstallLocation 'Claude.exe' }
} else {
    $exe = $null
    foreach ($p in @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
                     "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
                     "$env:ProgramFiles\Claude\Claude.exe")) {
        if (Test-Path $p) { $exe = $p; break }
    }
    if (-not $exe) {
        $exe = Get-ChildItem "$env:LOCALAPPDATA\AnthropicClaude" -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               ForEach-Object { Join-Path $_.FullName 'Claude.exe' } |
               Where-Object { Test-Path $_ } | Select-Object -First 1
    }
}
if (-not $exe -or -not (Test-Path $exe)) { exit 1 }
Start-Process -FilePath $exe -ArgumentList ('--user-data-dir="{0}"' -f $DataDir)
'@
    Write-TextNoBom $launcher $launcherText

    $ico = Join-Path $ProfileRoot 'claude.ico'
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
        $data = Join-Path $ProfileRoot $n
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        $lnk = $wsh.CreateShortcut((Join-Path $startMenu ("Claude - $n.lnk")))
        $lnk.TargetPath       = $psExe
        $lnk.Arguments        = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -DataDir "{1}"' -f $launcher, $data
        $lnk.WorkingDirectory = $ProfileRoot
        $lnk.IconLocation     = $iconRef
        $lnk.WindowStyle      = 7
        $lnk.Description       = "Claude - $n"
        $lnk.Save()
        Write-Host ("  created shortcut: Claude - {0}" -f $n) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "Done. Open each from the Start Menu and sign in once." -ForegroundColor Green
}

function Invoke-CopyChat {
    Write-Host ""
    Write-Host "Copy a chat into another account" -ForegroundColor Green
    $srcAcct = Pick-Account "Which account is the chat in now?"; if (-not $srcAcct) { return }
    $chat    = Pick-Chat "Pick the chat to copy:" $srcAcct.Dir;   if (-not $chat) { return }
    if (-not $chat.cliSessionId) { Write-Host "This chat has no history to point at." -ForegroundColor Red; return }
    if (-not (Test-Transcript $chat.cliSessionId)) {
        Write-Host "Warning: the conversation file for this chat was not found - the copy may open empty." -ForegroundColor Yellow
        if ((Read-Host "Copy anyway? (Y/N)") -notmatch '^(?i)y') { Write-Host "Cancelled."; return }
    }
    $dstAcct = Pick-Account "Copy it INTO which account?";        if (-not $dstAcct) { return }
    $leaf    = Resolve-Leaf $dstAcct.Dir

    $rename = Read-Host "New name for the copy (or Enter to keep '$($chat.Title)')"
    $o = $chat.Obj
    $o.sessionId = 'local_' + [guid]::NewGuid().ToString()
    if ($rename) { $o.title = $rename; if ($o.PSObject.Properties['titleSource']) { $o.titleSource = 'user' } }
    if ((Read-Host "Show the copy at the top of the chat list? (Y/N, Enter = Y)") -notmatch '^(?i)n') { Bump-ChatTimestamps $o -IncludeCreated }
    foreach ($k in 'enabledMcpTools','remoteMcpServersConfig','alwaysAllowedReasons','sessionPermissionUpdates') {
        if ($o.PSObject.Properties[$k]) { $o.PSObject.Properties.Remove($k) }
    }
    $dst = Join-Path $leaf ("{0}.json" -f $o.sessionId)
    Write-JsonNoBom $dst $o
    Write-Host ""
    Write-Host ("Copied '{0}' into account '{1}'." -f $o.title, $dstAcct.Name) -ForegroundColor Green
    Offer-Restart $dstAcct
}

function Invoke-ReplaceChat {
    Write-Host ""
    Write-Host "Replace a chat with another chat's history" -ForegroundColor Green
    $srcAcct = Pick-Account "Which account holds the history you want to show?"; if (-not $srcAcct) { return }
    $src     = Pick-Chat "Pick the chat whose history to use (source):" $srcAcct.Dir; if (-not $src) { return }
    if (-not $src.cliSessionId) { Write-Host "That source chat has no history." -ForegroundColor Red; return }
    if (-not (Test-Transcript $src.cliSessionId)) {
        Write-Host "Warning: the conversation file for the source was not found - the result may be empty." -ForegroundColor Yellow
        if ((Read-Host "Continue anyway? (Y/N)") -notmatch '^(?i)y') { Write-Host "Cancelled."; return }
    }
    $dstAcct = Pick-Account "Which account has the chat to overwrite?"; if (-not $dstAcct) { return }
    $tgt     = Pick-Chat "Pick the chat to OVERWRITE (its name stays, content changes):" $dstAcct.Dir; if (-not $tgt) { return }
    if ($tgt.Path -eq $src.Path) { Write-Host "Source and target are the same chat. Nothing to do." -ForegroundColor Yellow; return }

    Write-Host ""
    Write-Host ("This will make '{0}' show the history of '{1}'." -f $tgt.Title, $src.Title) -ForegroundColor Yellow
    if ((Read-Host "Type YES to confirm") -ne 'YES') { Write-Host "Cancelled."; return }

    Copy-Item $tgt.Path ("{0}.bak" -f $tgt.Path) -Force
    $o = $tgt.Obj
    $o.cliSessionId = $src.cliSessionId
    if ((Read-Host "Show it at the top of the chat list? (Y/N, Enter = Y)") -notmatch '^(?i)n') { Bump-ChatTimestamps $o }
    Write-JsonNoBom $tgt.Path $o
    Write-Host "Done. Backup saved next to the file (.bak)." -ForegroundColor Green
    Offer-Restart $dstAcct
}

function Invoke-ExportChat {
    Write-Host ""
    Write-Host "Export a chat to a file" -ForegroundColor Green
    $acct = Pick-Account "Which account is the chat in?"; if (-not $acct) { return }
    $chat = Pick-Chat "Pick the chat to export:" $acct.Dir;  if (-not $chat) { return }
    $tx = Find-TranscriptPath $chat.cliSessionId
    if (-not $tx) { Write-Host "Conversation file not found - nothing to export." -ForegroundColor Red; return }

    $destChoices = @()
    $desk = [Environment]::GetFolderPath('Desktop'); if ($desk -and (Test-Path $desk)) { $destChoices += [pscustomobject]@{ Name='Desktop'; Dir=$desk } }
    $dl = Get-DownloadsDir; if ($dl) { $destChoices += [pscustomobject]@{ Name='Downloads'; Dir=$dl } }
    if ($destChoices.Count -eq 0) { Write-Host "Could not find Desktop or Downloads." -ForegroundColor Red; return }
    $dest = Select-Menu "Save where?" $destChoices { param($x) "{0}  ({1})" -f $x.Name, $x.Dir }; if (-not $dest) { return }

    $fmt = Select-Menu "Which format?" @(
        [pscustomobject]@{ Name='Readable text (.md)'; Key='md' },
        [pscustomobject]@{ Name='Raw data (.jsonl)';   Key='raw' },
        [pscustomobject]@{ Name='Both';                Key='both' }
    ) { param($x) $x.Name }
    if (-not $fmt) { return }

    $short = ($chat.cliSessionId -split '-')[0]
    $base  = Join-Path $dest.Dir ("{0} ({1})" -f (Sanitize-Name $chat.Title), $short)
    $written = @()
    if ($fmt.Key -in 'raw','both')  { Copy-Item $tx ($base + '.jsonl') -Force; $written += ($base + '.jsonl') }
    if ($fmt.Key -in 'md','both')   { Write-TextNoBom ($base + '.md') (Render-Readable $tx $chat.Title); $written += ($base + '.md') }
    Write-Host ""
    Write-Host "Exported:" -ForegroundColor Green
    $written | ForEach-Object { Write-Host "  $_" }
}

function Get-ImportSourceDirs {
    $dirs = @()
    $desk = [Environment]::GetFolderPath('Desktop'); if ($desk -and (Test-Path $desk)) { $dirs += $desk }
    $dl = Get-DownloadsDir; if ($dl) { $dirs += $dl }
    $dirs | Select-Object -Unique
}

function Read-TranscriptMeta([string]$jsonlPath) {
    $sid = $null; $cwd = $null; $n = 0
    foreach ($line in [System.IO.File]::ReadLines($jsonlPath)) {
        if (-not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $sid -and $o.sessionId) { $sid = $o.sessionId }
        if (-not $cwd -and $o.cwd) { $cwd = $o.cwd }
        if (($sid -and $cwd) -or (++$n -ge 50)) { break }
    }
    [pscustomobject]@{ SessionId=$sid; Cwd=$cwd }
}

# Pull first/last message times out of a transcript so an imported chat can keep its real dates.
function Get-TranscriptDates([string]$jsonlPath) {
    $first = $null; $last = $null
    foreach ($line in [System.IO.File]::ReadLines($jsonlPath)) {
        if ($line -notmatch '"timestamp"\s*:\s*"([^"]+)"') { continue }
        try { $t = [DateTimeOffset]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) } catch { continue }
        if (-not $first) { $first = $t }
        $last = $t
    }
    if (-not $last) { return $null }
    [pscustomobject]@{ CreatedAt = $first.ToUnixTimeMilliseconds(); LastAt = $last.ToUnixTimeMilliseconds() }
}

# Claude names each transcript folder after the cwd, replacing \ / : . _ and spaces with -.
function Encode-CwdFolder([string]$cwd) { $cwd -replace '[\\/:._ ]', '-' }

function Invoke-ImportChat {
    Write-Host ""
    Write-Host "Import a chat from a file" -ForegroundColor Green
    Write-Host "Looks for .jsonl chat files on your Desktop and in Downloads."
    $files = @()
    foreach ($d in @(Get-ImportSourceDirs)) {
        Get-ChildItem $d -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object { $files += $_ }
    }
    if ($files.Count -eq 0) { Write-Host "No .jsonl chat files found on Desktop or in Downloads." -ForegroundColor Yellow; return }
    $pick = Select-Menu "Pick a file to import:" @($files | Sort-Object LastWriteTime -Descending) {
        param($x) "{0}   ({1} KB, in {2})" -f $x.Name, [int]($x.Length / 1KB), (Split-Path $x.DirectoryName -Leaf)
    }
    if (-not $pick) { return }

    $meta = Read-TranscriptMeta $pick.FullName
    if (-not $meta.SessionId) { Write-Host "This file is not a Claude chat (no sessionId inside)." -ForegroundColor Red; return }

    $acct = Pick-Account "Import INTO which account?"; if (-not $acct) { return }
    $leaf = Resolve-Leaf $acct.Dir
    $template = @(Get-Chats $acct.Dir)[0]
    if (-not $template) { Write-Host "Target account has no existing chat to copy settings from." -ForegroundColor Red; return }

    $defTitle = [System.IO.Path]::GetFileNameWithoutExtension($pick.Name)
    $title = Read-Host "Name for the imported chat (or Enter for '$defTitle')"
    if (-not $title) { $title = $defTitle }

    # Put the conversation file into Claude's shared store if it is not already there.
    if (-not (Find-TranscriptPath $meta.SessionId)) {
        $cwd = if ($meta.Cwd) { $meta.Cwd } else { $acct.Dir }
        $folder = Join-Path (Get-TranscriptRoot) (Encode-CwdFolder $cwd)
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Copy-Item $pick.FullName (Join-Path $folder ($meta.SessionId + '.jsonl')) -Force
    }

    # Build the index by cloning an existing one so the schema always matches.
    $o = $template.Obj
    $o.sessionId    = 'local_' + [guid]::NewGuid().ToString()
    $o.cliSessionId = $meta.SessionId
    if ($meta.Cwd) {
        if ($o.PSObject.Properties['cwd'])       { $o.cwd = $meta.Cwd }
        if ($o.PSObject.Properties['originCwd']) { $o.originCwd = $meta.Cwd }
    }
    $o.title = $title
    if ($o.PSObject.Properties['titleSource']) { $o.titleSource = 'user' }
    if ((Read-Host "Show it at the top of the chat list? (Y/N, Enter = Y)") -notmatch '^(?i)n') {
        Bump-ChatTimestamps $o -IncludeCreated
    } else {
        $dates = Get-TranscriptDates $pick.FullName
        if ($dates) {
            if ($o.PSObject.Properties['createdAt']) { $o.createdAt = $dates.CreatedAt }
            foreach ($t in 'lastActivityAt','lastFocusedAt') { if ($o.PSObject.Properties[$t]) { $o.$t = $dates.LastAt } }
        } else {
            # No dates inside the file; the template's dates would be some other chat's, so top it is.
            Bump-ChatTimestamps $o -IncludeCreated
        }
    }
    foreach ($k in 'enabledMcpTools','remoteMcpServersConfig','alwaysAllowedReasons','sessionPermissionUpdates','writtenBranches') {
        if ($o.PSObject.Properties[$k]) { $o.PSObject.Properties.Remove($k) }
    }
    $dst = Join-Path $leaf ($o.sessionId + '.json')
    Write-JsonNoBom $dst $o
    Write-Host ""
    Write-Host ("Imported '{0}' into account '{1}'." -f $title, $acct.Name) -ForegroundColor Green
    Offer-Restart $acct
}

# Match the running windows of ONE account.
#  - extra accounts always carry --user-data-dir="<their dir>"; match that exactly
#    (the trailing boundary stops 'main' from also matching 'main2').
#  - the plain install has no --user-data-dir and no Claude-Profiles path.
function Get-AccountProcs($acct) {
    $all = @(Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine })
    if ($acct.IsDefault) {
        $all | Where-Object { $_.CommandLine -notmatch '--user-data-dir' -and $_.CommandLine -notmatch 'Claude-Profiles' }
    } else {
        $pat = [regex]::Escape($acct.Dir) + '[\\"\s]'
        $all | Where-Object { $_.CommandLine -match $pat }
    }
}

function Restart-Account($acct) {
    $procs = @(Get-AccountProcs $acct)
    Write-Host ""
    Write-Host ("WARNING: this closes the '{0}' Claude window." -f $acct.Name) -ForegroundColor Yellow
    Write-Host "Finish anything you are typing there first. A running task will be interrupted."
    if ($procs.Count -eq 0) { Write-Host "(That account is not running right now - it will just be started.)" }
    if ((Read-Host "Type YES to restart it now") -ne 'YES') { Write-Host "Left it alone."; return }

    foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }
    for ($i = 0; $i -lt 40 -and (@(Get-AccountProcs $acct).Count -gt 0); $i++) { Start-Sleep -Milliseconds 250 }

    $launcher = Join-Path $ProfileRoot 'launch-claude.ps1'
    if (-not $acct.IsDefault -and (Test-Path $launcher)) {
        Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -DataDir "{1}"' -f $launcher, $acct.Dir)
    } else {
        $exe = Find-ClaudeExe
        if (-not $exe) { Write-Host "Could not find Claude.exe to relaunch. Start '$($acct.Name)' yourself." -ForegroundColor Red; return }
        if ($acct.IsDefault) { Start-Process $exe }
        else { Start-Process $exe -ArgumentList ('--user-data-dir="{0}"' -f $acct.Dir) }
    }
    Write-Host ("Restarted '{0}'." -f $acct.Name) -ForegroundColor Green
}

function Offer-Restart($acct) {
    Write-Host ""
    Write-Host "Claude only sees this after the account restarts." -ForegroundColor Cyan
    if ((Read-Host "Restart '$($acct.Name)' now? (Y/N)") -match '^(?i)y') { Restart-Account $acct }
    else { Write-Host "OK. Quit and reopen '$($acct.Name)' yourself, or use menu option 4." }
}

function Invoke-RestartMenu {
    $acct = Pick-Account "Which account do you want to restart?"; if (-not $acct) { return }
    Restart-Account $acct
}

function Invoke-BumpChat {
    Write-Host ""
    Write-Host "Move a chat to the top of the list" -ForegroundColor Green
    $acct = Pick-Account "Which account is the chat in?"; if (-not $acct) { return }
    $chat = Pick-Chat "Pick the chat to move up:" $acct.Dir; if (-not $chat) { return }
    $o = $chat.Obj
    Bump-ChatTimestamps $o
    Write-JsonNoBom $chat.Path $o
    Write-Host ""
    Write-Host ("Moved '{0}' to the top." -f $chat.Title) -ForegroundColor Green
    Offer-Restart $acct
}

# Claude Desktop reads its own policy from SOFTWARE\Policies\Claude, trying HKCU then HKLM.
# 'disableAutoUpdates' stops the in-app updater before it starts: nothing is downloaded, so the
# 72-hour force-install timer never arms and the app never relaunches itself.
#
# The setting is not per account. Every extra account is the same Windows user running the same
# machine-wide install with a different --user-data-dir, and the policy path carries no account in
# it - so one value covers all of them, and there is nothing to repeat per account.
#
# It goes in HKLM, not HKCU, for two reasons. Windows ACLs HKCU\SOFTWARE\Policies to read-only for
# a standard user (only SYSTEM and Administrators may write), so the per-user hive needs elevation
# anyway. And if HKLM holds ANY value under this key, the app reads the whole app-behavior group
# from HKLM alone and ignores HKCU - so a half-set HKCU value would silently do nothing.
$UpdatePolicyKey  = 'SOFTWARE\Policies\Claude'
$UpdatePolicyName = 'disableAutoUpdates'
# The build that introduced the key. Older Claude builds read no such policy, so writing it there
# would look like it worked and change nothing.
$UpdatePolicySince = [version]'1.2581.0'

function Get-UpdatePolicy {
    $out = [pscustomobject]@{ Hkcu = $null; Hklm = $null; HklmClaims = $false; Foreign = @() }
    foreach ($hive in 'CurrentUser', 'LocalMachine') {
        $k = $null
        try { $k = [Microsoft.Win32.Registry]::$hive.OpenSubKey($UpdatePolicyKey) } catch {}
        if (-not $k) { continue }
        try {
            $v = $k.GetValue($UpdatePolicyName)
            if ($hive -eq 'CurrentUser') { $out.Hkcu = $v }
            else {
                $out.Hklm = $v
                $out.HklmClaims = ($k.GetValueNames().Count -gt 0)
                # Anything under this key that is not ours belongs to somebody else - an employer's
                # MDM, most likely. Worth saying before we add to it, and worth not deleting on undo.
                $out.Foreign = @($k.GetValueNames() | Where-Object { $_ -and $_ -ne $UpdatePolicyName })
            }
        } finally { $k.Close() }
    }
    return $out
}

# Works for both install shapes: the MSIX package and the direct-download build both carry the app
# version on Claude.exe itself, so this needs no guess about how Claude got here.
function Get-ClaudeVersion {
    $exe = Find-ClaudeExe
    if (-not $exe) { return $null }
    try {
        $vi = (Get-Item $exe).VersionInfo
        $raw = if ($vi.ProductVersion) { $vi.ProductVersion } else { $vi.FileVersion }
        return [version](($raw -split '[^0-9.]')[0].Trim('.'))
    } catch { return $null }
}

# What the app will actually act on, after the HKLM-wins rule.
function Test-UpdatesBlocked($pol) {
    if ($pol.HklmClaims) { return ([string]$pol.Hklm -eq '1') }
    return ([string]$pol.Hkcu -eq '1')
}

function Show-UpdatePolicy($pol) {
    if (Test-UpdatesBlocked $pol) { Write-Host "Auto-updates: BLOCKED for every account on this PC" -ForegroundColor Green }
    else { Write-Host "Auto-updates: ON (Claude can update and relaunch itself)" -ForegroundColor Yellow }
    if ($pol.Hkcu -ne $null -and $pol.HklmClaims) {
        Write-Host "  A leftover per-user value exists at HKCU\$UpdatePolicyKey; HKLM overrides it." -ForegroundColor DarkGray
    }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# HKLM\SOFTWARE\Policies needs admin. Run the change in an elevated PowerShell and wait for it.
# Returns $true only if that process exited 0; a dismissed UAC prompt throws and lands on $false.
function Invoke-Elevated([string]$body) {
    if (Test-Elevated) {
        try { & ([scriptblock]::Create($body)); return $true } catch { Write-Host "Error: $_" -ForegroundColor Red; return $false }
    }
    $tmp = Join-Path $env:TEMP ("claude-toolbox-policy-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    Write-TextNoBom $tmp ("`$ErrorActionPreference = 'Stop'`ntry {`n$body`n exit 0 } catch { exit 1 }")
    try {
        Write-Host "Windows will ask for administrator rights - approve the prompt." -ForegroundColor Cyan
        $p = Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $tmp) -Verb RunAs -Wait -PassThru
        return ($p.ExitCode -eq 0)
    } catch {
        Write-Host "Administrator rights were not granted." -ForegroundColor Yellow
        return $false
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# Keeps 'winget upgrade --all' from putting the new build back. Only applies when Claude came from
# winget at all - a direct .exe download is not a winget package and there is nothing to pin, which
# is worth saying out loud rather than reporting a pin that does not exist.
function Set-WingetPin([switch]$Remove) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return 'no winget on this PC' }
    $wgArgs = if ($Remove) { @('pin', 'remove', '--id', 'Anthropic.Claude') }
              else { @('pin', 'add', '--id', 'Anthropic.Claude') }
    try {
        $out = & $winget.Source @wgArgs 2>&1
        if ($LASTEXITCODE -eq 0) { return $null }
        if ($out -match 'No installed package found') { return 'Claude was not installed through winget' }
        return ('winget said: ' + (($out | Select-Object -Last 1) -replace '\s+', ' ').Trim())
    } catch { return 'winget call failed' }
}

function Show-PinResult($why, [switch]$Remove) {
    $what = if ($Remove) { 'unpinned' } else { 'pinned' }
    if ($why) { Write-Host "The winget package was not $what - $why." -ForegroundColor DarkGray }
    else { Write-Host "The winget package is $what, so 'winget upgrade --all' leaves it alone." -ForegroundColor DarkGray }
}

function Invoke-UpdateLock {
    Write-Host ""
    Write-Host "Claude auto-updates" -ForegroundColor Green
    $pol = Get-UpdatePolicy
    Show-UpdatePolicy $pol
    Write-Host ""

    if (Test-UpdatesBlocked $pol) {
        Write-Host "Restoring auto-updates puts Claude back to updating and relaunching on its own,"
        Write-Host "for every account on this PC."
        if ((Read-Host "Restore auto-updates? (Y/N)") -notmatch '^(?i)y') { Write-Host "Left it blocked."; return }

        # Drop the value, and the key too if it is then empty - an empty key left behind would still
        # read as a managed device.
        $ok = Invoke-Elevated @"
  `$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('$UpdatePolicyKey', `$true)
  if (`$k) {
    `$k.DeleteValue('$UpdatePolicyName', `$false)
    `$empty = (`$k.GetValueNames().Count -eq 0 -and `$k.GetSubKeyNames().Count -eq 0)
    `$k.Close()
    if (`$empty) { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey('$UpdatePolicyKey', `$false) }
  }
  `$u = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('$UpdatePolicyKey', `$true)
  if (`$u) {
    `$u.DeleteValue('$UpdatePolicyName', `$false)
    `$empty = (`$u.GetValueNames().Count -eq 0 -and `$u.GetSubKeyNames().Count -eq 0)
    `$u.Close()
    if (`$empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('$UpdatePolicyKey', `$false) }
  }
"@
        if (-not $ok) { Write-Host "Nothing changed - auto-updates are still blocked." -ForegroundColor Yellow; return }
        $after = Get-UpdatePolicy
        if (Test-UpdatesBlocked $after) { Write-Host "The policy is still in place. Nothing changed." -ForegroundColor Red; return }
        Show-PinResult (Set-WingetPin -Remove) -Remove
        Write-Host ""
        Write-Host "Auto-updates restored." -ForegroundColor Green
        if ($after.Foreign.Count) {
            Write-Host ("Left the rest of the key alone - it still holds: " + ($after.Foreign -join ', ')) -ForegroundColor DarkGray
        }
        Write-Host "Takes effect after every Claude window is closed and reopened." -ForegroundColor Cyan
        return
    }

    Write-Host "Blocking means:"
    Write-Host "  - Claude stops downloading updates, so it never force-installs and never relaunches itself."
    Write-Host "  - One setting covers every account on this PC. There is nothing to repeat per account."
    Write-Host "  - Security and compatibility fixes stop arriving. You update by hand:"
    Write-Host "      winget upgrade --id Anthropic.Claude"
    Write-Host "  - The device is marked as managed, because this is a policy key."
    Write-Host "  - Needs administrator rights, and is reversible from this same menu option."

    $ver = Get-ClaudeVersion
    if ($ver -and $ver -lt $UpdatePolicySince) {
        Write-Host ""
        Write-Host ("This Claude is {0}, older than {1}, which is the build that started reading this" -f $ver, $UpdatePolicySince) -ForegroundColor Yellow
        Write-Host "policy. Setting it here would change nothing until Claude is newer." -ForegroundColor Yellow
    }
    if ($pol.Foreign.Count) {
        Write-Host ""
        Write-Host ("Careful: HKLM\{0} already carries someone else's settings ({1})." -f $UpdatePolicyKey, ($pol.Foreign -join ', ')) -ForegroundColor Yellow
        Write-Host "That usually means your employer manages this PC. Blocking adds one value beside" -ForegroundColor Yellow
        Write-Host "theirs and leaves the rest alone, but their policy may put it back." -ForegroundColor Yellow
    }

    Write-Host ""
    if ((Read-Host "Block Claude auto-updates? (Y/N)") -notmatch '^(?i)y') { Write-Host "Cancelled."; return }

    $ok = Invoke-Elevated @"
  `$k = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('$UpdatePolicyKey')
  `$k.SetValue('$UpdatePolicyName', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
  `$k.Close()
"@
    if (-not $ok) { Write-Host "Nothing changed - auto-updates are still on." -ForegroundColor Yellow; return }
    if (-not (Test-UpdatesBlocked (Get-UpdatePolicy))) { Write-Host "The policy did not take. Auto-updates are still on." -ForegroundColor Red; return }
    Show-PinResult (Set-WingetPin)

    Write-Host ""
    Write-Host "Auto-updates blocked for every account on this PC." -ForegroundColor Green
    Write-Host "The policy is read at launch, so close every Claude window - tray icon too - and reopen." -ForegroundColor Cyan
    Write-Host "An update already downloaded before now will still install once. After that, nothing." -ForegroundColor DarkGray
}

:menu while ($true) {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host "            Claude Desktop Toolbox            " -ForegroundColor White
    Write-Host "==============================================" -ForegroundColor DarkCyan
    $accts = @(Get-Accounts)
    if ($accts.Count) { Write-Host ("Accounts: " + (($accts | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join "   ")) -ForegroundColor DarkGray }
    else { Write-Host "No accounts set up yet - start with option 1." -ForegroundColor DarkGray }

    # One update closes every account's windows at once, and the extra accounts often fail to come
    # back up afterwards. Worth saying out loud once you are running more than one.
    $pol = $null
    try { $pol = Get-UpdatePolicy } catch {}
    if ($pol -and $accts.Count -gt 1 -and -not (Test-UpdatesBlocked $pol)) {
        Write-Host ""
        Write-Host "Auto-updates are ON. An update closes every account at once and can leave the extra" -ForegroundColor Yellow
        Write-Host "ones unable to start. With several accounts, option [8] is worth doing." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  [1] Set up extra Claude accounts"
    Write-Host "  [2] Copy a chat into another account"
    Write-Host "  [3] Replace a chat with another chat's history"
    Write-Host "  [4] Restart an account window"
    Write-Host "  [5] Export a chat to Desktop or Downloads"
    Write-Host "  [6] Import a chat from a file"
    Write-Host "  [7] Move a chat to the top of the list"
    if ($pol -and (Test-UpdatesBlocked $pol)) { Write-Host "  [8] Claude auto-updates (blocked - undo here)" }
    else { Write-Host "  [8] Block Claude auto-updates" }
    Write-Host "  [9] Exit"
    Write-Host ""
    switch (Read-Host "Choose") {
        '1' { try { Invoke-SetupAccounts } catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '2' { try { Invoke-CopyChat }      catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '3' { try { Invoke-ReplaceChat }   catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '4' { try { Invoke-RestartMenu }   catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '5' { try { Invoke-ExportChat }    catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '6' { try { Invoke-ImportChat }    catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '7' { try { Invoke-BumpChat }      catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '8' { try { Invoke-UpdateLock }    catch { Write-Host "Error: $_" -ForegroundColor Red }; Pause-Menu }
        '9' { break menu }
        default { }
    }
}
