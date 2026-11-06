# AutoHook

[🇫🇷 Version française](README.fr.md)

**Claude Code forgets your standing rules every time it compacts the
conversation. This puts them back.** For Windows, where the obvious fix
silently destroys every accented character before Claude ever reads it.

It also tells Claude where the full transcript is. Compaction keeps a summary,
and a summary drops details; the transcript on disk does not. After each
compaction Claude gets its path, so an exact value, path or command from before
the compaction can be re-read instead of recalled from the summary.

And because nobody reads megabytes of JSON in full, it builds a **conversation
thread**: every message you wrote, in full, with where Claude's reply is and
what was actually done (files written, commits, pushes, with their result).
Small enough to be read in full after each compaction, and every entry points
back into the transcript. Built for the moment Claude says "you never asked me
that" when you did.

## Install

Copy this and paste it into Claude Code. Nothing to download, nothing to run.

Claude Code will stop and ask your permission partway through, because the
files it needs to touch live outside your project folder. That prompt is the
install working, not failing. Approve it: it edits exactly one file, `settings.json`,
and backs it up first.

Near the end it asks a second time, separately: whether to add two short rules
to your `CLAUDE.md`. They are what make Claude actually use the thread (re-read
before stating a detail; never assume an action was done without a trace).
Optional, shown to you in full before anything is written, and backed up too.

```
Install a post-compaction rules reminder hook for Claude Code on this Windows machine.

STEP 1 - Create %USERPROFILE%\.claude\hooks\post-compact-reminder.ps1 with exactly this content:

    param([string]$RulesFile = (Join-Path $env:USERPROFILE ".claude\CLAUDE.md"))

    # Required. Reading [Console]::OutputEncoding is NOT a valid check - it can
    # report utf-8 while the stream is still mangled. It must be ASSIGNED.
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new(0)

    # Claude Code caps hook stdout at 10,000 characters, then keeps a preview only.
    $cap = 10000

    # Hook input is JSON on stdin. Read it only when redirected: run by hand
    # from a console, ReadToEnd() would wait forever.
    $transcript = $null
    if ([Console]::IsInputRedirected) {
        try { $transcript = ([Console]::In.ReadToEnd() | ConvertFrom-Json).transcript_path } catch {}
    }

    $footer = ""
    if ($transcript) {
        $footer = "`n`n---`nFull transcript of this session, including everything before the compaction: $transcript`n" +
                  "Before stating a detail from before the compaction (a value, a path, a command), re-read it there."

        # The conversation thread, built by build-thread.ps1 (step 1b) if it sits next to this script.
        $builder = Join-Path $PSScriptRoot "build-thread.ps1"
        if (Test-Path -LiteralPath $builder) {
            try {
                $thread = & $builder -Transcript $transcript
                $size = [IO.File]::ReadAllText($thread, [Text.Encoding]::UTF8).Length
                $footer += "`nConversation thread (every user message in full, where each reply is, verified actions): $thread`n"
                # Up to 40,000 characters (about 10,000 tokens) it is read in full; beyond, searched.
                if ($size -le 40000) {
                    $footer += "Read it IN FULL before stating what was asked, done or decided. For a detail, read the reply " +
                               "or the transcript line it points to (commands at the top of the thread)."
                } else {
                    $footer += "It is $size characters: search it with several keywords (synonyms too), read IN FULL every " +
                               "message found and its neighbours, then the reply or line it points to. Never conclude from an empty search."
                }
            } catch {
                $footer += "`nConversation thread: build failed ($($_.Exception.Message))."
            }
        }
    }

    if (-not (Test-Path -LiteralPath $RulesFile)) {
        Write-Output ("Context was compacted, but no rules file was found at: $RulesFile" + $footer)
        exit 0
    }

    $out = "Context was just compacted. Your standing rules are restored below - they apply to everything that follows.`n`n" +
           (Get-Content -Raw -Encoding UTF8 -LiteralPath $RulesFile) + $footer

    if ($out.Length -gt $cap) {
        $out = "Context was just compacted. Your rules file is too long to be injected ($($out.Length) characters, " +
               "the hook limit is $cap). Tell the user, then read $RulesFile in full before doing anything else." + $footer
    }

    Write-Output $out
    exit 0

