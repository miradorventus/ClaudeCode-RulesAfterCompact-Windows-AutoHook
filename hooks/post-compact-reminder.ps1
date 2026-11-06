<#
.SYNOPSIS
    Claude Code SessionStart hook - re-injects your rules file after compaction,
    and tells Claude where the full pre-compaction transcript is.

.DESCRIPTION
    Claude Code fires SessionStart with source "compact" right after it compacts
    the conversation. This script prints your rules file to stdout, and Claude
    Code injects that stdout straight into the model's context.

    Compaction replaces the conversation with a summary, and a summary drops
    details. The transcript itself is not lost: Claude Code passes its path on
    stdin (transcript_path). The script prints that path after the rules, so
    Claude can re-read an exact value, path or command instead of trusting the
    summary.

    If build-thread.ps1 sits next to this script, it also builds the
    conversation thread (every user message in full, with pointers into the
    transcript) and prints its path with instructions to read it.

    The single most important line in this file is the OutputEncoding assignment
    below. Without it, Windows PowerShell re-encodes stdout in the console's ANSI
    codepage; Claude Code then decodes it as UTF-8 and every non-ASCII character
    is destroyed. Silently. See the README.

.PARAMETER RulesFile
    Path to the file to inject. Defaults to the user-level CLAUDE.md.
#>
param(
    [string]$RulesFile = (Join-Path $env:USERPROFILE ".claude\CLAUDE.md")
)

# --- Required. Do not remove. -----------------------------------------------
# Reading [Console]::OutputEncoding is NOT a valid check: it can report utf-8
# while the stream is still being mangled. It has to be ASSIGNED, which is what
# rebuilds the cached stdout writer.  0 = no BOM.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(0)
# ----------------------------------------------------------------------------

# Claude Code caps hook stdout at 10,000 characters. Above that it keeps only a
# 2,000-character preview and does not ask Claude to read the rest.
$cap = 10000

# Hook input arrives as JSON on stdin. Only read it when stdin is redirected:
# run by hand from a console, ReadToEnd() would wait forever.
$transcript = $null
if ([Console]::IsInputRedirected) {
    try { $transcript = ([Console]::In.ReadToEnd() | ConvertFrom-Json).transcript_path } catch {}
}

$footer = ""
if ($transcript) {
    $footer = "`n`n---`nFull transcript of this session, including everything before the compaction: $transcript`n" +
              "Before stating a detail from before the compaction (a value, a path, a command), re-read it there."

    # Optional: the conversation thread, built by build-thread.ps1 if it sits
    # next to this script. Every user message in full, with pointers into the
    # transcript, small enough to be read in full.
    $builder = Join-Path $PSScriptRoot "build-thread.ps1"
    if (Test-Path -LiteralPath $builder) {
        try {
            $thread = & $builder -Transcript $transcript
            $size = [IO.File]::ReadAllText($thread, [Text.Encoding]::UTF8).Length
            $footer += "`nConversation thread (every user message in full, where each reply is, verified actions): $thread`n"
            # Up to 40,000 characters (about 10,000 tokens) the thread is read in
            # full. Beyond that, a full read costs too much: search, then read.
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
    # Fail quietly: a hook that errors on every compaction is worse than one
    # that says nothing. Claude Code treats non-zero exits as hook failures.
    Write-Output ("Context was compacted, but the rules file was not found at: $RulesFile" + $footer)
    exit 0
}

$rules = Get-Content -Raw -Encoding UTF8 -LiteralPath $RulesFile
$out = "Context was just compacted. Your standing rules are restored below - they apply to everything that follows.`n`n" +
       $rules + $footer

if ($out.Length -gt $cap) {
    # Never let the rules be silently cut to a preview.
    $out = "Context was just compacted. Your rules file is too long to be injected ($($out.Length) characters, " +
           "the hook limit is $cap). Tell the user, then read $RulesFile in full before doing anything else." + $footer
}

Write-Output $out
exit 0
