<#
.SYNOPSIS
    Claude Code PreToolUse hook: blocks destructive SQL and credential reads, asks before
    high-impact changes, and logs every call it checks.

.DESCRIPTION
    Claude Code sends the pending tool call to this script as JSON on stdin, before the tool runs.
    The script checks the command text against the rules below and answers with one of:

      deny   Exit 2 with the reason on stderr. The call never runs, and Claude sees the reason.
      ask    JSON with permissionDecision "ask" on stdout, exit 0. You get a prompt even if the
             tool is already approved or prompts are turned off.
      allow  No output, exit 0. The normal permission rules apply.

    Deny rules are checked before ask rules. The first match wins.

    For PowerShell/Bash commands that run a .sql file (-File, -InputFile, -i), the file's
    contents are checked too.

    This is pattern matching, not a T-SQL parser. It catches an agent's honest mistakes; it does
    not stop someone determined to get around it. The real control is the login's permissions.
    The hook is the layer in front of that.

.NOTES
    Wired up in .claude/settings.json. Test it with .claude/hooks/Test-SqlGuard.ps1.
    Log: .claude/hooks/logs/sql-guard.log (one JSON object per line; passwords redacted).
#>
$ErrorActionPreference = 'Stop'

$rules = @(
    [pscustomobject]@{ Decision = 'deny'; Name = 'Read .env.dab'
        Pattern = '(?i)\.env\.dab\b'
        Reason  = '.env.dab holds SQL credentials. Load it inside a script (DataAPIBuilder\DabSettings.ps1); never display or read it directly.' },
    [pscustomobject]@{ Decision = 'deny'; Name = 'DROP'
        Pattern = '(?i)\bDROP\s+(DATABASE|TABLE|LOGIN|USER|SCHEMA|AVAILABILITY\s+GROUP|EVENT\s+SESSION)\b'
        Reason  = 'Dropping databases, tables, logins, users, schemas, AGs or XE sessions is not allowed from an AI session. A human runs it through change control.' },
    [pscustomobject]@{ Decision = 'deny'; Name = 'TRUNCATE'
        Pattern = '(?i)\bTRUNCATE\s+TABLE\b'
        Reason  = 'TRUNCATE TABLE removes every row. A human runs it through change control.' },
    [pscustomobject]@{ Decision = 'deny'; Name = 'DELETE without WHERE'
        Pattern = '(?is)\bDELETE\s+(?:TOP\s*\(\s*\d+\s*\)\s+)?FROM\s+[\w.\[\]#@]+(?!(?:[^;''"]|'''')*\bWHERE\b)'
        Reason  = 'DELETE with no WHERE clause removes every row. Add a WHERE clause or have a human run it.' },
    [pscustomobject]@{ Decision = 'deny'; Name = 'UPDATE without WHERE'
        Pattern = '(?is)\bUPDATE\s+(?:TOP\s*\(\s*\d+\s*\)\s+)?[\w.\[\]#@]+\s+SET\b(?!(?:[^;''"]|'''')*\bWHERE\b)'
        Reason  = 'UPDATE with no WHERE clause changes every row. Add a WHERE clause or have a human run it.' },
    [pscustomobject]@{ Decision = 'deny'; Name = 'Permission change'
        Pattern = '(?i)\bGRANT\s+(SELECT|INSERT|UPDATE|DELETE|EXEC|EXECUTE|ALTER|CONTROL|CREATE|IMPERSONATE|VIEW|CONNECT)\b|\bALTER\s+(SERVER\s+)?ROLE\b[^;''"]*\bADD\s+MEMBER\b|\bsp_add(srv)?rolemember\b'
        Reason  = 'Granting permissions or adding role members is not allowed from an AI session. Least privilege for dab_user is the point; a human makes permission changes.' },
    [pscustomobject]@{ Decision = 'deny'; Name = 'xp_cmdshell'
        Pattern = '(?i)\bxp_cmdshell\b'
        Reason  = 'xp_cmdshell runs OS commands as the SQL Server service account. Not allowed from an AI session.' },
    [pscustomobject]@{ Decision = 'deny'; Name = 'Docker data loss'
        Pattern = '(?i)\bdocker(-compose|\s+compose)\b[^;|&]*\bdown\b[^;|&]*(\s-v\b|--volumes\b)|\bdocker\s+(volume\s+(rm|prune)|system\s+prune)\b'
        Reason  = 'This removes Docker volumes, which hold the SQL Server databases. A human runs it.' },
    [pscustomobject]@{ Decision = 'ask'; Name = 'AG change'
        Pattern = '(?i)\bALTER\s+AVAILABILITY\s+GROUP\b|\bInvoke-DbaAgFailover\b'
        Reason  = 'This changes availability group state (failover, offline, role, settings). Confirm it is the runbook step you expect.' },
    [pscustomobject]@{ Decision = 'ask'; Name = 'SHUTDOWN'
        Pattern = '(?i)\bSHUTDOWN\b'
        Reason  = 'This shuts down SQL Server. Confirm before it runs.' },
    [pscustomobject]@{ Decision = 'ask'; Name = 'Restore or remove database'
        Pattern = '(?i)\bRESTORE\s+DATABASE\b|\b(Restore|Remove)-DbaDatabase\b'
        Reason  = 'This restores over or removes a database. Confirm before it runs.' },
    [pscustomobject]@{ Decision = 'ask'; Name = 'Database state change'
        Pattern = '(?i)\bALTER\s+DATABASE\b[^;''"]*\bSET\s+(SINGLE_USER|OFFLINE|EMERGENCY|READ_ONLY)\b'
        Reason  = 'This takes a database offline, single-user, emergency or read-only. Confirm before it runs.' }
)

