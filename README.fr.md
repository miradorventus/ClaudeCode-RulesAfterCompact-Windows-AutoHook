# AutoHook

[🇬🇧 English version](README.md)

**Claude Code oublie vos règles à chaque compactage de la conversation. Ceci
les lui rend.** Pour Windows, où la solution évidente détruit en silence chaque
caractère accentué avant même que Claude le lise.

Il dit aussi à Claude où se trouve la transcription complète. Le compactage
garde un résumé, et un résumé perd des détails ; la transcription sur le disque,
non. Une valeur, un chemin ou une commande d'avant le compactage se relit au
lieu d'être reconstitué de mémoire.

Et parce que personne ne lit des mégaoctets de JSON en entier, il construit un
**fil de la conversation** : chacun de vos messages, en entier, avec l'endroit
où se trouve la réponse de Claude et ce qui a réellement été fait (fichiers
écrits, commits, push, avec leur résultat). Assez court pour être relu en entier
après chaque compactage. Fait pour le moment où Claude vous dit « tu ne me l'as
jamais demandé » alors que si.

## Installation

Copiez ceci et collez-le dans Claude Code. Rien à télécharger, rien à lancer.

Claude Code s'arrêtera pour demander votre permission, parce que les fichiers
à toucher sont hors de votre dossier de projet. C'est l'installation qui
fonctionne, pas qui échoue. Acceptez : un seul fichier est modifié,
`settings.json`, sauvegardé avant.

Vers la fin, il demande une seconde fois, à part : s'il peut ajouter deux règles
courtes à votre `CLAUDE.md`. Ce sont elles qui font que Claude se sert vraiment
du fil (relire avant d'affirmer un détail ; ne jamais tenir une action pour
faite sans trace). Facultatif, montré en entier avant d'écrire quoi que ce soit,
et sauvegardé aussi.

```
Installe sur cette machine Windows un hook Claude Code qui rappelle mes règles après chaque compactage.

ÉTAPE 1 - Crée %USERPROFILE%\.claude\hooks\post-compact-reminder.ps1 avec exactement ce contenu :

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

Enregistre-le en ASCII pur, sans BOM.

ÉTAPE 1b - Crée %USERPROFILE%\.claude\hooks\build-thread.ps1 avec exactement ce contenu,
lui aussi en ASCII pur, sans BOM. Il construit le fil de la conversation ; le hook
ci-dessus l'appelle, et fonctionne sans lui s'il manque.

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

ÉTAPE 2 - Modifie %USERPROFILE%\.claude\settings.json. C'est mon fichier de réglages
GLOBAL de Claude Code, hors de tout projet : dis-moi clairement que le hook se
déclenchera alors dans toutes les sessions Claude Code de cette machine, et demande
la permission en une fois, en nommant ce seul fichier.

Si le fichier existe, copie-le d'abord en settings.json.bak-autohook.
S'il N'existe PAS, crée-le, et crée aussi à côté un fichier témoin vide nommé
settings.json.absent-before-autohook, pour que la désinstallation sache qu'il
n'existait pas et puisse le supprimer proprement.

Ajoute ensuite cette entrée. Fusionne avec soin, n'écrase RIEN :
  - s'il n'y a pas d'objet "hooks", crée-le ;
  - si "hooks" existe sans "SessionStart", ajoute cette clé ;
  - si "SessionStart" existe déjà, AJOUTE cet objet à son tableau sans toucher
    aux entrées existantes. D'autres hooks avec d'autres matchers sont normaux ;
  - si une entrée de matcher "compact" pointant vers post-compact-reminder.ps1
    existe déjà, c'est une réinstallation : remplace cette seule entrée.
Garde tout le reste du fichier identique à l'octet près :

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

Remplace %USERPROFILE% par le vrai chemin absolu avant d'écrire : un chemin
relatif casse le hook. Vérifie que le fichier est toujours un JSON valide.

ÉTAPE 3 - Vérifie, puis montre-moi le résultat. Deux choses rendent un test naïf
inutile ici : mon fichier de règles peut être en ASCII pur, et ce bogue ne se
produit pas du tout quand la console est déjà en page de codes 65001. Le test
fournit donc ses propres caractères ET force une page de codes qui échoue.
Lance exactement ceci, rien d'autre :

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

Donne la liste d'octets telle quelle.

    RÉUSSI  C3 A9 C3 A8 E2 86 92      UTF-8 multi-octets, la correction fonctionne
    ÉCHEC   E9 E8   ou   82 8A        octets isolés, et la flèche a disparu

En cas d'ÉCHEC, il manque au script l'affectation de [Console]::OutputEncoding,
ou il a été enregistré avec un BOM. Arrête-toi et dis-le-moi : ne le fais pas
réussir en retirant le chcp, c'est lui qui donne son sens au test.

Vérifie ensuite le fil sur une vraie transcription : prends le fichier .jsonl
modifié le plus récemment sous %USERPROFILE%\.claude\projects, lance
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\build-thread.ps1" -Transcript "<ce fichier>"
et donne-moi le chemin affiché, la taille de ce fichier en caractères et sa
première entrée. Ne colle pas le fil entier.

ÉTAPE 4 - Deux règles font que Claude se sert vraiment du fil. Montre-les-moi
telles qu'elles sont ci-dessous, et demande-moi s'il faut les ajouter à
%USERPROFILE%\.claude\CLAUDE.md. C'est un second fichier hors du projet :
demande à part, ne l'inclus pas dans la permission de l'étape 2. Si je refuse,
passe à l'ÉTAPE 5.

Si j'accepte :
  - si CLAUDE.md existe, copie-le d'abord en CLAUDE.md.bak-autohook ; sinon,
    crée-le ;
  - s'il contient déjà des règles sur le même sujet (relire après un
    compactage, ou supposer qu'une action a été faite), n'ajoute pas de
    doublon : montre-moi les deux versions et demande laquelle garder ;
  - ajoute-les à la fin, sous des titres dans le style du fichier. S'il est
    écrit dans une autre langue, traduis-les fidèlement dans cette langue,
    sans les raccourcir ;
  - garde tout le contenu existant à l'octet près, et enregistre en UTF-8.

    ## Après un compactage, relire avant d'affirmer
    Après un compactage, un détail de la conversation (valeur, chemin,
    commande, résultat, décision) se relit avant d'être affirmé : d'abord le
    fil de la conversation (ce qui a été demandé, fait, décidé), en entier ou
    par mots-clés selon le hook, puis la transcription à la ligne indiquée.
    Chemins donnés par le hook. Le résumé en perd, la transcription non.

    ## Pas de trace, pas d'action acquise
    Une action ne se tient pour faite que si une trace l'atteste : fichier
    modifié, commit, résultat de commande. Sans trace, ne pas la supposer
    faite : me demander en une phrase si je l'ai faite moi-même.

ÉTAPE 5 - Dis-moi si %USERPROFILE%\.claude\CLAUDE.md existe et sa taille en
caractères, puisque tout son contenu est réinjecté à chaque compactage. Claude
Code limite la sortie d'un hook à 10 000 caractères, et le hook en ajoute 750 à
1 000 (en-tête, chemins de la transcription et du fil, consigne de lecture, selon
la longueur des chemins) : au-delà d'environ 9 000 caractères, le hook remplace
les règles par un avertissement. Si le fichier dépasse, dis-le clairement. S'il
n'existe pas, dis-le : le hook n'a rien à injecter tant que je ne l'ai pas créé.
```