Save it as pure ASCII with no BOM.

STEP 1b - Create %USERPROFILE%\.claude\hooks\build-thread.ps1 with exactly this content,
also pure ASCII with no BOM. It builds the conversation thread; the hook above
calls it, and works without it if it is missing.

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

STEP 2 - Edit %USERPROFILE%\.claude\settings.json. This is my GLOBAL Claude Code
settings file, outside any project, so tell me plainly that the hook will then fire
in every Claude Code session on this machine - and ask for permission in one go,
naming that one file and nothing else.

If the file already exists, copy it to settings.json.bak-autohook first.
If it does NOT exist, create it, and also create an empty marker file next to it
named settings.json.absent-before-autohook, so the uninstall knows the file was not
there before and can remove it cleanly.

Then add this entry. Merge carefully - do NOT overwrite anything:
  - if there is no "hooks" object, create it;
  - if "hooks" exists but has no "SessionStart", add that key;
  - if "SessionStart" already exists, APPEND this object to its array and leave
    every existing entry untouched. Other hooks with other matchers are normal;
  - if an entry with matcher "compact" pointing at post-compact-reminder.ps1 is
    already present, this is a re-install: replace only that one entry.
Keep everything else in the file byte-for-byte identical:

    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\hooks\\post-compact-reminder.ps1\"",
            "timeout": 15,
            "statusMessage": "Restoring standing rules after compaction"
          }
        ]
      }
    ]

Expand %USERPROFILE% to the real absolute path before writing it - a relative path
breaks the hook. Validate that the file is still valid JSON after the edit.

STEP 3 - Verify, then show me the output. Two things make a naive check useless
here, so run exactly this and nothing else: my own rules file may be pure ASCII,
and this bug does not occur at all when the console codepage is already 65001.
The test therefore supplies its own characters AND forces a codepage that fails.

    $hook  = "$env:USERPROFILE\.claude\hooks\post-compact-reminder.ps1"
    $probe = Join-Path $env:TEMP "autohook-probe.md"
    $out   = Join-Path $env:TEMP "autohook-out.txt"
    $want  = "accents " + [char]0xE9 + [char]0xE8 + " arrow " + [char]0x2192
    [IO.File]::WriteAllText($probe, $want, (New-Object Text.UTF8Encoding $false))
    $cl = 'chcp 1252 >nul && powershell -NoProfile -ExecutionPolicy Bypass -File "' +
          $hook + '" -RulesFile "' + $probe + '" > "' + $out + '"'
    cmd /c $cl
    ([IO.File]::ReadAllBytes($out) | Where-Object { $_ -gt 127 } |
       Select-Object -First 10 | ForEach-Object { "{0:X2}" -f $_ }) -join " "

Report the byte list verbatim.

    PASS   C3 A9 C3 A8 E2 86 92      multi-byte UTF-8, the fix is working
    FAIL   E9 E8   or   82 8A        lone high bytes, and the arrow vanished

On FAIL the script is missing the [Console]::OutputEncoding assignment, or it
was saved with a BOM. Stop and tell me - do not make it pass by dropping the
chcp, which is what makes the test meaningful.

Then check the thread on a real transcript: take the most recently modified
.jsonl file under %USERPROFILE%\.claude\projects, run
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\build-thread.ps1" -Transcript "<that file>"
and report the path it prints, the size of that file in characters, and its
first message entry. Do not paste the whole thread.

STEP 4 - Two rules make Claude actually use the thread. Show them to me as they
are below, and ask whether to add them to %USERPROFILE%\.claude\CLAUDE.md. This is
a second file outside the project: ask for it separately, do not fold it into
the step 2 permission. If I say no, skip to STEP 5.

