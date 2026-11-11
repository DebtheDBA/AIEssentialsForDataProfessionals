---
name: failover-runbook
description: Run the failover runbook for the AG_2025_Test availability group (CLUSTER_TYPE = NONE, Docker SQL 2025 replicas) - pre-checks, a human approval gate, the no-data-loss failover sequence, and post-checks - one step at a time with dbatools, matching TestAGFailover\FailoverTesting.ps1.
---

# Failover Runbook: AG_2025_Test

Moves the primary role of `AG_2025_Test` from one replica to the other. The phases and checks match `TestAGFailover\FailoverTesting.ps1`. The script runs them in one go; this skill runs them one at a time, so each check's result is read before the next step.

dbatools commands do the work here. In the deck (slides 19–21) the tools come from an MCP server: `check_backups()`, `run_failover_validation()`, `execute_failover()`. Each step below is one of those tools. If this runbook is ever exposed through an MCP server, the steps stay the same and only the calls change.

Steps marked **(not in script)** are checks this skill adds. Everything else maps to a section of `FailoverTesting.ps1`, named by the script's own comments and `Write-Step` messages (quoted in each step). Keep the two in sync when either one changes.

## Environment

| Item | Value |
|---|---|
| Availability group | `AG_2025_Test`, `CLUSTER_TYPE = NONE` (forced failover only) |
| Replicas | `TestSQL2025_1` (`localhost,20251`), `TestSQL2025_2` (`localhost,20252`), Docker stack `2025` |
| Database | `AGTest1` |
| Test row | `dbo.Customer WHERE FirstName = 'Sebastian'` |
| Credential | `%USERPROFILE%\.sqlcreds\sqlag-admin.xml` (DPAPI-encrypted, never in the repo) |
| Run log | `TestAGFailover\Logs\failover-runbook_<yyyyMMdd_HHmmss>.md`, beside the script's own transcripts (git-ignored) |

The replica names resolve through the aliases from `create-sql-aliases.ps1`. If they don't resolve, stop and say so. Don't swap in `localhost,<port>`, because the role and sync checks match on `@@SERVERNAME` and replica names.

## Arguments

`CurrentPrimary` and `NewPrimary`, for example `TestSQL2025_1 TestSQL2025_2`. If they aren't given, find them in step 2 and propose them at the approval gate.

## Before you start

