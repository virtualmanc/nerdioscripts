#description: Expands the OS disk on an AVD session host VM and extends the in-guest Windows partition to use the new space.
#tags: Nerdio, AVD, Storage, Disk, OSDisk

<#
Notes:

This script must be run as an Azure Runbook scripted action targeted at a specific VM
(e.g. via Scripted Actions -> Azure runbooks -> Run now, selecting the host(s) to run against,
or attached to a host pool as a manual "Run script" action). It cannot be run as a Windows
Script, because resizing the underlying managed disk is an ARM-level operation and requires
the VM to be deallocated — something that can't be done from inside the guest OS.

Workflow:
  1. Read the current OS disk size for the target VM.
  2. Validate the requested NewDiskSizeGB is larger than the current size.
  3. Deallocate the VM (if not already deallocated).
  4. Resize the managed OS disk.
  5. Start the VM.
  6. Extend the in-guest C: partition via Invoke-AzVMRunCommand.

Requires the Nerdio Manager service principal to have Contributor (or equivalent) rights
on the target VM and its OS disk.

Built-in Nerdio variables are declared in the param block below with
ParameterSetName = "NME_PARAMETER" so they are hidden in the UI but still populated
automatically by Nerdio Manager.
#>

param (
    [Parameter(Mandatory = $true, HelpMessage = "Target OS disk size in GB. Must be larger than the current size (most AVD gallery images ship at 128GB).")]
    [int] $NewDiskSizeGB = 256,

    [Parameter(Mandatory = $false, HelpMessage = "Tick only if the VM is already deallocated and you want to skip the stop step.")]
    [bool] $SkipDeallocate = $false,

    [Parameter(ParameterSetName = "NME_PARAMETER")]
    [string] $AzureSubscriptionId,

    [Parameter(ParameterSetName = "NME_PARAMETER")]
    [string] $AzureResourceGroupName,

    [Parameter(ParameterSetName = "NME_PARAMETER")]
    [string] $AzureVMName,

    [Parameter(ParameterSetName = "NME_PARAMETER")]
    [string] $AzureRegionName
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$timestamp] [$Level] $Message"
}

##### Validate Nerdio built-ins #####
if ([string]::IsNullOrEmpty($AzureVMName)) {
    Throw "AzureVMName is not set. This script must be run against a specific VM (via Run now against a host, or attached to a host pool/host)."
}
if ([string]::IsNullOrEmpty($AzureResourceGroupName)) {
    Throw "AzureResourceGroupName is not set. This script must be run against a specific VM."
}

Write-Log "Target VM: $AzureVMName | Resource Group: $AzureResourceGroupName | Target OS disk size: ${NewDiskSizeGB}GB"

# If Nerdio's automation account spans multiple subscriptions, make sure we're pointed at the right one
if (-not [string]::IsNullOrEmpty($AzureSubscriptionId)) {
    Write-Log "Setting context to subscription $AzureSubscriptionId"
    Set-AzContext -SubscriptionId $AzureSubscriptionId | Out-Null
}

try {
    Write-Log "Retrieving VM '$AzureVMName'"
    $vm = Get-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName -ErrorAction Stop

    $osDiskName = $vm.StorageProfile.OsDisk.Name
    Write-Log "OS disk identified: $osDiskName"

    $osDisk = Get-AzDisk -ResourceGroupName $AzureResourceGroupName -DiskName $osDiskName -ErrorAction Stop
    $currentSizeGB = $osDisk.DiskSizeGB

    Write-Log "Current OS disk size: ${currentSizeGB}GB. Target size: ${NewDiskSizeGB}GB"

    if ($NewDiskSizeGB -le $currentSizeGB) {
        Write-Log "Target size (${NewDiskSizeGB}GB) is not greater than current size (${currentSizeGB}GB). Nothing to do." 'WARN'
        return
    }

    # --- Step 1: Deallocate the VM ---
    $vmStatus = (Get-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName -Status).Statuses |
        Where-Object { $_.Code -like 'PowerState*' } | Select-Object -ExpandProperty Code

    if (-not $SkipDeallocate) {
        if ($vmStatus -ne 'PowerState/deallocated') {
            Write-Log "Current power state: $vmStatus. Deallocating VM before resize..."
            Stop-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName -Force | Out-Null
            Write-Log "VM deallocated."
        }
        else {
            Write-Log "VM already deallocated. Skipping stop step."
        }
    }
    else {
        Write-Log "SkipDeallocate specified — assuming VM is already deallocated." 'WARN'
    }

    # --- Step 2: Resize the OS disk ---
    Write-Log "Resizing OS disk '$osDiskName' from ${currentSizeGB}GB to ${NewDiskSizeGB}GB"
    $osDisk.DiskSizeGB = $NewDiskSizeGB
    Update-AzDisk -ResourceGroupName $AzureResourceGroupName -DiskName $osDiskName -Disk $osDisk | Out-Null
    Write-Log "Disk resize submitted successfully."

    # --- Step 3: Start the VM ---
    Write-Log "Starting VM '$AzureVMName'..."
    Start-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName | Out-Null
    Write-Log "VM started."

    # --- Step 4: Extend the in-guest partition ---
    $inGuestScript = @'
$ErrorActionPreference = "Stop"
$driveLetter = "C"
$partition = Get-Partition -DriveLetter $driveLetter
$maxSize = (Get-PartitionSupportedSize -DriveLetter $driveLetter).SizeMax

if ($partition.Size -lt $maxSize) {
    Resize-Partition -DriveLetter $driveLetter -Size $maxSize
    Write-Output "Partition $driveLetter extended to $([math]::Round($maxSize / 1GB, 2))GB"
} else {
    Write-Output "Partition $driveLetter already at max size ($([math]::Round($partition.Size / 1GB, 2))GB). No action taken."
}
'@

    Write-Log "Waiting for the guest OS/agent to come fully online..."
    Start-Sleep -Seconds 60

    Write-Log "Invoking in-guest partition extension via Run Command..."
    $runResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $AzureResourceGroupName `
        -VMName $AzureVMName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $inGuestScript

    $output = $runResult.Value | Where-Object { $_.Code -eq 'ComponentStatus/StdOut/succeeded' } | Select-Object -ExpandProperty Message
    Write-Log "In-guest result: $output"

    Write-Log "OS disk resize and partition extension completed for '$AzureVMName'." 'SUCCESS'
}
catch {
    Write-Log "Failed: $($_.Exception.Message)" 'ERROR'
    throw
}
