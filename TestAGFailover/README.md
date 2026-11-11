# TestAGFailover: running FailoverTesting.ps1

[FailoverTesting.ps1](FailoverTesting.ps1) moves the primary role of the existing `AG_2025_Test` availability group between two SQL Server replicas, prints diagnostics, and records a transcript.

**Running this script changes the AG.** It takes the current primary offline and performs a forced failover with confirmation suppressed. There is no script-level dry run or approval prompt before these changes. Use it for the intended test environment during an agreed interruption window.

## Environment and prerequisites

The script assumes an existing two-replica, read-scale AG with `CLUSTER_TYPE = NONE`. It does not create or validate that configuration. Microsoft's [read-scale AG guidance](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/configure-read-scale-availability-groups?view=sql-server-ver17) describes the manual role-change procedure used here.

Confirm these items with the environment owner before running:

- Both SQL instances are reachable directly from your machine. Use instance names, not a listener that follows the primary.
- The intended target is a healthy, synchronous-commit secondary. Check every database in the AG; the script's synchronization gate checks only `AGTest1`.
- `AG_2025_Test` contains `AGTest1`, and `AGTest1.dbo.Customer` exists on both replicas.
- The secondary permits the script's read query using its normal connection. The script does not specify read-only application intent.
- One credential works on both replicas and has permission to query AG/DMV state, read `dbo.Customer`, alter the AG, fail over, resume data movement, and read SQL Server error logs. Have the DBA provision the required access.
- Your local account can create and write the `Logs` directory beside the script.
- Backups and an environment-specific recovery procedure are available.

Names fixed in the script:

| Setting | Value |
| --- | --- |
| Availability group | `AG_2025_Test` |
| Database checked and resumed | `AGTest1` |
| Sample query | `dbo.Customer WHERE FirstName = 'Sebastian'` |
| Synchronization wait | 60 seconds, polled every 5 seconds |

[Customer.sql](Customer.sql) defines the sample table only. It does not select a database or insert sample rows. If setup is needed, have the owner run it in `AGTest1` on the current primary before testing. An empty sample-query result does not fail the script.

## Prepare PowerShell

Use your team's approved PowerShell and dbatools versions. This repository does not pin or establish a tested version pair.

From PowerShell, install dbatools if it is missing, following the [dbatools getting-started guide](https://dbatools.io/getting-started/):

```powershell
# One-time setup, if dbatools is not installed.
Install-Module -Name dbatools -Scope CurrentUser

# Run in the session used for the test.
Import-Module dbatools -ErrorAction Stop
Get-Module dbatools | Select-Object Name, Version
Get-Command Invoke-DbaQuery, Get-DbaAvailabilityGroup, Get-DbaAgReplica,
    Get-DbaAgDatabase, Invoke-DbaAgFailover, Resume-DbaAgDbDataMovement,
    Get-DbaErrorLog -ErrorAction Stop
```

Resolve module, execution-policy, connectivity, and certificate errors before the test. Follow your organization's script-signing and trust policies.

## Run the test

1. Confirm which replica currently owns the primary role. The example assumes `TestSQL2025_1` is primary and `TestSQL2025_2` is secondary.
2. Open PowerShell and change to the folder containing the script. Replace the example local path as needed.
3. Run:

```powershell
Set-Location 'C:\GitRepo\AIEssentialsForDataProfessionals\TestAGFailover'
.\FailoverTesting.ps1 -CurrentPrimary 'TestSQL2025_1' -NewPrimary 'TestSQL2025_2'
```

4. Enter the approved credential at the `Get-Credential` prompt. The script reuses it for both replicas; do not put passwords in the command or README.
5. Watch the output through completion, then review the final AG state and transcript.

| Required parameter | Meaning |
| --- | --- |
| `-CurrentPrimary` | Instance that is primary before the run; becomes secondary. |
| `-NewPrimary` | Instance that is secondary before the run; becomes primary. |

Use the exact replica server name for `NewPrimary`: the synchronization query compares your value to `sys.availability_replicas.replica_server_name`. An alias that connects successfully can still fail this comparison. The script prints `@@SERVERNAME` for each connection but does not enforce a name match.

The script prompts for credentials before starting the transcript. It stops before its AG-changing steps if the supplied instances do not report PRIMARY and SECONDARY respectively.

## What happens during the run

1. Connects to both instances, prints their server names, and checks their local roles.
2. Displays AG, replica, and database state, then queries the sample customer data on both replicas.
3. Sets `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1` on the current primary.
4. Waits for the target's `AGTest1` database to report `SYNCHRONIZED`.
5. Takes the AG offline on the current primary.
6. Promotes the target using `Invoke-DbaAgFailover -Force -Confirm:$false`.
7. Sets the old primary's role to SECONDARY and resumes data movement for `AGTest1` there.
8. Prints the final state of both replicas.

The [dbatools failover reference](https://dbatools.io/Invoke-DbaAgFailover/) documents that `-Force` allows potential data loss. Do not treat the script as a guarantee of no data loss: it checks synchronization for only one database and does not validate all configuration prerequisites.

**Persistent change:** the script does not restore the previous commit requirement. Requiring one synchronized secondary can prevent writes from committing when that requirement cannot be met. Have the environment owner verify the intended setting after the test, including after a failed run.

## Verify completion

Review the final output and confirm:

- `NewPrimary` reports PRIMARY and the old primary reports SECONDARY.
- Replicas are connected, data movement is not suspended, and databases return to the expected synchronized, healthy state.
- Application connectivity and required reads/writes work against the new primary.

The script displays final state but does not assert that the old primary has finished synchronizing. It does not rerun the customer query after failover, compare data, redirect application connections, or perform application validation. A completed transcript alone is not proof that the full test passed.

## Fail back

After verifying that the old primary is healthy and synchronized as a secondary, reverse the parameters:

```powershell
.\FailoverTesting.ps1 -CurrentPrimary 'TestSQL2025_2' -NewPrimary 'TestSQL2025_1'
```

This performs another complete failover and interruption. Failback is not automatic.

## Logs and troubleshooting

Transcripts are written beside the script as:

```text
Logs/FailoverTesting_yyyyMMdd_HHmmss.log
```

Protect these files appropriately: they contain instance names, query results, operational state, and potentially SQL Server error-log details.

| Symptom | Action |
| --- | --- |
| Replica-role mismatch | Inspect actual roles. Reverse parameters only if intentionally failing back. |
| Synchronization timeout | Check the exact target replica name, synchronization health, suspended movement, and connectivity. The commit requirement has already been changed at this point. |
| Sample-query failure | Check database/table existence, SELECT permissions, and secondary readability before retrying. |
| Login, connection, or certificate error | Resolve access or trust with the environment owner; do not bypass validation as a routine fix. |
| Failure after the AG is taken offline | Stop and inspect both replicas with the DBA. The AG may remain offline or partially transitioned. Do not blindly rerun or reverse parameters. |

Failures inside the six numbered change steps print a `FAILED` message, attempt to display both replicas' AG state, and attempt to retrieve the last 30 entries from each current SQL Server error log. Earlier checks and final reporting do not use that diagnostic wrapper. Diagnostic queries can also fail.

**There is no automatic rollback or cleanup of AG settings.** Preserve the transcript, identify the last successful step, and use the environment's recovery procedure. The script attempts to close the transcript in its final cleanup block.

---
Updated using GPT-6 (Codex) on 2026-11-05.

