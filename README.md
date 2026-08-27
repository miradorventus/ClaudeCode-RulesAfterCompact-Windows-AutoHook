# AutoHook - Claude Code compact hook for Windows

**Claude Code forgets your rules after it compacts the conversation.** This puts
them back — on Windows, where the usual fix quietly corrupts every accented
character before Claude ever reads it.

## Install

Nothing to download. Copy the block below and paste it into Claude Code - the
copy button is at its top right corner. Claude writes the files itself.

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

Then nothing happens, until the next compaction. When Claude Code compacts the
conversation the hook fires and your rules land back in context. Ask Claude what
your standing rules are, right after a compaction, and you will know it worked.

## Why a prompt instead of an installer

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

## The trap this exists for

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

## What it costs

The hook injects the **whole** rules file, every time the conversation is
compacted. That is a recurring token cost, so keep the file short: a page of
standing rules is the right size, a 76 KB architecture document is not.

If your rules file is large, point the hook at a short summary instead and let
Claude read the full document on demand:

```
-RulesFile "C:\Users\YOU\.claude\RULES-SHORT.md"
```

The upstream Bash project takes the other approach - it injects a one-line
reminder telling Claude to re-read the file. That is cheaper per compaction but
depends on Claude actually performing the read. Injecting the content is more
reliable and costs more. Pick per file size.

## Read it before you run it

You should not paste a prompt that writes a script onto your machine without
knowing what the script does. It is twenty lines, and both pieces are here:

- [hooks/post-compact-reminder.ps1](hooks/post-compact-reminder.ps1) - the hook
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

## Uninstall

Paste this instead:

```
Remove the AutoHook post-compaction hook from this machine: delete the
"SessionStart" entry whose matcher is "compact" and whose command points at
post-compact-reminder.ps1 from %USERPROFILE%\.claude\settings.json, keep the rest
of the file intact, then delete %USERPROFILE%\.claude\hooks\post-compact-reminder.ps1.
```

## Notes for anyone writing Claude Code hooks on Windows

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

## Tested on

- Windows 11 Pro 26100, Windows PowerShell 5.1.26100
- Claude Code, `SessionStart` hook with `matcher: "compact"`, verified end to end
  by compacting a real session and observing the injection arrive
- Smart App Control enforcing; PowerShell 7 not tested

Everything in this README was measured on that machine. Nothing is inferred.

## Prior art

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

## License

MIT — see [LICENSE](LICENSE).
