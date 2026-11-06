<#
.SYNOPSIS
    Builds the conversation thread of a Claude Code transcript (.jsonl): every
    user message in full, where each reply is, and the actions that can be
    verified. Called by post-compact-reminder.ps1 after each compaction.

.DESCRIPTION
    A compaction summary drops details. The transcript keeps them, but it is
    megabytes of JSON: nobody reads it in full, and a keyword search in it is
    exactly how a request gets missed. The thread sits in between. It is small
    enough to be read in full, and every entry points back into the transcript.

    Default: writes %USERPROFILE%\.claude\threads\<session>.md and prints its path.
    -Message N : prints user message N and every text Claude wrote in reply.
    -Line N    : prints line N of the transcript in readable form (text, tool
                 call, tool result). This is the bridge from a thread entry
                 back to the exact error or output.

    "Actions" only lists what can be detected for certain: files written by
    Write/Edit/NotebookEdit, git commit, git push, and gh commands that write.
    Anything else, including a command the user ran themselves, is invisible:
    "none" does not prove that nothing was done.
#>
param(
    [Parameter(Mandatory)][string]$Transcript,
    [int]$Message = 0,
    [int]$Line = 0
)

# Same trap as the hook: without this assignment, -Message and -Line output is
# re-encoded in the console's ANSI codepage and every non-ASCII character is lost.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(0)

function Cut([string]$s, [int]$max) {
    if ($s.Length -gt $max) { $s.Substring(0, $max) + " [... $($s.Length - $max) characters cut]" } else { $s }
}