C'est toute l'installation. Rien ne se voit avant le prochain compactage ; vos
règles reviennent alors d'elles-mêmes, suivies des chemins de la transcription et
du fil. Juste après un compactage, demandez à Claude quelles sont vos règles, et
ce que vous lui aviez demandé plus tôt dans la session : vous saurez que ça marche.

Les messages que le hook envoie à Claude sont en anglais ; Claude vous répond
dans votre langue, et le fil garde vos messages tels que vous les avez écrits.

---

<details>
<summary><b>Le fil de la conversation</b></summary>

La transcription garde tout, mais elle fait des mégaoctets de JSON : 7 Mo pour la
session où ce fil a été construit. Claude ne peut pas la lire en entier, alors il
y cherche, et une recherche trop étroite est exactement la façon dont une demande
se perd. C'est arrivé ici même : interrogé sur une mise à jour GitHub demandée une
heure plus tôt, Claude a répondu qu'on ne lui avait rien demandé.

Le fil est la couche intermédiaire, reconstruite à chaque compactage dans
`%USERPROFILE%\.claude\threads\<session>.md`. Une entrée par message :

```
## 36 - 2026-11-06 23:33 - line 1260 - reply: 1 text(s), lines 1274-1274
Non, je les ai déjà lancés.
Actions: none
```

- **Vos messages, en entier.** Les réponses de Claude ne sont pas recopiées, seulement
  localisées : `-Message 36` les affiche en entier quand un détail compte.
- **Les actions, avec leur résultat** : fichiers écrits, `git commit`, `git push`,
  commandes `gh` qui écrivent. Un échec renvoie à la ligne de l'appel et à celle de
  son résultat (`1227->1228`), et `-Line 1228` affiche l'erreur en clair.
- **Ce qu'il ne voit pas** : toute autre commande, et ce que vous avez fait vous-même.
  C'est pourquoi `none` ne prouve rien, et que la bonne réaction est de demander.

Jusqu'à 40 000 caractères, le fil se lit en entier ; au-delà, il se fouille par
plusieurs mots-clés, chaque message trouvé relu en entier avec ses voisins.

</details>

<details>
<summary><b>Désinstallation</b></summary>

Une commande PowerShell. Elle remet `settings.json` dans son état d'avant
(sauvegarde restaurée, ou fichier supprimé si l'installation l'avait créé) et
supprime les scripts.

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

La restauration ramène aussi tout ce que vous avez changé dans `settings.json`
depuis l'installation. Quelques minutes après, ce n'est rien ; des mois plus tard,
préférez le texte ci-dessous, à coller dans Claude Code :

