# The Affair of the Vanishing Primary
## A TestAGFailover mystery, in the manner of Agatha Christie

At a quarter past two, the primary was precisely where everyone expected it to be.

By half past, it was to have surrendered its position to the secondary. This had been arranged in advance, which made the matter respectable; it did not, Inspector Vale observed, make it harmless.

On the desk lay [FailoverTesting.ps1](FailoverTesting.ps1), a credential prompt, and a rather troubling instruction containing the word `Force`.

“Before we begin,” said the inspector, “we shall establish who is who.”

> **Operator's notice:** This is a runnable guide presented as a mystery. The script really changes the availability group. It takes the current primary offline and performs a forced failover without a confirmation prompt. Use the intended test environment and an agreed interruption window. There is no script-level dry run, automatic rollback, or automatic failback.

For the conventional reference, consult [README.md](README.md).

## Chapter I: The guests at the table

There were only two replicas in the inspector's notebook. Neither could plausibly claim to be the other, although an alias might muddy the evidence.

| Name in the case | Actual meaning |
| --- | --- |
| `CurrentPrimary` | The instance that must report PRIMARY before the run. |
| `NewPrimary` | The instance that must report SECONDARY before the run. |
| `AG_2025_Test` | The availability group, fixed in the script. |
| `AGTest1` | The database checked for synchronization and resumed afterward. |
| `dbo.Customer` | The sample table queried on both replicas. |
| Sebastian | The value sought in `FirstName`; his absence does not fail the test. |

“The names of the guests,” Vale remarked, “are evidence, not decoration.”

Use direct instance names rather than a listener that follows the primary. In particular, `NewPrimary` must match the replica name recorded in `sys.availability_replicas.replica_server_name`. The script prints `@@SERVERNAME` but does not enforce a match. An alias can connect successfully and still fail the synchronization lookup.

## Chapter II: In which the inspector refuses to proceed without facts

The arrangement was a two-replica, read-scale availability group with `CLUSTER_TYPE = NONE`. Such was the script's assumption; it did not investigate the truth of it.

Before running, confirm with the environment owner:

- The existing AG is `AG_2025_Test`, contains `AGTest1`, and both instances are reachable.
- The intended secondary is healthy and uses synchronous commit. Inspect every AG database: the script waits for synchronization of **only `AGTest1`**.
- `AGTest1.dbo.Customer` exists and can be queried on both replicas. The secondary must accept the script's ordinary read connection; no read-only application intent is supplied.
- One approved credential works on both replicas and has the necessary access for AG/DMV queries, sample-table reads, AG changes, failover, data-movement resume, and SQL error-log inspection.
- Your local account can create and write the `Logs` folder beside the script.
- Backups and an environment-specific recovery procedure are available.

[Customer.sql](Customer.sql) provides the table definition. It neither selects the database nor supplies Sebastian. If required, have the owner run it in `AGTest1` on the current primary before testing.

“A table with no Sebastian,” said Vale, “is not proof of a successful transfer. It is merely a table with no Sebastian.”

## Chapter III: The tools are laid out

There was nothing romantic about the next part. The inspector preferred it that way.

Use the team's approved PowerShell and dbatools versions; the repository specifies no tested version pair. The [dbatools getting-started guide](https://dbatools.io/getting-started/) provides installation guidance.

```powershell
# One-time installation, only if dbatools is missing.
Install-Module -Name dbatools -Scope CurrentUser

# Prepare the session used for the test.
Import-Module dbatools -ErrorAction Stop
Get-Module dbatools | Select-Object Name, Version
Get-Command Invoke-DbaQuery, Get-DbaAvailabilityGroup, Get-DbaAgReplica,
    Get-DbaAgDatabase, Invoke-DbaAgFailover, Resume-DbaAgDbDataMovement,
    Get-DbaErrorLog -ErrorAction Stop
```

Resolve module, execution-policy, certificate, and connection problems before proceeding. Follow the organization's signing and trust policies.

## Chapter IV: The invitation is accepted

For this example, `TestSQL2025_1` must currently be primary and `TestSQL2025_2` secondary. Confirm that fact before running. Change the local folder path if your copy resides elsewhere.

```powershell
Set-Location 'C:\GitRepo\AIEssentialsForDataProfessionals\TestAGFailover'
.\FailoverTesting.ps1 -CurrentPrimary 'TestSQL2025_1' -NewPrimary 'TestSQL2025_2'
```

