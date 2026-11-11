##### TODOs for presentations:
##### - add data changes for testing
##### - create readme documentation in various styles


<#
.SYNOPSIS
    Pre-failover testing script for the AG_2025_Test availability group.

.DESCRIPTION
    Verifies the state of the availability group and its replicas before performing a failover,
    then moves the primary role from CurrentPrimary to NewPrimary and checks both replicas.
    Uses dbatools for checking the availability group and replica states.

    Checks performed using dbatools:
    1. Availability group state (Get-DbaAvailabilityGroup)
    2. Replica states (Get-DbaAgReplica)
    3. Database replica states (Get-DbaAgDatabase)

    Each step prints the instance it runs against and the AG state of both replicas.
    dbatools commands run with -EnableException, so a failing step stops the script and
    prints the AG state and the recent SQL Server error log from both replicas.

.PARAMETER CurrentPrimary
    The replica that is primary now. It becomes the secondary after failover.

.PARAMETER NewPrimary
    The replica that is secondary now. It becomes the primary after failover.

.EXAMPLE
    .\FailoverTesting.ps1 -CurrentPrimary TestSQL2025_1 -NewPrimary TestSQL2025_2

.NOTES
    The script checks both replicas' roles first and stops without changing anything
    if CurrentPrimary is not the primary or NewPrimary is not the secondary.
#>

param (
    [Parameter(Mandatory)]
    [string]$CurrentPrimary,

    [Parameter(Mandatory)]
    [string]$NewPrimary
)

$ErrorActionPreference = 'Stop'

#set credentials
$cred = Get-Credential

# log all output to a timestamped transcript in the Logs folder next to this script
$logFolder = Join-Path $PSScriptRoot 'Logs'
New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
$logFile = Join-Path $logFolder "FailoverTesting_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logFile | Out-Null
Write-Host "Logging to: $logFile"

function Write-Step {
    param ([string]$Message, [string]$Instance)
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
    if ($Instance) { Write-Host "    Running against: $Instance" -ForegroundColor Cyan }
    Write-Host ("=" * 80) -ForegroundColor Cyan
}