```
Retire le hook AutoHook de cette machine : supprime de
%USERPROFILE%\.claude\settings.json l'entrée "SessionStart" de matcher "compact"
qui pointe vers post-compact-reminder.ps1, en gardant tout le reste à l'octet près.
Si c'était le seul contenu du fichier et qu'un témoin
settings.json.absent-before-autohook est présent, supprime les deux. Supprime
ensuite %USERPROFILE%\.claude\hooks\post-compact-reminder.ps1 et
%USERPROFILE%\.claude\hooks\build-thread.ps1. Enfin, si les deux règles
« Après un compactage, relire avant d'affirmer » et « Pas de trace, pas d'action
acquise » (ou leur traduction) sont dans %USERPROFILE%\.claude\CLAUDE.md,
montre-les-moi et demande s'il faut les retirer ; si oui, retire ces deux-là
seulement, le reste à l'octet près.
```

Les fils restent dans `%USERPROFILE%\.claude\threads` : ce sont des copies de vos
messages, supprimez ce dossier si vous ne voulez pas les garder.

</details>

<details>
<summary><b>Pourquoi un prompt, et pas un installeur</b></summary>

Parce qu'un installeur téléchargé ne s'exécute pas sur un Windows par défaut :

```
> powershell -File install.ps1
install.ps1 cannot be loaded. The file is not digitally signed.
You cannot run this script on the current system.                    exit 1
```

C'est `ExecutionPolicy = RemoteSigned`, la valeur d'usine, appliquée à tout
fichier marqué comme venant d'Internet, donc à tout ce qui vient de GitHub. Le
contourner demande un certificat de signature payant, ou d'apprendre aux gens à
désactiver leur propre sécurité. Avec un prompt, Claude écrit les fichiers sur
place, sans cette marque : il n'y a plus rien à contourner. Le `-ExecutionPolicy
Bypass` de la commande ne vaut que pour ce processus et ne change rien à la machine.

</details>

<details>
<summary><b>Le piège d'encodage à l'origine du projet</b></summary>

Claude Code injecte la sortie d'un hook directement dans le contexte du modèle.
Sous Windows, PowerShell réencode cette sortie dans la page de codes ANSI de la
console, puis Claude Code la décode en UTF-8. Tout ce qui n'est pas ASCII est
détruit, sans erreur ni trace dans les journaux.

```
page de codes   avec la correction        sans
cp1252          C3 A9 C3 A8 E2 86 92      E9 E8        flèche perdue
cp850           C3 A9 C3 A8 E2 86 92      82 8A        flèche perdue
cp65001         C3 A9 C3 A8 E2 86 92      C3 A9 C3 A8 E2 86 92
```

Sur une console déjà en UTF-8, le bogue n'apparaît pas : c'est pour ça qu'il est
invisible chez certains et destructeur chez d'autres. Et lire
`[Console]::OutputEncoding` ne prouve rien : la propriété annonce déjà UTF-8
pendant que la sortie est abîmée. Il faut l'**affecter** :

```powershell
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(0)   # 0 = sans BOM
```

</details>

<details>
<summary><b>Ce que ça coûte</b></summary>

Le hook injecte **tout** le fichier de règles à chaque compactage : gardez-le court,
une page de règles, pas un document d'architecture. Au-delà de la limite de
10 000 caractères de Claude Code, le hook le dit à Claude au lieu de laisser les
règles réduites en silence à un aperçu.

Le fil ne coûte que quand Claude le lit. Mesuré sur une session de 53 messages
et 7 Mo de transcription : 18 317 caractères, construits en 0,6 s, soit environ
4 500 tokens (estimation à 4 caractères par token, pas un comptage).

</details>

<details>
<summary><b>Testé sur</b></summary>

Windows 11 Pro 26100 et 26300, Windows PowerShell 5.1, Smart App Control actif ;
PowerShell 7 non testé. Vérifié de bout en bout sur une seconde machine par
quelqu'un qui ne connaissait pas le projet, à partir de cette page seule. Le fil a
été testé sur une vraie transcription de 7 Mo et lors d'un vrai `/compact`. Pas
encore exécutées de bout en bout sur une machine neuve : les nouvelles étapes 4 et 5
du prompt. Détails et notes techniques dans la [version anglaise](README.md).

</details>

<details>
<summary><b>Travaux existants</b></summary>

- **[Dicklesworthstone/post_compact_reminder](https://github.com/Dicklesworthstone/post_compact_reminder)**
  — l'original, d'où vient l'approche `SessionStart` + `matcher: "compact"`. En Bash,
  pour Linux, macOS et WSL : si vous êtes sur l'un d'eux, prenez-le.
- **[hagigi0405/claude-code-hooks-windows-traps](https://github.com/hagigi0405/claude-code-hooks-windows-traps)**
  — les pièges des hooks Windows côté **entrée** (stdin), sur un système japonais.
  Ce dépôt couvre le côté **sortie** (stdout).

Aucun code de l'un ou l'autre n'est repris ici.

</details>

---

MIT - voir [LICENSE](LICENSE).