$logFolder = Join-Path $PSScriptRoot 'logs'
$logFile   = Join-Path $logFolder 'sql-guard.log'

function Hide-Secrets([string]$Text) {
    $Text = $Text -replace '(?i)(password|pwd)\s*=\s*[^;''"\s]+', '$1=***'
    $Text = $Text -replace '(?i)(\s-P\s+)\S+', '$1***'
    return $Text
}

function Write-GuardLog([string]$Tool, [string]$Decision, [string]$Rule, [string]$Text) {
    try {
        New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
        $short = Hide-Secrets $Text
        if ($short.Length -gt 400) { $short = $short.Substring(0, 400) + '...' }
        $entry = [ordered]@{
            time     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            tool     = $Tool
            decision = $Decision
            rule     = $Rule
            text     = $short
        } | ConvertTo-Json -Compress
        Add-Content -Path $logFile -Value $entry -Encoding UTF8
    } catch {
        # Logging must never change the decision.
    }
}

# Read stdin as raw UTF-8 bytes. Windows PowerShell otherwise decodes it with the OEM code page.
try {
    $stdin  = [Console]::OpenStandardInput()
    $buffer = New-Object IO.MemoryStream
    $stdin.CopyTo($buffer)
    $raw = [Text.Encoding]::UTF8.GetString($buffer.ToArray()).TrimStart([char]0xFEFF)
    $call = $raw | ConvertFrom-Json
} catch {
    # Fail closed: if the hook can't read the call, the call doesn't run.
    [Console]::Error.WriteLine("sql-guard hook could not read the tool call, so it was blocked: $($_.Exception.Message)")
    exit 2
}

$tool  = [string]$call.tool_name
$input_ = $call.tool_input

# What to check, by tool.
$text = ''
if ($tool -eq 'Read') {
    $text = [string]$input_.file_path
} elseif ($tool -eq 'Bash' -or $tool -eq 'PowerShell') {
    $text = [string]$input_.command
    # Include the contents of any .sql file the command runs, so a script file isn't a way around the rules.
    $cwd = [string]$call.cwd
    foreach ($m in [regex]::Matches($text, '(?i)(?:-File|-InputFile|\s-i)\s+[''"]?([^''"\s]+\.sql)')) {
        $path = $m.Groups[1].Value
        if ($cwd -and -not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $cwd $path }
        if (Test-Path -LiteralPath $path) {
            $text += "`n" + [IO.File]::ReadAllText($path)
        }
    }
} else {
    # MCP tools: check every argument.
    $text = $input_ | ConvertTo-Json -Depth 10 -Compress
}

if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }

foreach ($rule in $rules) {
    if ($text -match $rule.Pattern) {
        Write-GuardLog -Tool $tool -Decision $rule.Decision -Rule $rule.Name -Text $text
        if ($rule.Decision -eq 'deny') {
            [Console]::Error.WriteLine("Blocked by the sql-guard hook ($($rule.Name)): $($rule.Reason)")
            exit 2
        }
        $answer = @{
            hookSpecificOutput = @{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'ask'
                permissionDecisionReason = "sql-guard hook ($($rule.Name)): $($rule.Reason)"
            }
        } | ConvertTo-Json -Depth 5 -Compress
        [Console]::Out.Write($answer)
        exit 0
    }
}

Write-GuardLog -Tool $tool -Decision 'allow' -Rule '' -Text $text
exit 0