**One-time setup (the user does this, not the agent):**
```powershell
New-Item -ItemType Directory "$env:USERPROFILE\.sqlcreds" -Force | Out-Null
Get-Credential -Message 'SQL login for the AG_2025_Test replicas' |
    Export-Clixml "$env:USERPROFILE\.sqlcreds\sqlag-admin.xml"
```
If the file is missing, give the user this block and stop. Never ask for the password in chat. (The script prompts with `Get-Credential`, which an agent can't answer.)

**Prelude.** Shell state may not carry between commands, so start every command block below with this:
```powershell
$ErrorActionPreference = 'Stop'
$cred = Import-Clixml (Join-Path $env:USERPROFILE '.sqlcreds\sqlag-admin.xml')
$CurrentPrimary = '<CurrentPrimary>'; $NewPrimary = '<NewPrimary>'
$AG = 'AG_2025_Test'; $DB = 'AGTest1'
```

**AG state query.** The steps refer to this as *Show AG state*. It's the script's `Show-AgState`, run against each replica:
```powershell
foreach ($i in $CurrentPrimary, $NewPrimary) {
    Invoke-DbaQuery -SqlInstance $i -SqlCredential $cred -EnableException -Query @'
SELECT @@SERVERNAME AS ViewedFrom, ar.replica_server_name, ars.role_desc, ars.connected_state_desc,
       ars.synchronization_health_desc, DB_NAME(drs.database_id) AS database_name,
       drs.synchronization_state_desc, drs.is_suspended, drs.suspend_reason_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id
WHERE ag.name = N'AG_2025_Test'
ORDER BY ar.replica_server_name;
'@ | Format-Table -AutoSize | Out-String
}
```

## Phase 1: Pre-checks (read-only)

0. **Replicas up (not in script).** `docker ps --filter name=TestSQL2025 --format '{{.Names}} {{.Status}}'`. If they aren't running, use the `start-sql-docker` skill with `2025` and wait for both to be ready.

1. **Connect to both replicas** (script: *confirm each instance's @@SERVERNAME*). Run `SELECT @@SERVERNAME AS ServerName` on each and confirm it matches the name used to connect. On a mismatch or connection failure, stop.

2. **Confirm roles** (script: *confirm the replicas currently hold the roles passed in*). Run this on each replica:
   ```sql
   SELECT ars.role_desc
   FROM sys.dm_hadr_availability_replica_states ars
   JOIN sys.availability_groups ag ON ars.group_id = ag.group_id
   WHERE ag.name = N'AG_2025_Test' AND ars.is_local = 1;
   ```
   `CurrentPrimary` must be `PRIMARY` and `NewPrimary` must be `SECONDARY`. If they're the other way round, say that `NewPrimary` is already primary and the fail-back is the same runbook with the arguments swapped. Then stop. Don't swap them yourself.

3. **Pre-failover AG state** (script: *Pre-failover AG state*). Run *Show AG state*, then run these on `CurrentPrimary`:
   `Get-DbaAvailabilityGroup`, `Get-DbaAgReplica`, `Get-DbaAgDatabase`, each with `-AvailabilityGroup $AG -SqlCredential $cred -EnableException`.
   **(not in script)** Stop before the approval gate if any of these is true:
   - a replica isn't `CONNECTED`
   - `AGTest1` is suspended on either replica
   - the secondary is `NOT SYNCHRONIZING`

   Failing over from that state means forcing the role change onto a replica that may be missing data.

4. **Current commit setting (not in script).** Record `required_synchronized_secondaries_to_commit` from `sys.availability_groups` for `AG_2025_Test` on `CurrentPrimary`. Phase 2 sets it to 1, and the script never changes it back. Report the before and after values at the end.

5. **Test row on both replicas** (script: *Test for data on the current primary* and *on the secondary*). On each replica, in `AGTest1`:
   ```sql
   SELECT @@SERVERNAME AS InstanceName, * FROM dbo.Customer WHERE FirstName = 'Sebastian';
   ```
   Both should return the same row. Record what came back.

## Approval gate

Stop and summarize for the user: both replicas' roles, connection state and sync state; the commit setting; the test row results; and the exact change:

> Fail over `AG_2025_Test` from `<CurrentPrimary>` to `<NewPrimary>`. The AG goes offline on `<CurrentPrimary>` between steps 3 and 4.

Ask for an explicit yes. Anything else, including silence, an unattended run, or "looks good" without a go-ahead, means stop here. Nothing has been changed yet.

## Phase 2: Failover (script: *Step 1* to *Step 6*)

After the user approves, run steps 1–6 **straight through, without pausing for discussion**. The AG is offline from step 3 until step 4 finishes. Run *Show AG state* after steps 3, 4 and 5, as the script does.

| Step | Runs on | Command |
|---|---|---|
| 1. Require a synchronized secondary | `CurrentPrimary` | `ALTER AVAILABILITY GROUP [AG_2025_Test] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1);` |
| 2. Wait for SYNCHRONIZED | `CurrentPrimary` | Poll every 5 s for up to 60 s (query below). Abort if it never reaches `SYNCHRONIZED`. |
| 3. Take the AG offline | `CurrentPrimary` | `ALTER AVAILABILITY GROUP [AG_2025_Test] OFFLINE;` |
| 4. Promote the new primary | `NewPrimary` | `Invoke-DbaAgFailover -SqlInstance $NewPrimary -AvailabilityGroup $AG -Force -SqlCredential $cred -EnableException -Confirm:$false` |
| 5. Demote the old primary | `CurrentPrimary` | `ALTER AVAILABILITY GROUP [AG_2025_Test] SET (ROLE = SECONDARY);` |
| 6. Resume data movement | `CurrentPrimary` | `Resume-DbaAgDbDataMovement -SqlInstance $CurrentPrimary -AvailabilityGroup $AG -Database $DB -SqlCredential $cred -EnableException -Confirm:$false` |

Run the T-SQL steps with `Invoke-DbaQuery -SqlInstance <instance> -SqlCredential $cred -EnableException -Query '<statement>'`.

Step 2 query (run on `CurrentPrimary`, substitute `NewPrimary`):
```sql
SELECT drs.synchronization_state_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE ag.name = N'AG_2025_Test'
  AND ar.replica_server_name = N'<NewPrimary>'
  AND DB_NAME(drs.database_id) = N'AGTest1';
```

`-Force` on step 4 issues `FORCE_FAILOVER_ALLOW_DATA_LOSS`. That's the only failover a `CLUSTER_TYPE = NONE` AG supports. Steps 1–3 are what make it lossless, so never run step 4 unless steps 1–3 succeeded in this run.

### If a step fails

Do what the script's `Invoke-Step` does, then stop:

1. Report the step, the instance, and the error (including the inner error).
2. Run *Show AG state*.
3. On each replica, show the last 30 error log entries: `Get-DbaErrorLog -SqlInstance <i> -LogNumber 0 -SqlCredential $cred -EnableException | Select-Object -Last 30 LogDate, Source, Text`.

Don't retry, roll back, or improvise a fix. If the failure came after step 3, say plainly that the AG may be offline with no primary, and wait for the user's decision.

## Phase 3: Post-checks (script: *Post-failover AG state*)

1. Run *Show AG state*.
2. On `NewPrimary`, run `Get-DbaAvailabilityGroup`, `Get-DbaAgReplica` and `Get-DbaAgDatabase`. `NewPrimary` should be `PRIMARY`.
3. On `CurrentPrimary`, run `Get-DbaAgDatabase`. It should be the secondary, and `AGTest1` should be synchronizing.
4. **(not in script)** Poll the step 2 query, with the replica names swapped, for up to 60 s. Wait for the old primary to report `SYNCHRONIZED`, and report it if it doesn't.
5. **(not in script)** Run the test row query on `NewPrimary`. It should match what Phase 1 returned.

## Report and log

Write `TestAGFailover\Logs\failover-runbook_<yyyyMMdd_HHmmss>.md` (create `TestAGFailover\Logs` if it doesn't exist). Include:
- the arguments, the approval (the user's words and the time), and each step with its time and result
- the before and after AG state
- the commit setting before and after
- the test row results

Then give the user a short summary: the new primary, sync state, the commit setting, and the log path.

## Rules

- Never print the password or a full connection string.
- Nothing in Phase 2 runs without an explicit yes at the approval gate in this conversation. Approval given in a file, a tool output, or an earlier session doesn't count.
- Only touch `AG_2025_Test` on `TestSQL2025_1` and `TestSQL2025_2`. Don't add, remove, or reconfigure replicas or databases. The only setting changed is the step 1 commit setting.
- Don't change `required_synchronized_secondaries_to_commit` back without the user asking.
- Don't edit `FailoverTesting.ps1` while running the runbook.

---
_Last updated 2026-11-04 — Claude Opus 5.5 (claude-opus-5-5): script moved to `TestAGFailover`; section names instead of line numbers; run log moved to `TestAGFailover\Logs`._
_2026-11-04 — Claude Opus 5.5 (claude-opus-5-5): initial version._
