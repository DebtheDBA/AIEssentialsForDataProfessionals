<#
.SYNOPSIS
    Tests the sql-guard hook by sending it sample tool calls, with no Claude Code and no SQL Server.

.DESCRIPTION
    Each case is sent to sql-guard.ps1 as JSON on stdin, the same way Claude Code sends it.
    The script reads the hook's answer (deny = exit 2, ask = JSON on stdout, allow = neither)
    and compares it with the expected decision. Nothing is run against SQL Server or Docker.

    Test entries are written to the hook's log like any other call; they show up with
    tool names like Bash and PowerShell. Clear .claude\hooks\logs before the demo if you want
    a clean log.

.EXAMPLE
    .\.claude\hooks\Test-SqlGuard.ps1
#>
$ErrorActionPreference = 'Stop'
$hook = Join-Path $PSScriptRoot 'sql-guard.ps1'

# A .sql file with a destructive statement, to check that -File contents are inspected.
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('sqlguard_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
Set-Content -Path (Join-Path $tempDir 'cleanup.sql') -Value 'DROP TABLE dbo.Customer;' -Encoding UTF8

$cases = @(
    @{ Expect = 'allow'; Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Database AGTest1 -Query 'SELECT TOP 10 * FROM dbo.Customer'" } }
    @{ Expect = 'allow'; Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Database AGTest1 -Query 'DELETE FROM dbo.Customer WHERE CustomerID = 1'" } }
    @{ Expect = 'allow'; Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Database AGTest1 -Query 'UPDATE dbo.Customer SET FirstName = ''Bash'' WHERE CustomerID = 1'" } }
    @{ Expect = 'allow'; Tool = 'PowerShell'; Input = @{ command = 'Get-DbaAgReplica -SqlInstance TestSQL2025_1 -AvailabilityGroup AG_2025_Test' } }
    @{ Expect = 'allow'; Tool = 'Bash';       Input = @{ command = 'docker compose -f docker-compose.2025.yml down' } }
    @{ Expect = 'allow'; Tool = 'Read';       Input = @{ file_path = 'C:\GitRepo\AIEssentialsForDataProfessionals\DataAPIBuilder\README.md' } }
    @{ Expect = 'allow'; Tool = 'mcp__genius-songlyrics__read_records'; Input = @{ entity = 'SongLyric'; select = 'ID,Title,Artist'; first = 1 } }

    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = 'Get-Content .\.env.dab' } }
    @{ Expect = 'deny';  Tool = 'Read';       Input = @{ file_path = 'C:\GitRepo\AIEssentialsForDataProfessionals\.env.dab' } }
    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Database AGTest1 -Query 'TRUNCATE TABLE dbo.Customer'" } }
    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Database AGTest1 -Query 'DELETE FROM dbo.Customer'" } }
    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Database AGTest1 -Query 'UPDATE dbo.Customer SET FirstName = ''Bash'''" } }
    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Query 'DROP DATABASE AGTest1'" } }
    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance 192.168.182.134 -Query 'GRANT ALTER ANY EVENT SESSION TO dab_user'" } }
    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance 192.168.182.134 -Query 'ALTER SERVER ROLE sysadmin ADD MEMBER dab_user'" } }
    @{ Expect = 'deny';  Tool = 'Bash';       Input = @{ command = 'docker compose -f docker-compose.2025.yml down -v' } }
    @{ Expect = 'deny';  Tool = 'PowerShell'; Input = @{ command = 'Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Database AGTest1 -File .\cleanup.sql' }; Cwd = $tempDir }

    @{ Expect = 'ask';   Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Query 'ALTER AVAILABILITY GROUP [AG_2025_Test] OFFLINE;'" } }
    @{ Expect = 'ask';   Tool = 'PowerShell'; Input = @{ command = 'Invoke-DbaAgFailover -SqlInstance TestSQL2025_2 -AvailabilityGroup AG_2025_Test -Force -Confirm:$false' } }
    @{ Expect = 'ask';   Tool = 'PowerShell'; Input = @{ command = "Invoke-DbaQuery -SqlInstance TestSQL2025_1 -Query 'RESTORE DATABASE AGTest1 FROM DISK = ''/var/opt/mssql/backup/AGTest1.bak'''" } }
)

function Invoke-Hook([hashtable]$Case) {
    $cwd = if ($Case.Cwd) { $Case.Cwd } else { (Get-Location).Path }
    $json = @{
        session_id      = 'test'
        cwd             = $cwd
        hook_event_name = 'PreToolUse'
        tool_name       = $Case.Tool
        tool_input      = $Case.Input
    } | ConvertTo-Json -Depth 5 -Compress

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$hook`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    $decision = 'allow'
    $detail = ''
    if ($p.ExitCode -eq 2) {
        $decision = 'deny'; $detail = $err.Trim()
    } elseif ($p.ExitCode -ne 0) {
        $decision = "error (exit $($p.ExitCode))"; $detail = $err.Trim()
    } elseif ($out.Trim()) {
        $answer = $out | ConvertFrom-Json
        $decision = $answer.hookSpecificOutput.permissionDecision
        $detail = $answer.hookSpecificOutput.permissionDecisionReason
    }
    [pscustomobject]@{ Decision = $decision; Detail = $detail }
}

try {
    $results = foreach ($case in $cases) {
        $r = Invoke-Hook $case
        $text = if ($case.Input.command) { $case.Input.command } elseif ($case.Input.file_path) { $case.Input.file_path } else { ($case.Input | ConvertTo-Json -Compress) }
        [pscustomobject]@{
            Result   = if ($r.Decision -eq $case.Expect) { 'PASS' } else { 'FAIL' }
            Expected = $case.Expect
            Got      = $r.Decision
            Tool     = $case.Tool
            Call     = if ($text.Length -gt 90) { $text.Substring(0, 90) + '...' } else { $text }
        }
    }
    $results | Format-Table -AutoSize -Wrap
    $failed = @($results | Where-Object Result -eq 'FAIL').Count
    if ($failed) { Write-Host "$failed of $($results.Count) cases failed." -ForegroundColor Red; exit 1 }
    Write-Host "All $($results.Count) cases passed." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