On yes:
  - if CLAUDE.md exists, copy it to CLAUDE.md.bak-autohook first; if it does
    not, create it;
  - if it already holds rules on the same subject (re-reading after a
    compaction, or assuming an action was done), do not add duplicates: show
    me both versions and ask which to keep;
  - append them at the end, under headings that match the style of the file.
    If the file is written in another language, translate them faithfully
    into that language, without shortening them;
  - keep everything already in the file byte-for-byte, and save it as UTF-8.

    ## After a compaction, re-read before stating
    After a compaction, a detail of the conversation (a value, a path, a
    command, a result, a decision) is re-read before it is stated: first the
    conversation thread (what was asked, done, decided), in full or by
    keywords as the hook says, then the transcript at the line it points to.
    The paths are given by the hook. The summary loses details; the
    transcript does not.

    ## No trace, no action
    An action counts as done only if a trace shows it: a file changed, a
    commit, a command result. Without a trace, do not assume it was done:
    ask me in one sentence whether I did it myself.

STEP 5 - Tell me whether %USERPROFILE%\.claude\CLAUDE.md exists and its size in
characters, since its whole content is re-injected at every compaction. Claude
Code caps hook output at 10,000 characters, and the hook adds 750 to 1,000 of
its own (header, transcript path, thread path and reading rule, depending on
the length of the paths): above roughly 9,000 characters, the hook replaces the
rules with a warning. If the file is
over that, say so plainly. If it does not exist, say so: the hook has nothing
to inject until I create it.
```

That is the whole install. Nothing visible happens until your next compaction -
then your rules come back on their own, followed by the transcript and thread
paths. Right after a compaction, ask Claude what your standing rules are, and
what you asked it earlier in the session: you will know it worked.

---

<details>
<summary><b>Uninstall</b></summary>

One command in PowerShell. It puts `settings.json` back the way it was - restoring
the backup if the file already existed, removing it if the install created it -
and deletes the hook script.

```powershell
$c = "$env:USERPROFILE\.claude"
if (Test-Path "$c\settings.json.bak-autohook") {
  Copy-Item "$c\settings.json.bak-autohook" "$c\settings.json" -Force
  Remove-Item "$c\settings.json.bak-autohook" -Force
  "settings.json restored from backup"
} elseif (Test-Path "$c\settings.json.absent-before-autohook") {
  Remove-Item "$c\settings.json" -Force -ErrorAction SilentlyContinue
  Remove-Item "$c\settings.json.absent-before-autohook" -Force
  "settings.json removed - it did not exist before the install"
} else { "no backup and no marker - remove the SessionStart compact entry by hand" }
Remove-Item "$c\hooks\post-compact-reminder.ps1", "$c\hooks\build-thread.ps1" -Force -ErrorAction SilentlyContinue
"hook removed"
```

Your threads stay in `%USERPROFILE%\.claude\threads`. They are copies of your own
messages; delete that folder if you do not want them kept.

If you added the two rules in step 4, they stay in your `CLAUDE.md`: they are
your rules now, and the command above does not touch that file. Remove them by
hand, or with the paste below. `CLAUDE.md.bak-autohook` holds the file as it was
before, but restoring it would also undo anything you added since.

The first branch restores a backup, so anything else you changed in
`settings.json` after installing goes back too. Minutes after an install that is
nothing; months later it might not be, and then the paste below is safer.

Or paste this into Claude Code instead:

```
Remove the AutoHook post-compaction hook from this machine: delete the
"SessionStart" entry whose matcher is "compact" and whose command points at
post-compact-reminder.ps1 from %USERPROFILE%\.claude\settings.json, keeping every
other setting byte-for-byte. If that entry was the only thing in the file and
a settings.json.absent-before-autohook marker is present, delete both instead.
Then delete %USERPROFILE%\.claude\hooks\post-compact-reminder.ps1 and
%USERPROFILE%\.claude\hooks\build-thread.ps1. Finally, show me the two rules
"After a compaction, re-read before stating" and "No trace, no action" (or
their translation) if they are in %USERPROFILE%\.claude\CLAUDE.md, and ask me
whether to remove them; on yes, remove only those two, byte-for-byte the rest.
```
</details>

<details>
<summary><b>The conversation thread</b></summary>

The transcript keeps everything, but it is megabytes of JSON: 7 MB for the
session this was built in. Claude cannot read it in full, so it searches it,
and a narrow keyword search is exactly how a request gets missed. That is what
happened here, before the thread existed: asked about a GitHub update requested
an hour earlier, Claude answered that it had never been asked.

The thread is the layer in between, rebuilt from the transcript at every
compaction (`%USERPROFILE%\.claude\threads\<session>.md`). One entry per message
you wrote:

```
## 36 - 2026-11-06 23:33 - line 1260 - reply: 1 text(s), lines 1274-1274
No, I already ran them.
Actions: none
```

- **Your messages, in full.** They are what the session is about, and they are
  short. Claude's replies are not copied, only located: `-Message 36` prints
  them in full when a detail is needed.
- **Actions, with their result.** Files written by Write/Edit, `git commit`,
  `git push`, and `gh` commands that write to GitHub. A failure points to the
  line of the call and the line of its result, `1227->1228`, and `-Line 1228`
  prints that error in clear. When the command never ran, the cause is written
  down: denied by auto mode, denied by the user, interrupted.
- **A commit and a push in one command are judged separately**, from git's own
  output. When git said nothing conclusive, the thread says `result unknown`
  and points to the line, rather than guess.

What it does not see: any other command, and anything you did yourself, such
as running a command Claude proposed. That is why `none` proves nothing, and
the thread says so in its header. The right move then is to ask, not assume.

**Reading rule**, given to Claude by the hook: up to 40,000 characters the
thread is read in full; beyond that, it is searched with several keywords, and
every message found is read in full with its neighbours.

</details>

<details>
<summary><b>Why a prompt, and not an installer</b></summary>

Because a downloaded installer does not run on a default Windows machine.
Measured, on Windows 11 with factory settings:

```
> powershell -File install.ps1
install.ps1 cannot be loaded. The file is not digitally signed.
You cannot run this script on the current system.                    exit 1
```

That is the installer this repo deliberately does not ship. The blocker is
`ExecutionPolicy = RemoteSigned`, the default for the current user, and
it applies to any `.ps1` that carries the Mark of the Web — which every file
downloaded from GitHub does. Getting past it takes a paid code-signing
certificate, or teaching users to disable their own security. Neither is
shipping.

A prompt removes that surface. Claude writes the file locally, and a locally
created file carries no Mark of the Web - which is the whole of what
`RemoteSigned` refuses. Measured both ways on the same script: unmarked it runs,
marked it is rejected. Everyone installing a Claude Code hook already has the
installer: Claude.

Execution policy does not stop existing, of course, and you will notice the hook
command passes `-ExecutionPolicy Bypass`. That is there for anyone on `AllSigned`
or `Restricted`, where even a local script is refused. Two things about that flag:
it lasts exactly as long as that one process and changes nothing on the machine,
and it is the tool applying it to itself rather than you being told to loosen a
setting of your own. That distinction is the entire point of this repo. Nobody
should have to switch a protection off to install a reminder.

(Smart App Control, for the record, is not the blocker here. It was enforcing on
the test machine and PowerShell still ran in FullLanguage.)

</details>

<details>
<summary><b>The encoding trap this exists for</b></summary>

Claude Code injects a hook's stdout directly into the model's context. On
Windows, PowerShell re-encodes that stdout in the console's ANSI codepage on the
way out. Claude Code then decodes it as UTF-8. Everything non-ASCII is
destroyed — silently, with no error and nothing in the logs.

Measured on the same string, same machine, with and without the one-line fix:

```
console codepage   with the fix              without it
cp1252             C3 A9 C3 A8 E2 86 92      E9 E8        arrow gone
cp850              C3 A9 C3 A8 E2 86 92      82 8A        arrow gone
cp65001            C3 A9 C3 A8 E2 86 92      C3 A9 C3 A8 E2 86 92
```

Read the last row carefully: **on a console already set to UTF-8 the bug does
not happen at all.** That is why it is invisible to some people and destructive
for others, why it will not reproduce on demand, and why a check run from the
wrong shell will happily report success on a broken hook. Characters that the
codepage cannot represent at all - the arrow above, or an emoji - do not become
a wrong byte; they are replaced by a literal `3F` question mark and are gone.
**The check that looks like proof, and is not:**

```powershell
[Console]::OutputEncoding.WebName    # => utf-8
[Console]::OutputEncoding.CodePage   # => 65001
```

Both already read UTF-8 while the output above was still being mangled. Reading
the property proves nothing. The encoding has to be **assigned**, which is what
rebuilds the cached stdout writer:

```powershell
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(0)   # 0 = no BOM
```

One statement, prepended to the hook. With it, the round-trip is byte-identical.

Note that `Get-Content -Encoding UTF8` does **not** cover this. That fixes
reading the file. The corruption happens on the way out.

</details>

<details>
<summary><b>What it costs you</b></summary>

The hook injects the **whole** rules file, every time the conversation is
compacted. That is a recurring token cost, so keep the file short: a page of
standing rules is the right size, a 76 KB architecture document is not.

There is also a hard limit. Claude Code caps a hook's stdout at **10,000
characters**; above that it saves the output to a file, passes Claude only a
2,000-character preview, and does not ask Claude to read the rest. The cap
cannot be raised. Rather than let your rules be cut to a preview without
anyone noticing, the hook checks its own output length: over the cap, it tells
Claude the file is too long, to say so to you, and to read it in full.

If your rules file is large, point the hook at a short summary instead and let
Claude read the full document on demand:

```
-RulesFile "C:\Users\YOU\.claude\RULES-SHORT.md"
```

The upstream Bash project takes the other approach - it injects a one-line
reminder telling Claude to re-read the file. That is cheaper per compaction but
depends on Claude actually performing the read. Injecting the content is more
reliable and costs more. Pick per file size.

The thread has its own cost, paid only when Claude reads it. Measured on a
53-message session with a 7 MB transcript: 18,317 characters, built in 0.6 s.
At roughly 4 characters per token (an estimate, not a count) that is about
4,500 tokens. It grows by about 350 characters per message you write, which is
why the hook switches from a full read to a search above 40,000 characters.

</details>

<details>
<summary><b>Reading it before you run it</b></summary>

You should not paste a prompt that writes a script onto your machine without
knowing what the scripts do. All the pieces are here:

- [hooks/post-compact-reminder.ps1](hooks/post-compact-reminder.ps1) - the hook
- [hooks/build-thread.ps1](hooks/build-thread.ps1) - the thread builder; it only
  reads the transcript and writes one file under `.claude\threads`
- [settings.example.json](settings.example.json) - the settings entry

**They are here to be read, not downloaded.** Save that `.ps1` from GitHub and run
it and Windows will refuse it - unsigned, Mark of the Web - which is the exact
error at the top of this page. That is not a flaw in the file; it is the reason
the install is a prompt. The prompt contains the same script verbatim, and
Claude writes it locally where the policy does not apply.

If you would rather type it out yourself, two rules:

- Use an **absolute** path in the hook command. A relative path breaks it.
- Save the `.ps1` as **pure ASCII, no BOM**. PowerShell 5.1 reads a BOM-less
  file as ANSI, so any non-ASCII character in the script itself is a second
  instance of the same bug.

</details>

<details>
<summary><b>Notes for anyone writing Claude Code hooks on Windows</b></summary>

Collected the hard way, each one field-tested:

- **`Get-Content` without `-Encoding UTF8` reads UTF-8 files as ANSI.** Silent.
- **Python writing non-ASCII to a Windows pipe raises `UnicodeEncodeError`.**
  Force it: `sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')`.
