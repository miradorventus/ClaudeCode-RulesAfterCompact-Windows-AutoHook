<#
.SYNOPSIS
    Claude Code SessionStart hook - re-injects your rules file after compaction.

.DESCRIPTION
    Claude Code fires SessionStart with source "compact" right after it compacts
    the conversation. This script prints your rules file to stdout, and Claude
    Code injects that stdout straight into the model's context.

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

if (-not (Test-Path -LiteralPath $RulesFile)) {
    # Fail quietly: a hook that errors on every compaction is worse than one
    # that says nothing. Claude Code treats non-zero exits as hook failures.
    Write-Output "Context was compacted, but the rules file was not found at: $RulesFile"
    exit 0
}

$contenu = Get-Content -Raw -Encoding UTF8 -LiteralPath $RulesFile

Write-Output "Context was just compacted. Your standing rules are restored below - they apply to everything that follows."
Write-Output ""
Write-Output $contenu
exit 0