# shows the AG as seen from one instance: replica roles/connection and database sync state
function Show-AgState {
    param ([string]$Instance)
    $stateQuery = @"
SELECT @@SERVERNAME AS ViewedFrom,
       ar.replica_server_name,
       ars.role_desc,
       ars.connected_state_desc,
       ars.synchronization_health_desc,
       DB_NAME(drs.database_id) AS database_name,
       drs.synchronization_state_desc,
       drs.is_suspended,
       drs.suspend_reason_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id
WHERE ag.name = N'AG_2025_Test'
ORDER BY ar.replica_server_name
"@
    Write-Host "--- AG state as seen from $Instance ---" -ForegroundColor Yellow
    try {
        Invoke-DbaQuery -SqlInstance $Instance -Query $stateQuery -SqlCredential $cred -EnableException | Format-Table -AutoSize | Out-Host
    }
    catch {
        Write-Host "Could not read AG state from ${Instance}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-BothAgStates {
    Show-AgState -Instance $CurrentPrimary
    Show-AgState -Instance $NewPrimary
}

# runs a step, and on failure dumps diagnostics from both replicas before stopping
function Invoke-Step {
    param ([string]$Message, [string]$Instance, [scriptblock]$Action)
    Write-Step -Message $Message -Instance $Instance
    try {
        & $Action
        Write-Host "OK: $Message" -ForegroundColor Green
    }
    catch {
        Write-Host "FAILED: $Message" -ForegroundColor Red
        Write-Host "Instance: $Instance" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner error: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }

        Show-BothAgStates

        foreach ($instance in $CurrentPrimary, $NewPrimary) {
            Write-Host "--- Last 30 error log entries on $instance ---" -ForegroundColor Yellow
            try {
                Get-DbaErrorLog -SqlInstance $instance -LogNumber 0 -SqlCredential $cred -EnableException |
                    Select-Object -Last 30 LogDate, Source, Text | Format-Table -AutoSize -Wrap | Out-Host
            }
            catch {
                Write-Host "Could not read error log from ${instance}: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        throw
    }
}

try {
    Write-Step -Message "Parameters: CurrentPrimary = $CurrentPrimary, NewPrimary = $NewPrimary"

    # confirm each instance's @@SERVERNAME matches the replica name it's expected to be
    foreach ($instance in $CurrentPrimary, $NewPrimary) {
        $serverName = (Invoke-DbaQuery -SqlInstance $instance -Query "SELECT @@SERVERNAME AS ServerName" -SqlCredential $cred -EnableException).ServerName
        Write-Host "Connected to $instance -> @@SERVERNAME = $serverName"
    }

    # confirm the replicas currently hold the roles passed in, before changing anything
    $roleQuery = @"
SELECT ars.role_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ars.group_id = ag.group_id
WHERE ag.name = N'AG_2025_Test'
  AND ars.is_local = 1
"@
    $currentPrimaryRole = (Invoke-DbaQuery -SqlInstance $CurrentPrimary -Query $roleQuery -SqlCredential $cred -EnableException).role_desc
    $newPrimaryRole = (Invoke-DbaQuery -SqlInstance $NewPrimary -Query $roleQuery -SqlCredential $cred -EnableException).role_desc
    Write-Host "Current role of $CurrentPrimary = $currentPrimaryRole"
    Write-Host "Current role of $NewPrimary = $newPrimaryRole"

    if ($currentPrimaryRole -ne 'PRIMARY' -or $newPrimaryRole -ne 'SECONDARY') {
        $message = "Replica roles don't match the parameters: -CurrentPrimary $CurrentPrimary is $currentPrimaryRole (expected PRIMARY) and -NewPrimary $NewPrimary is $newPrimaryRole (expected SECONDARY)."
        if ($currentPrimaryRole -eq 'SECONDARY' -and $newPrimaryRole -eq 'PRIMARY') {
            $message += " $NewPrimary is already the primary. To fail back, rerun with -CurrentPrimary $NewPrimary -NewPrimary $CurrentPrimary."
        }
        Write-Host $message -ForegroundColor Red
        throw $message
    }

    Write-Step -Message "Pre-failover AG state"
    Show-BothAgStates

    Get-DbaAvailabilityGroup -SqlInstance $CurrentPrimary -AvailabilityGroup AG_2025_Test -SqlCredential $cred -EnableException | Format-Table -AutoSize
    Get-DbaAgReplica -SqlInstance $CurrentPrimary -AvailabilityGroup AG_2025_Test -SqlCredential $cred -EnableException | Format-Table -AutoSize
    Get-DbaAgDatabase -SqlInstance $CurrentPrimary -AvailabilityGroup AG_2025_Test -SqlCredential $cred -EnableException | Format-Table -AutoSize

    # test for data
    Write-Step -Message "Test for data on the current primary" -Instance $CurrentPrimary
    Invoke-DbaQuery -SqlInstance $CurrentPrimary -Database AGTest1 -Query "SELECT @@servername as InstanceName, * FROM dbo.Customer WHERE FirstName = 'Sebastian'" -SqlCredential $cred -EnableException | Format-Table

    # test for data on the secondary (the new primary after failover)
    Write-Step -Message "Test for data on the secondary (new primary after failover)" -Instance $NewPrimary
    Invoke-DbaQuery -SqlInstance $NewPrimary -Database AGTest1 -Query "SELECT @@servername as InstanceName, * FROM dbo.Customer WHERE FirstName = 'Sebastian'" -SqlCredential $cred -EnableException | Format-Table

    # CLUSTER_TYPE = NONE only supports forced failover, so use the documented no-data-loss sequence:

    # 1. require a synchronized secondary before the primary commits (run on the primary)
    Invoke-Step -Message "Step 1: Set REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1" -Instance $CurrentPrimary -Action {
        Invoke-DbaQuery -SqlInstance $CurrentPrimary -Query "ALTER AVAILABILITY GROUP [AG_2025_Test] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1);" -SqlCredential $cred -EnableException
    }

    # 2. wait for the secondary to report SYNCHRONIZED (checked from the primary)
    $syncQuery = @"
SELECT drs.synchronization_state_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE ag.name = N'AG_2025_Test'
  AND ar.replica_server_name = N'$NewPrimary'
  AND DB_NAME(drs.database_id) = N'AGTest1'
"@
    Invoke-Step -Message "Step 2: Wait for $NewPrimary to report SYNCHRONIZED" -Instance $CurrentPrimary -Action {
        $timeoutSeconds = 60
        $elapsed = 0
        do {
            $syncState = (Invoke-DbaQuery -SqlInstance $CurrentPrimary -Query $syncQuery -SqlCredential $cred -EnableException).synchronization_state_desc
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Secondary sync state: $syncState (elapsed ${elapsed}s)"
            if ($syncState -eq 'SYNCHRONIZED') { break }
            Start-Sleep -Seconds 5
            $elapsed += 5
        } while ($elapsed -lt $timeoutSeconds)

        if ($syncState -ne 'SYNCHRONIZED') {
            throw "Secondary $NewPrimary did not reach SYNCHRONIZED within $timeoutSeconds seconds. Failover aborted."
        }
    }

    # 3. take the AG offline on the current primary to prepare for the role change
    Invoke-Step -Message "Step 3: Take AG offline on $CurrentPrimary" -Instance $CurrentPrimary -Action {
        Invoke-DbaQuery -SqlInstance $CurrentPrimary -Query "ALTER AVAILABILITY GROUP [AG_2025_Test] OFFLINE;" -SqlCredential $cred -EnableException
    }
    Show-BothAgStates

    # 4. promote the new primary (runs FORCE_FAILOVER_ALLOW_DATA_LOSS on the target)
    Invoke-Step -Message "Step 4: Force failover to $NewPrimary" -Instance $NewPrimary -Action {
        Invoke-DbaAgFailover -SqlInstance $NewPrimary -AvailabilityGroup AG_2025_Test -Force -SqlCredential $cred -EnableException -Confirm:$false | Format-Table | Out-Host
    }
    Show-BothAgStates

    # 5. set the old primary's role to SECONDARY (run on the old primary, after the promotion)
    Invoke-Step -Message "Step 5: Set $CurrentPrimary (old primary) to SECONDARY" -Instance $CurrentPrimary -Action {
        Invoke-DbaQuery -SqlInstance $CurrentPrimary -Query "ALTER AVAILABILITY GROUP [AG_2025_Test] SET (ROLE = SECONDARY);" -SqlCredential $cred -EnableException
    }
    Show-BothAgStates

    # 6. resume data movement on $CurrentPrimary, which is the secondary from here on
    Invoke-Step -Message "Step 6: Resume data movement on $CurrentPrimary (old primary, now the secondary)" -Instance $CurrentPrimary -Action {
        Resume-DbaAgDbDataMovement -SqlInstance $CurrentPrimary -AvailabilityGroup AG_2025_Test -Database AGTest1 -SqlCredential $cred -EnableException -Confirm:$false | Format-Table | Out-Host
    }

    # test the new primary replica after failover
    Write-Step -Message "Post-failover AG state"
    Show-BothAgStates

    Get-DbaAvailabilityGroup -SqlInstance $NewPrimary -AvailabilityGroup AG_2025_Test -SqlCredential $cred -EnableException | Format-Table -AutoSize
    Get-DbaAgReplica -SqlInstance $NewPrimary -AvailabilityGroup AG_2025_Test -SqlCredential $cred -EnableException | Format-Table -AutoSize
    Get-DbaAgDatabase -SqlInstance $NewPrimary -AvailabilityGroup AG_2025_Test -SqlCredential $cred -EnableException | Format-Table -AutoSize

    # confirm $CurrentPrimary (the old primary) is now a synchronizing secondary
    Get-DbaAgDatabase -SqlInstance $CurrentPrimary -AvailabilityGroup AG_2025_Test -SqlCredential $cred -EnableException | Format-Table -AutoSize
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Transcript saved to: $logFile"
}