- **Setting anything through an API from the shell can corrupt it.** Send a
  pure-ASCII JSON body with `\uXXXX` escapes instead — no encoding layer can
  damage ASCII.
- **`$args` is a PowerShell automatic variable.** Naming a `param()` entry
  `$args` fails in ways that look like a logic bug.
- **`ConvertFrom-Json` in PowerShell 5.1 merges multi-line input** into one
  object whose properties are arrays. You get 1 result where there were 15.
  Join first: ``($output -join "`n") | ConvertFrom-Json``.
- **A hook that exits non-zero on every session start is worse than no hook.**
  Fail quietly and say why in stdout.
- **PowerShell variable names are case-insensitive, parameters included.** A
  loop variable `$line` in a script with a `[int]$Line` parameter is silently
  cast to `[int]`, and the first JSON line fails to convert.
- **A function that returns a single object has no `.Count` in PowerShell 5.1.**
  Wrap the call: `$r = @(MyFunction)`.
- **Transcript lines can be megabytes.** Filter with plain string checks
  (`.Contains(...)`) before `ConvertFrom-Json`: 7 MB in 0.6 s instead of minutes.
- **A tool result is matched to its call by `tool_use_id`**, and a failure is
  `"is_error":true` on the result line. A denied or interrupted command also
  sets it, without ever having run.

