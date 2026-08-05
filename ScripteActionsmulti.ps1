<#
.SYNOPSIS
    Reads a list of target VMs from a CSV file and runs a Nerdio Scripted Action against just
    those VMs, using the NerdioManagerPowerShell module.

.DESCRIPTION
    The Nerdio Scripted Actions API is scoped per host pool (subscription + resource group +
    host pool name), not by an arbitrary VM list - so this script groups your input file by
    host pool and fires one API call per group, restricted to the matched VM names within it.

    CSV INPUT FORMAT (vmlist.csv):
        VMName,SubscriptionId,ResourceGroup,HostPoolName
        avd-host-01,00000000-0000-0000-0000-000000000000,rg-avd-prod,hp-prod-pool1
        avd-host-02,00000000-0000-0000-0000-000000000000,rg-avd-prod,hp-prod-pool1
        avd-host-05,00000000-0000-0000-0000-000000000000,rg-avd-prod,hp-prod-pool2

    CMDLET CHAIN (confirmed via Get-Help against the installed module, not guessed):

        New-NmeScriptedActionOption          -Type "Action" -Id <scriptedActionId>
                v (array, -ScriptedActions)
        New-NmeRunScriptParams                -ActiveDirectoryId -ScriptedActions
                v (-Config)
        New-NmeBulkJobParamsBulkRunScript      -TaskParallelism -CountFailedTaskToStopWork
                                                -RestartVms -SessionHostsToProcessNames <- target VMs
                v (-BulkJobParams, alongside -Config above)
        New-NmeRunHostPoolScriptRestPayload    -Config -BulkJobParams
                v (-JobPayload)
        New-NmeRunHostPoolScriptRestRequest    -JobPayload [-FailurePolicy]
                v
        New-NmeHostPoolScriptTask              -SubscriptionId -ResourceGroup -HostPoolName
                                                -NmeRunHostPoolScriptRestRequest

    Note: Get-NmeSessionHost fetches ONE host by exact -Hostname, not a list - so each VM in
    the input file is looked up individually to confirm it exists before it's included in the
    -SessionHostsToProcessNames list sent to Nerdio.

    RESTART BEHAVIOUR - IMPORTANT: -RestartVms here is the module's OWN restart mechanism,
    separate from anything the target Windows Scripted Action script does internally (e.g. a
    scheduled shutdown.exe with an on-screen warning). If your scripted action already manages
    its own restart, leave -RestartVm off here (the default) to avoid two restarts colliding.
#>

param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [int]$ScriptedActionId,

    # This is the MODULE's restart mechanism (New-NmeBulkJobParamsBulkRunScript -RestartVms),
    # separate from any restart logic inside the scripted action itself. Leave off if the
    # scripted action already handles its own restart.
    [switch]$RestartVm,

    # 0 = no AD profile sent with the scripted action. Look up a real ID via Get-NmeAdConfig if
    # your scripted action needs one (e.g. domain-join actions).
    [int]$ActiveDirectoryId = 0,

    # How many hosts to run against simultaneously within a single host pool group.
    [int]$TaskParallelism = 5,

    # Abort the remaining hosts in a group after this many failures.
    [int]$CountFailedTaskToStopWork = 3,

    # Safety valve: preview what would run without actually calling the API.
    [switch]$WhatIfOnly
)

# ---- 1. Connect ----
# TLS 1.3 - this endpoint rejected the older Windows PowerShell default and needed this set
# explicitly before Connect-Nme would succeed.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls13
[Net.ServicePointManager]::SecurityProtocol

# Get these from Settings > Integrations > REST API in Nerdio Manager.
Connect-Nme `
    -NmeUri       $env:NME_URI `
    -TenantId     $env:NME_TENANT_ID `
    -ClientId     $env:NME_CLIENT_ID `
    -ClientSecret $env:NME_CLIENT_SECRET `
    -ApiScope     $env:NME_API_SCOPE

# ---- 2. Read the input file ----
if (-not (Test-Path $CsvPath)) {
    throw "Input file not found: $CsvPath"
}
$targets = @(Import-Csv -Path $CsvPath)
if (-not $targets) {
    throw "No rows found in $CsvPath - check it has a header row: VMName,SubscriptionId,ResourceGroup,HostPoolName"
}

Write-Host "Loaded $($targets.Count) target VM(s) from $CsvPath"

# ---- 3. Group by host pool, since the API is scoped that way ----
$groups = $targets | Group-Object -Property SubscriptionId, ResourceGroup, HostPoolName

foreach ($group in $groups) {
    $sample = $group.Group[0]
    $subId  = $sample.SubscriptionId
    $rg     = $sample.ResourceGroup
    $pool   = $sample.HostPoolName
    $wantedNames = @($group.Group.VMName)

    Write-Host ""
    Write-Host "=== Host pool: $pool (RG: $rg) - $($wantedNames.Count) target VM(s) ==="

    # ---- 4. Resolve each named VM directly ----
    $matched = @()
    $missing = @()
    foreach ($name in $wantedNames) {
        try {
            $null = Get-NmeSessionHost -SubscriptionId $subId -ResourceGroup $rg -HostPoolName $pool -Hostname $name -ErrorAction Stop
            $matched += $name
        }
        catch {
            $missing += $name
        }
    }

    if ($missing) {
        Write-Warning "Not found in '$pool': $($missing -join ', ')"
    }
    if (-not $matched) {
        Write-Warning "No matching hosts found in '$pool' - skipping this group."
        continue
    }

    Write-Host "Resolved $($matched.Count) host(s):"
    $matched | ForEach-Object { Write-Host "  $_" }

    if ($WhatIfOnly) {
        Write-Host "[-WhatIfOnly] Skipping actual API call for this group."
        continue
    }

    Read-Host "Press Enter to run scripted action $ScriptedActionId against these $($matched.Count) host(s) in '$pool', or Ctrl+C to abort"

    # ---- 5. Build the request through the confirmed cmdlet chain ----
    $actionOption = New-NmeScriptedActionOption -Type 'Action' -Id $ScriptedActionId

    $runScriptParams = New-NmeRunScriptParams `
        -ActiveDirectoryId $ActiveDirectoryId `
        -ScriptedActions @($actionOption)

    $bulkJobParams = New-NmeBulkJobParamsBulkRunScript `
        -TaskParallelism $TaskParallelism `
        -CountFailedTaskToStopWork $CountFailedTaskToStopWork `
        -RestartVms ([bool]$RestartVm) `
        -SessionHostsToProcessNames $matched

    $payload = New-NmeRunHostPoolScriptRestPayload `
        -Config $runScriptParams `
        -BulkJobParams $bulkJobParams

    $request = New-NmeRunHostPoolScriptRestRequest -JobPayload $payload

    # ---- 6. Fire it ----
    $result = New-NmeHostPoolScriptTask `
        -SubscriptionId $subId `
        -ResourceGroup  $rg `
        -HostPoolName   $pool `
        -NmeRunHostPoolScriptRestRequest $request

    Write-Host "Submitted. Result:"
    $result | Format-List *
}

Write-Host ""
Write-Host "Done."