Enter the approved credential when `Get-Credential` appears. It is reused for both replicas. Keep the password out of command lines and documentation.

The credential prompt occurs before transcript recording begins. The script then checks the local roles. If they disagree with the parameters, it stops before the AG-changing steps.

“If the secondary is already primary,” Vale said, “we do not improve matters by insisting upon our original theory.”

## Chapter V: Six movements before the revelation

First came the preliminary interviews: server names, roles, AG state, replica state, database state, and the customer query on both instances.

Then the machinery began.

1. **The condition is imposed.** On the current primary, the script sets `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1`.
2. **The clock is watched.** From that primary, it checks whether the target's `AGTest1` is `SYNCHRONIZED`, polling every five seconds for a nominal sixty-second wait. A timeout stops the run.
3. **The drawing room is closed.** The AG is taken offline on the current primary.
4. **The successor takes the chair.** The target is promoted with `Invoke-DbaAgFailover -Force -Confirm:$false`.
5. **The former host receives a new title.** The old primary is explicitly set to SECONDARY.
6. **Correspondence resumes.** Data movement for `AGTest1` is resumed on the old primary.

Finally, the script displays AG, replica, and database information for review.

Vale tapped the fourth line.

“That word must not be concealed by a pleasant narrative.”

**Forced failover permits potential data loss**, as documented in the [dbatools command reference](https://dbatools.io/Invoke-DbaAgFailover/). This script follows a sequence intended for the read-scale scenario described by [Microsoft](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/configure-read-scale-availability-groups?view=sql-server-ver17), but it does not validate every prerequisite or check synchronization of every AG database. It is not a guarantee of no data loss.

**A condition remains after the guests depart:** the script does not restore the previous commit requirement. Requiring one synchronized secondary can prevent writes from committing when that requirement cannot be satisfied. Have the environment owner verify the intended setting after success or failure.

## Chapter VI: The evidence must agree

The last command finished. Someone reached for the teapot.

“Not yet,” said the inspector.

Review the output and independently confirm:

- The intended new primary reports PRIMARY; the old primary reports SECONDARY.
- Replicas are connected, data movement is not suspended, and all databases return to their expected healthy, synchronized state.
- Application connections and required reads and writes work against the new primary.

The script prints final state but does not wait for the old primary to finish synchronizing. It does not compare customer data, repeat that query after failover, redirect application connections, or validate the application.

A transcript ending neatly is evidence that recording ended. It does not establish that the test passed.

## Chapter VII: An unexpected interruption

Every case had its inconvenient witness. Here, it was usually an exception.

| Evidence | Next action |
| --- | --- |
| Roles do not match | Inspect the actual roles; reverse parameters only for an intentional failback. |
| Synchronization times out | Check the exact target name, connectivity, synchronization health, and suspended movement. The commit setting has already changed. |
| Customer query fails | Check table/database existence, SELECT permission, and secondary readability. |
| Login or certificate failure | Resolve access or trust with the owner before retrying. |
| Failure after OFFLINE | Inspect both replicas with the DBA and follow the recovery procedure. The AG may be offline or partly transitioned. Do not blindly rerun. |

Within the six numbered change steps, a failure prints diagnostics and attempts to retrieve both replicas' AG state and the last thirty entries of each current SQL Server error log. Earlier checks and final reporting do not have that diagnostic wrapper. Even the diagnostic requests may fail.

**Nothing automatically reverses completed changes.** Preserve the evidence, identify the last successful step, and involve the environment owner.

The notebook is kept beside the script:

```text
Logs/FailoverTesting_yyyyMMdd_HHmmss.log
```

Protect transcripts: they can contain server names, customer-query results, operational details, and error-log information. The script attempts to close the transcript in its final cleanup block.

## Chapter VIII: The return journey

Only after the former primary is confirmed healthy and synchronized as a secondary may the roles be reversed:

```powershell
.\FailoverTesting.ps1 -CurrentPrimary 'TestSQL2025_2' -NewPrimary 'TestSQL2025_1'
```

This is another complete failover, with another interruption and the same checks and risks.

Inspector Vale closed his notebook.

“The mystery,” he said, “was never which server ought to be primary. It was whether anyone had troubled to ask which server actually was.”

---
Updated using GPT-6 (Codex) on 2026-11-05.