</details>

<details>
<summary><b>Tested on</b></summary>

- Windows 11 Pro 26100, Windows PowerShell 5.1.26100
- Smart App Control enforcing; PowerShell 7 not tested

**Independently verified end to end on a second Windows machine**, by someone who
had not seen the project, working from this page alone:

- the install prompt ran through, including the permission stop
- the check returned `C3 A9 C3 A8 E2 86 92` - correct UTF-8 under a forced cp1252
  console, the condition an unfixed hook fails
- a real `/compact` fired the hook, and their own accented rules came back intact:
  `ç` as `C3 A7`, an em dash as `E2 80 94`, nothing replaced

Every link is measured: disk, PowerShell, hook stdout, model context. Nothing in
this README is inferred.

**Transcript path and length check** (added later), tested on Windows 11 Pro 26300,
Windows PowerShell 5.1, by feeding the hook the JSON Claude Code sends on stdin:

- with `transcript_path` on stdin, the path is printed after the rules
- with no stdin at all (the check in step 3), the hook still exits at once, and
  the byte check still returns `C3 A9 C3 A8 E2 86 92`
- with a rules file over the cap, the warning replaces the rules

The field name and the 10,000-character cap come from the
[hooks reference](https://code.claude.com/docs/en/hooks).

A real `/compact` was then run on Windows 11 Pro 26300 with the same logic (the
author's copy, with French messages): the full rules file and the transcript path
both reached the model context, accents intact, and the transcript at that path
held the conversation from before the compaction.

**Conversation thread** (added later), on a real 7 MB transcript: the hook exits 0
under a forced cp1252 console, both scripts are pure ASCII, a rejected push and a
push denied by auto mode each show up with their cause, and above 40,000
characters the reading rule switches to a search. In a real `/compact`, "what
did I ask for the GitHub repo, and who ran the commands?" was answered correctly
from the thread alone. Not yet run end to end on a fresh machine: the install
prompt's new steps 4 and 5.
</details>

<details>
<summary><b>Prior art</b></summary>

This is the Windows-native complement to work that already exists, not a
replacement for it:

- **[Dicklesworthstone/post_compact_reminder](https://github.com/Dicklesworthstone/post_compact_reminder)**
  — the original, and where the `SessionStart` + `matcher: "compact"` approach
  comes from. Bash; Linux, macOS and WSL. If you are on any of those, use it.
- **[hagigi0405/claude-code-hooks-windows-traps](https://github.com/hagigi0405/claude-code-hooks-windows-traps)**
  — field-tested Windows hook pitfalls on a Japanese (cp932) system. Covers the
  **stdin** side: exit-code semantics, JSON payload corruption on input,
  relative-path breakage, hot reload. This repo covers the **stdout** side.

No code from either is used here.

</details>

---

MIT - see [LICENSE](LICENSE).