if ($Line -gt 0) {
    $n = 0
    foreach ($l in [IO.File]::ReadLines($Transcript, [Text.Encoding]::UTF8)) {
        if (++$n -lt $Line) { continue }
        try { $o = $l | ConvertFrom-Json } catch { "Line ${Line}: not valid JSON."; return }
        $time = if ($o.timestamp) { ([datetime]$o.timestamp).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        "## Line $Line - $($o.type) - $time"
        foreach ($c in @($o.message.content)) {
            if ($c -is [string]) { Cut $c 4000 }
            elseif ($c.type -eq 'text') { Cut $c.text 4000 }
            elseif ($c.type -eq 'tool_use') { "[call $($c.name)]"; Cut ($c.input | ConvertTo-Json -Depth 5 -Compress) 3000 }
            elseif ($c.type -eq 'tool_result') {
                "[result$(if ($c.is_error) { ' - ERROR' })]"
                $r = if ($c.content -is [string]) { $c.content } else { (@($c.content) | Where-Object type -eq 'text' | ForEach-Object text) -join "`n" }
                Cut $r 3000
            }
        }
        return
    }
    "No line $Line (the transcript has $n)."; return
}

# One pass over the transcript. Variable names must not collide with the
# parameters: PowerShell is case-insensitive, so a loop variable $line would
# silently be cast to [int] by the -Line parameter.
$messages = [Collections.Generic.List[object]]::new()
$texts    = [Collections.Generic.List[object]]::new()
$actions  = [Collections.Generic.List[object]]::new()
$pending  = @{}    # tool call id -> actions of that call, waiting for their result
$home_    = $env:USERPROFILE
$n = 0
foreach ($raw in [IO.File]::ReadLines($Transcript, [Text.Encoding]::UTF8)) {
    $n++
    # Cheap string checks before any JSON parsing: transcripts run to megabytes.
    $isHuman  = $raw.Contains('"kind":"human"')
    $isClaude = $raw.StartsWith('{') -and $raw.Contains('"type":"assistant"') -and
                ($raw.Contains('"type":"text"') -or $raw.Contains('"type":"tool_use"'))

    # Tool result: matched by pattern, never parsed (these lines can be huge).
    if ($pending.Count -and $raw.Contains('"tool_use_id"')) {
        $id = [regex]::Match($raw, '"tool_use_id":"([^"]+)"').Groups[1].Value
        if ($pending.ContainsKey($id)) {
            $isError = $raw.Contains('"is_error":true')
            # The command never ran: the whole call failed, and the cause is known.
            $cause = if ($raw.Contains('"toolDenialKind":"interrupted"')) { 'interrupted' }
                     elseif ($raw.Contains('denied by the Claude Code auto mode classifier')) { 'denied by auto mode' }
                     elseif ($raw.Contains("The user doesn't want to proceed") -or $raw.Contains('Permission for this action was denied')) { 'denied by the user' }
            foreach ($a in $pending[$id]) {
                $a.Result = $n
                if (-not $isError) { $a.Ok = $true; continue }
                if ($cause) { $a.Ok = $false; $a.Cause = $cause; continue }
                # The command ran and failed somewhere: a commit and a push run in
                # one command are told apart by git's own output.
                $a.Ok = switch ($a.What) {
                    'commit' { if ($raw -match '\[[^\]\s]+ [0-9a-f]{7,}\]') { $true }
                               elseif ($raw -match 'nothing to commit|nothing added to commit|Aborting commit|Please tell me who you are') { $false }
                               else { $null } }
                    'push'   { if ($raw -match 'rejected|failed to push|fatal:') { $false }
                               elseif ($raw -match 'Everything up-to-date|\S+ -> \S+') { $true }
                               else { $false } }
                    default  { $false }
                }
            }
            $pending.Remove($id)
            continue
        }
    }
    if (-not ($isHuman -or $isClaude)) { continue }
    try { $o = $raw | ConvertFrom-Json } catch { continue }

    if ($o.type -eq 'user' -and $o.origin.kind -eq 'human') {
        $parts = @()
        foreach ($c in @($o.message.content)) {
            if ($c -is [string]) { $parts += $c }
            elseif ($c.type -eq 'text') { $parts += $c.text }
            elseif ($c.type -eq 'image') { $parts += '[image]' }
        }
        $text = ($parts -join "`n").Trim()
        if ($text -match '<command-name>(.*?)</command-name>[\s\S]*?<command-args>(.*?)</command-args>') {
            $text = "[command] $($Matches[1]) $($Matches[2])".Trim()
        }
        elseif ($text -match '^<local-command|^This session is being continued') { continue }
        $text = [regex]::Replace($text, '<system-reminder>[\s\S]*?</system-reminder>', '').Trim()
        if (-not $text) { continue }
        $time = if ($o.timestamp) { ([datetime]$o.timestamp).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
        $messages.Add([pscustomobject]@{ Line = $n; Time = $time; Text = $text })
    }
    elseif ($o.type -eq 'assistant') {
        foreach ($c in @($o.message.content)) {
            if ($c.type -eq 'text' -and $c.text.Trim()) { $texts.Add([pscustomobject]@{ Line = $n; Text = $c.text.Trim() }) }
            elseif ($c.type -eq 'tool_use') {
                $done = @()
                if ($c.name -in 'Write', 'Edit', 'NotebookEdit') {
                    $path = [string]$c.input.file_path
                    if ($path.StartsWith($home_, 'OrdinalIgnoreCase')) { $path = '~' + $path.Substring($home_.Length) }
                    $done += "modified $path"
                }
                elseif ($c.name -in 'PowerShell', 'Bash') {
                    $cmd = [string]$c.input.command
                    if ($cmd -match '\bgit\b[^|;\r\n]*\bcommit\b') { $done += 'commit' }
                    if ($cmd -match '\bgit\b[^|;\r\n]*\bpush\b') { $done += 'push' }
                    # gh: only what writes to GitHub, not reads (view, list, api GET).
                    if ($cmd -match '\bgh\s+api\b[^|;\r\n]*(-X|--method)\s*(POST|PATCH|PUT|DELETE)') { $done += "gh api $($Matches[2])" }
                    if ($cmd -match '\bgh\s+(repo|pr|issue|release)\s+(create|edit|delete|rename|merge|close|comment|archive)\b') { $done += "gh $($Matches[1]) $($Matches[2])" }
                }
                if ($done) {
                    $list = foreach ($d in $done) { [pscustomobject]@{ Line = $n; What = $d; Ok = $null; Result = $null; Cause = $null } }
                    $list | ForEach-Object { $actions.Add($_) }
                    $pending[$c.id] = @($list)
                }
            }
        }
    }
}

# Reply to message k: whatever Claude wrote between message k and message k+1.
function Between($list, [int]$k) {
    $from = $messages[$k - 1].Line
    $to = if ($k -lt $messages.Count) { $messages[$k].Line } else { [int]::MaxValue }
    $list | Where-Object { $_.Line -gt $from -and $_.Line -lt $to }
}
function Reply([int]$k) { Between $texts $k }

# Actions of message k, grouped: "modified X (3x)". A failure points to the
# line of the call and the line of its result, where the error is (-Line N).
function Actions([int]$k) {
    $list = @(Between $actions $k)
    if (-not $list.Count) { return 'none' }
    $parts = foreach ($g in ($list | Group-Object What)) {
        $t = $g.Name
        if ($g.Count -gt 1) { $t += " ($($g.Count)x)" }
        $ko = @($g.Group | Where-Object { $_.Ok -eq $false })
        $unknown = @($g.Group | Where-Object { $null -eq $_.Ok })
        if ($ko.Count) {
            $t += " - FAILED $($ko.Count) (" + (($ko | ForEach-Object { "$($_.Line)->$($_.Result)$(if ($_.Cause) { " $($_.Cause)" })" }) -join ', ') + ')'
        }
        if ($unknown.Count) {
            $t += " - result unknown (" + (($unknown | ForEach-Object { if ($_.Result) { "$($_.Line)->$($_.Result)" } else { "$($_.Line), no result" } }) -join ', ') + ')'
        }
        $t
    }
    $parts -join ' | '
}

if ($Message -gt 0) {
    if ($Message -gt $messages.Count) { "No message $Message (there are $($messages.Count))."; return }
    $m = $messages[$Message - 1]
    "## User $Message - $($m.Time) - line $($m.Line)`n$($m.Text)`n"
    foreach ($t in (Reply $Message)) { "### Claude - line $($t.Line)`n$($t.Text)`n" }
    return
}

$self = $MyInvocation.MyCommand.Path
$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine("# Conversation thread`n")
[void]$sb.AppendLine("Every user message, in full. 'Actions' only lists files written by Write/Edit and git commit, git push and")
[void]$sb.AppendLine("gh commands that write. 'none' does not prove nothing was done: the user may have done it. Ask, do not assume.")
[void]$sb.AppendLine("A failure '1227->1228': the call is at line 1227 of the transcript, its result (the error) at line 1228.")
[void]$sb.AppendLine("~ = $home_")
[void]$sb.AppendLine("Claude's reply to message N, then line N of the transcript, readable:")
[void]$sb.AppendLine("powershell -NoProfile -File `"$self`" -Transcript `"$Transcript`" -Message N")
[void]$sb.AppendLine("powershell -NoProfile -File `"$self`" -Transcript `"$Transcript`" -Line N`n")
for ($k = 1; $k -le $messages.Count; $k++) {
    $m = $messages[$k - 1]
    $r = @(Reply $k)   # @(): PowerShell 5.1 has no .Count on a single object
    $info = if ($r.Count) { "reply: $($r.Count) text(s), lines $($r[0].Line)-$($r[-1].Line)" } else { 'no written reply' }
    [void]$sb.AppendLine("## $k - $($m.Time) - line $($m.Line) - $info`n$($m.Text)`nActions: $(Actions $k)`n")
}
$folder = Join-Path $home_ '.claude\threads'
[void][IO.Directory]::CreateDirectory($folder)
$target = Join-Path $folder ([IO.Path]::GetFileNameWithoutExtension($Transcript) + '.md')
[IO.File]::WriteAllText($target, $sb.ToString(), [Text.UTF8Encoding]::new($false))
$target
