# AutoHook - install by prompt

Copy everything in the block below and paste it into Claude Code. That's the
whole install. Claude writes the files itself, so nothing is ever downloaded
and no execution policy, Mark of the Web, or code signature is involved.

---

```
Install a post-compaction rules reminder hook for Claude Code on this Windows machine.

STEP 1 - Create %USERPROFILE%\.claude\hooks\post-compact-reminder.ps1 with exactly this content:

    param([string]$RulesFile = (Join-Path $env:USERPROFILE ".claude\CLAUDE.md"))

    # Required. Reading [Console]::OutputEncoding is NOT a valid check - it can
    # report utf-8 while the stream is still mangled. It must be ASSIGNED.
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new(0)

    if (-not (Test-Path -LiteralPath $RulesFile)) {
        Write-Output "Context was compacted, but no rules file was found at: $RulesFile"
        exit 0
    }

    Write-Output "Context was just compacted. Your standing rules are restored below - they apply to everything that follows."
    Write-Output ""
    Write-Output (Get-Content -Raw -Encoding UTF8 -LiteralPath $RulesFile)
    exit 0

Save it as pure ASCII with no BOM.

STEP 2 - Back up %USERPROFILE%\.claude\settings.json (copy it to settings.json.bak-autohook),
then add this entry. Merge carefully - do NOT overwrite anything:
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

Finally, tell me whether %USERPROFILE%\.claude\CLAUDE.md exists and its size in
KB, since its whole content is re-injected at every compaction. If it does not
exist, say so: the hook has nothing to inject until I create it.
```

---

## What you should see afterwards

Nothing, until the next compaction. When Claude Code compacts the conversation,
the hook fires and your rules land back in context. You can confirm it worked by
asking Claude, right after a compaction, what your standing rules are.

## Uninstall

Paste this instead:

```
Remove the AutoHook post-compaction hook from this machine: delete the
"SessionStart" entry whose matcher is "compact" and whose command points at
post-compact-reminder.ps1 from %USERPROFILE%\.claude\settings.json, keep the rest
of the file intact, then delete %USERPROFILE%\.claude\hooks\post-compact-reminder.ps1.
```
