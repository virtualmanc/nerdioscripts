# ============================================================
# Nerdio Backup & Restore Toolkit
# ============================================================
# Usage:
#   .\NerdioBackupRestore.ps1 -Action Backup
#   .\NerdioBackupRestore.ps1 -Action RestoreHostPool -BackupFile "C:\backups\nerdio\hostpools\2026-04-12\domainjoin.json"
#   .\NerdioBackupRestore.ps1 -Action RestoreAllHostPools -BackupFolder "C:\backups\nerdio\hostpools\2026-04-12"
#   .\NerdioBackupRestore.ps1 -Action BackupScriptedActions
#   .\NerdioBackupRestore.ps1 -Action RestoreScriptedActions -BackupFile "C:\backups\nerdio\scripted-actions\2026-04-12\all-scripted-actions.json"
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet(
        "Backup",
        "RestoreHostPool",
        "RestoreAllHostPools",
        "BackupScriptedActions",
        "RestoreScriptedActions"
    )]
    [string]$Action,

    [string]$BackupFile,
    [string]$BackupFolder,
    [string]$TargetSubscriptionId,
    [string]$TargetResourceGroup,
    [string]$TargetHostPoolName,
    [string]$TargetWorkspaceId
)

# ============================================================
# CONFIG - Edit these
# ============================================================
$SubscriptionId = "yoursubscriptionhere"
$BackupRoot     = "C:\backups\nerdio"

# ============================================================
# BACKUP - All Nerdio-Managed Host Pools
# ============================================================
function Backup-NmeHostPools {

    $timestamp    = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $backupFolder = Join-Path "$BackupRoot\hostpools" $timestamp
    New-Item -ItemType Directory -Force -Path $backupFolder | Out-Null

    Write-Host "Discovering host pools from Azure..." -ForegroundColor Cyan
    $allHostPools = Get-AzWvdHostPool
    Write-Host "Found $($allHostPools.Count) total host pools" -ForegroundColor Green

    $exported = 0
    $skipped  = 0
    $failed   = 0
    $manifest = @()

    foreach ($hp in $allHostPools) {

        Write-Host "  Testing: $($hp.Name)" -ForegroundColor Cyan

        try {
            Get-NmeHostPool `
                -SubscriptionId $SubscriptionId `
                -ResourceGroup  $hp.ResourceGroupName `
                -HostPoolName   $hp.Name `
                -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "    Not managed by Nerdio - skipping" -ForegroundColor Yellow
            $skipped++
            continue
        }

        try {
            $config    = Export-NmeHostPoolConfig `
                -SubscriptionId $SubscriptionId `
                -ResourceGroup  $hp.ResourceGroupName `
                -HostPoolName   $hp.Name

            $configObj = $config | ConvertFrom-Json

            $workspace = Get-AzWvdWorkspace `
                -ResourceGroupName $hp.ResourceGroupName `
                -ErrorAction SilentlyContinue | Select-Object -First 1

            $avdHp = Get-AzWvdHostPool `
                -ResourceGroupName $hp.ResourceGroupName `
                -Name              $hp.Name

            $enriched = @{
                NerdioConfig = $configObj
                AzureConfig  = @{
                    HostPoolType                  = $avdHp.HostPoolType
                    Location                      = $avdHp.Location
                    FriendlyName                  = $avdHp.FriendlyName
                    Description                   = $avdHp.Description
                    LoadBalancerType              = $avdHp.LoadBalancerType
                    MaxSessionLimit               = $avdHp.MaxSessionLimit
                    PreferredAppGroupType         = $avdHp.PreferredAppGroupType
                    PersonalDesktopAssignmentType = $avdHp.PersonalDesktopAssignmentType
                    ValidationEnvironment         = $avdHp.ValidationEnvironment
                    StartVMOnConnect              = $avdHp.StartVMOnConnect
                    CustomRdpProperty             = $avdHp.CustomRdpProperty
                    ResourceGroupName             = $hp.ResourceGroupName
                    Name                          = $hp.Name
                    SubscriptionId                = $SubscriptionId
                }
                WorkspaceId  = $workspace.Id
                BackupDate   = $timestamp
            }

            $fileName = "$($hp.Name).json"
            $enriched | ConvertTo-Json -Depth 20 |
                Out-File (Join-Path $backupFolder $fileName) -Encoding UTF8

            $manifest += @{
                Name          = $hp.Name
                ResourceGroup = $hp.ResourceGroupName
                File          = $fileName
            }

            Write-Host "    Exported: $fileName" -ForegroundColor Green
            $exported++
        }
        catch {
            Write-Host "    FAILED: $($hp.Name) - $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }

    @{
        BackupDate     = $timestamp
        SubscriptionId = $SubscriptionId
        HostPools      = $manifest
    } | ConvertTo-Json -Depth 5 |
        Out-File (Join-Path $backupFolder "manifest.json") -Encoding UTF8

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Backup Summary" -ForegroundColor Cyan
    Write-Host "  Exported : $exported" -ForegroundColor Green
    Write-Host "  Skipped  : $skipped"  -ForegroundColor Yellow
    Write-Host "  Failed   : $failed"   -ForegroundColor Red
    Write-Host "  Location : $backupFolder" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

# ============================================================
# CREATE HOST POOL - Step 1 of restore (Nerdio only)
# ============================================================
function New-HostPoolFromBackup {
    param(
        [Parameter(Mandatory=$true)]
        $Backup,
        [string]$SubId,
        [string]$RG,
        [string]$HPName,
        [string]$WorkspaceId
    )

    $az     = $Backup.AzureConfig
    $nerdio = $Backup.NerdioConfig

    Write-Host "  Creating host pool via Nerdio: $HPName" -ForegroundColor Cyan

    try {
        $wsParts = $WorkspaceId -split '/'
        $wsSubId = $wsParts[2]
        $wsRG    = $wsParts[4]
        $wsName  = $wsParts[-1]

        $workspaceObj = New-NmeWvdObjectId `
            -SubscriptionId $wsSubId `
            -ResourceGroup  $wsRG `
            -Name           $wsName

        $adProfileId  = $nerdio.AdConfig.PredefinedConfigId
        $hasAdProfile = ($adProfileId -ne $null -and $adProfileId -gt 0)

        if ($hasAdProfile) {
            $adPayload = New-NmeHostpoolAdPayload -AdProfileId $adProfileId
        }

        if ($az.HostPoolType -eq "Pooled") {
            $poolParams = New-NmePooledParams `
                -IsSingleUser $nerdio.AsConfig.IsSingleUserDesktop `
                -IsDesktop    ($az.PreferredAppGroupType -eq "Desktop")

            if ($hasAdProfile) {
                $createRequest = New-NmeCreateArmHostPoolRequest `
                    -WorkspaceId     $workspaceObj `
                    -PooledParams    $poolParams `
                    -ActiveDirectory $adPayload `
                    -Description     $az.Description `
                    -AppGroupName    "$HPName-AppGroup"
            }
            else {
                $createRequest = New-NmeCreateArmHostPoolRequest `
                    -WorkspaceId  $workspaceObj `
                    -PooledParams $poolParams `
                    -Description  $az.Description `
                    -AppGroupName "$HPName-AppGroup"
            }
        }
        else {
            $personalParams = New-NmePersonalParams `
                -AssignmentType $az.PersonalDesktopAssignmentType

            if ($hasAdProfile) {
                $createRequest = New-NmeCreateArmHostPoolRequest `
                    -WorkspaceId     $workspaceObj `
                    -PersonalParams  $personalParams `
                    -ActiveDirectory $adPayload `
                    -Description     $az.Description `
                    -AppGroupName    "$HPName-AppGroup"
            }
            else {
                $createRequest = New-NmeCreateArmHostPoolRequest `
                    -WorkspaceId    $workspaceObj `
                    -PersonalParams $personalParams `
                    -Description    $az.Description `
                    -AppGroupName   "$HPName-AppGroup"
            }
        }

        $result = New-NmeHostPool `
            -SubscriptionId              $SubId `
            -ResourceGroup               $RG `
            -HostPoolName                $HPName `
            -NmeCreateArmHostPoolRequest $createRequest

        Write-Host "    Host pool creation job submitted (JobId: $($result.job.id))" -ForegroundColor Green

        Write-Host "    Waiting for host pool to become available..." -ForegroundColor Cyan
        $timeout  = 120
        $elapsed  = 0
        $interval = 10
        $ready    = $false

        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds $interval
            $elapsed += $interval

            try {
                Get-NmeHostPool `
                    -SubscriptionId $SubId `
                    -ResourceGroup  $RG `
                    -HostPoolName   $HPName `
                    -ErrorAction Stop | Out-Null

                Write-Host "    Host pool is ready" -ForegroundColor Green
                $ready = $true
                break
            }
            catch {
                Write-Host "    Still waiting... ($elapsed/$timeout seconds)" -ForegroundColor Yellow
            }
        }

        if (-not $ready) {
            throw "Timed out waiting for host pool to become available in Nerdio"
        }

        Write-Host "    Converting to dynamic host pool..." -ForegroundColor Cyan
        try {
            $convertResult = ConvertTo-NmeDynamicHostPool `
                -SubscriptionId $SubId `
                -ResourceGroup  $RG `
                -HostPoolName   $HPName

            Write-Host "    Conversion job submitted (JobId: $($convertResult.job.id))" -ForegroundColor Green

            Write-Host "    Waiting for conversion to complete..." -ForegroundColor Cyan
            $timeout  = 120
            $elapsed  = 0
            $interval = 10

            while ($elapsed -lt $timeout) {
                Start-Sleep -Seconds $interval
                $elapsed += $interval

                try {
                    $asCheck = Get-NmeHostPoolAutoScaleConfig `
                        -SubscriptionId $SubId `
                        -ResourceGroup  $RG `
                        -HostPoolName   $HPName `
                        -ErrorAction Stop

                    if ($asCheck -ne $null) {
                        Write-Host "    Host pool is now dynamic and ready" -ForegroundColor Green
                        Start-Sleep -Seconds 5
                        break
                    }
                }
                catch {
                    Write-Host "    Still converting... ($elapsed/$timeout seconds)" -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host "    [FAIL] Convert to dynamic - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "    FAILED to create host pool - $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# ============================================================
# APPLY CONFIG - Step 2 of restore
# ============================================================
function Set-HostPoolConfig {
    param(
        $NerdioConfig,
        [string]$SubId,
        [string]$RG,
        [string]$HPName
    )

    Write-Host "  Applying Nerdio config to: $HPName" -ForegroundColor Cyan

    # AVD Config
    try {
        $avdModel = New-NmeArmHostPoolPropertiesRestModel `
            -FriendlyName       $NerdioConfig.AvdConfig.FriendlyName `
            -Description        $NerdioConfig.AvdConfig.Description `
            -LoadBalancerType   $NerdioConfig.AvdConfig.LoadBalancerType `
            -MaxSessionLimit    $NerdioConfig.AvdConfig.MaxSessionLimit `
            -ValidationEnv      $NerdioConfig.AvdConfig.ValidationEnv `
            -PowerOnPooledHosts $NerdioConfig.AvdConfig.PowerOnPooledHosts `
            -StartVMOnConnect   $NerdioConfig.AvdConfig.StartVMOnConnect

        Set-NmeHostPoolAVDConfig `
            -SubscriptionId                    $SubId `
            -ResourceGroup                     $RG `
            -HostPoolName                      $HPName `
            -NmeArmHostPoolPropertiesRestModel $avdModel

        Write-Host "    [OK] AVD config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] AVD config - $($_.Exception.Message)" -ForegroundColor Red }

    # RDP Config - PATCH only, ConfigurationName OR RdpProperties never both
    try {
        $rdpConfig     = $NerdioConfig.RdpConfig
        $hasConfigName = ($rdpConfig.ConfigurationName -ne $null -and $rdpConfig.ConfigurationName -ne "")
        $hasRdpProps   = ($rdpConfig.RdpProperties -ne $null -and $rdpConfig.RdpProperties -ne "")

        if ($hasConfigName) {
            $rdpModel = New-NmePatchHostPoolRdpRequestRest `
                -ConfigurationName $rdpConfig.ConfigurationName
        }
        elseif ($hasRdpProps) {
            $rdpModel = New-NmePatchHostPoolRdpRequestRest `
                -RdpProperties $rdpConfig.RdpProperties
        }
        else {
            $rdpModel = New-NmePatchHostPoolRdpRequestRest
        }

        Update-NmeHostPoolRdpConfig `
            -SubscriptionId                 $SubId `
            -ResourceGroup                  $RG `
            -HostPoolName                   $HPName `
            -NmePatchHostPoolRdpRequestRest $rdpModel

        Write-Host "    [OK] RDP config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] RDP config - $($_.Exception.Message)" -ForegroundColor Red }

    # FSLogix Config - only pass PredefinedConfigId if valid non-zero value
    try {
        $fsl            = $NerdioConfig.FslConfig
        $fslConfigId    = $fsl.PredefinedConfigId
        $hasFslConfigId = ($fslConfigId -ne $null -and $fslConfigId -gt 0)

        if ($hasFslConfigId) {
            $fslModel = New-NmeUpdateHostPoolFsLogixRestModel `
                -Enable             $fsl.Enable `
                -Type               $fsl.Type `
                -PredefinedConfigId $fslConfigId
        }
        else {
            $fslModel = New-NmeUpdateHostPoolFsLogixRestModel `
                -Enable $fsl.Enable `
                -Type   $fsl.Type
        }

        Set-NmeHostPoolFslConfig `
            -SubscriptionId                    $SubId `
            -ResourceGroup                     $RG `
            -HostPoolName                      $HPName `
            -NmeUpdateHostPoolFsLogixRestModel $fslModel

        Write-Host "    [OK] FSLogix config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] FSLogix config - $($_.Exception.Message)" -ForegroundColor Red }

    # AD Config
    try {
        $adModel = New-NmeUpdateHostPoolActiveDirectoryRestModel `
            -Type               $NerdioConfig.AdConfig.Type `
            -PredefinedConfigId $NerdioConfig.AdConfig.PredefinedConfigId

        Set-NmeHostPoolADConfig `
            -SubscriptionId                            $SubId `
            -ResourceGroup                             $RG `
            -HostPoolName                              $HPName `
            -NmeUpdateHostPoolActiveDirectoryRestModel $adModel

        Write-Host "    [OK] AD config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] AD config - $($_.Exception.Message)" -ForegroundColor Red }

    # Backup Config
    try {
        $backupModel = New-NmeHostPoolBackupModelRest `
            -BackupMode     $NerdioConfig.BackupConfig.BackupMode `
            -BackupPolicyId $NerdioConfig.BackupConfig.BackupPolicyId

        Set-NmeHostPoolBackupConfig `
            -SubscriptionId             $SubId `
            -ResourceGroup              $RG `
            -HostPoolName               $HPName `
            -NmeHostPoolBackupModelRest $backupModel

        Write-Host "    [OK] Backup config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] Backup config - $($_.Exception.Message)" -ForegroundColor Red }

    # Session Timeout Config
    try {
        $timeoutModel = New-NmeHostPoolSessionTimeoutRestModel `
            -IsSessionTimeoutsEnabled $NerdioConfig.SessiontTimeoutConfig.IsSessionTimeoutsEnabled `
            -MaxDisconnectionTime     $NerdioConfig.SessiontTimeoutConfig.MaxDisconnectionTime `
            -MaxIdleTime              $NerdioConfig.SessiontTimeoutConfig.MaxIdleTime `
            -MaxConnectionTime        $NerdioConfig.SessiontTimeoutConfig.MaxConnectionTime `
            -RemoteAppLogoffTimeLimit $NerdioConfig.SessiontTimeoutConfig.RemoteAppLogoffTimeLimit `
            -FresetBroken             $NerdioConfig.SessiontTimeoutConfig.FresetBroken

        Set-NmeHostPoolSessionTimeoutConfig `
            -SubscriptionId                     $SubId `
            -ResourceGroup                      $RG `
            -HostPoolName                       $HPName `
            -NmeHostPoolSessionTimeoutRestModel $timeoutModel

        Write-Host "    [OK] Session timeout config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] Session timeout config - $($_.Exception.Message)" -ForegroundColor Red }

    # Custom Tags
    try {
        $tagsModel = New-NmeUpdateHostPoolTagsRest -Tags $NerdioConfig.CustomTags.Tags

        Set-NmeHostPoolCustomTags `
            -SubscriptionId            $SubId `
            -ResourceGroup             $RG `
            -HostPoolName              $HPName `
            -NmeUpdateHostPoolTagsRest $tagsModel

        Write-Host "    [OK] Custom tags" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] Custom tags - $($_.Exception.Message)" -ForegroundColor Red }

    # Self Service Config
    try {
        $ss = $NerdioConfig.SelfServiceConfig

        $selfServiceModel = New-NmeHostPoolUserSelfServicePatchModelRest `
            -AllowStartDesktops                  $ss.AllowStartDesktops `
            -AllowStopDesktops                   $ss.AllowStopDesktops `
            -AllowRestartDesktops                $ss.AllowRestartDesktops `
            -AllowReimageDesktops                $ss.AllowReimageDesktops `
            -AllowResizeDesktops                 $ss.AllowResizeDesktops `
            -AllowRestoreDesktops                $ss.AllowRestoreDesktops `
            -AllowCreateVm                       $ss.AllowCreateVm `
            -AllowAppInstall                     $ss.AllowAppInstall `
            -AllowScriptedActions                $ss.AllowScriptedActions `
            -AllowResetFsLogix                   $ss.AllowResetFsLogix `
            -AllowUpdateDesktopsTags             $ss.AllowUpdateDesktopsTags `
            -AllowRestrictAutoScale              $ss.AllowRestrictAutoScale `
            -MaxAutoScaleRestrictionPeriod       $ss.MaxAutoScaleRestrictionPeriod `
            -AutoRevertPersonalSize              $ss.AutoRevertPersonalSize `
            -AutoRevertPersonalSizeMaxDelayHours $ss.AutoRevertPersonalSizeMaxDelayHours `
            -RecoveryMode                        $ss.RecoveryMode

        Set-NmeHostPoolSelfServiceConfig `
            -SubscriptionId                           $SubId `
            -ResourceGroup                            $RG `
            -HostPoolName                             $HPName `
            -NmeHostPoolUserSelfServicePatchModelRest $selfServiceModel

        Write-Host "    [OK] Self service config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] Self service config - $($_.Exception.Message)" -ForegroundColor Red }

    # AutoScale Config - restore last
    # All nested objects must be built as proper typed objects
    try {
        $as  = $NerdioConfig.AsConfig
        $vmt = $as.VmTemplate

        # Build VmTemplate
        if ($vmt.ephemeralOSDiskPlacement -ne $null -and $vmt.ephemeralOSDiskPlacement -ne "") {
            $vmTemplate = New-NmeVmTemplateParams `
                -Prefix                   $vmt.prefix `
                -Size                     $vmt.size `
                -Image                    $vmt.image `
                -StorageType              $vmt.storageType `
                -ResourceGroupId          $vmt.resourceGroupId `
                -NetworkId                $vmt.networkId `
                -Subnet                   $vmt.subnet `
                -DiskSize                 $vmt.diskSize `
                -HasEphemeralOSDisk       $vmt.hasEphemeralOSDisk `
                -EphemeralOSDiskPlacement $vmt.ephemeralOSDiskPlacement
        }
        else {
            $vmTemplate = New-NmeVmTemplateParams `
                -Prefix             $vmt.prefix `
                -Size               $vmt.size `
                -Image              $vmt.image `
                -StorageType        $vmt.storageType `
                -ResourceGroupId    $vmt.resourceGroupId `
                -NetworkId          $vmt.networkId `
                -Subnet             $vmt.subnet `
                -DiskSize           $vmt.diskSize `
                -HasEphemeralOSDisk $vmt.hasEphemeralOSDisk
        }

        # Build ScaleInRestriction
        $sir = $as.ScaleInRestriction
        $scaleInRestriction = New-NmeScaleIntimeRestrictionConfiguration `
            -Enable         $sir.enable `
            -PutToDrainMode $sir.putToDrainMode

        # Build PreStageHosts
        $psh = $as.PreStageHosts
        $preStageHosts = New-NmePreStateHostsConfiguration `
            -Enable                $psh.enable `
            -IsMultipleConfigsMode $psh.isMultipleConfigsMode

        # Build RemoveMessaging
        $rm = $as.RemoveMessaging
        $removeMessaging = New-NmeWarningMessageSettings `
            -MinutesBeforeRemove $rm.minutesBeforeRemove `
            -Message             $rm.message

        # Build AutoHeal
        $ah = $as.AutoHeal
        $autoHeal = New-NmeAutoHealConfiguration `
            -Enable $ah.enable

        # Build UserDriven
        $ud = $as.UserDriven
        $userDriven = New-NmeUserDrivenRestConfiguration `
            -StopDelayMinutes     $ud.stopDelayMinutes `
            -MinAvailableSessions $ud.minAvailableSessions `
            -BypassDrainMode      $ud.bypassDrainMode

        # Build Extensions
        $ext = $as.Extensions
        $extensions = New-NmeExtensionsRestConfiguration `
            -MaxSessionsPerHost $ext.maxSessionsPerHost `
            -LoadBalancing      $ext.loadBalancing `
            -StartVmOnConnect   $ext.startVmOnConnect

        # Build RollingDrainMode - omit entirely if not enabled or no windows defined
        $rdm = $as.RollingDrainMode
        if ($rdm.isEnabled -and $rdm.windows -ne $null -and $rdm.windows.Count -gt 0) {
            $rollingDrainMode = New-NmeRollingDrainModeRestConfiguration `
                -IsEnabled $rdm.isEnabled `
                -Windows   $rdm.windows
        }
        else {
            $rollingDrainMode = $null
        }

        # Build SecondaryRegion
        $sr = $as.SecondaryRegion
        $secondaryRegion = New-NmeSecondaryRegionRestModel `
            -Enabled $sr.enabled

        # Build UserDrivenPreStageHosts - omit entirely if no configs defined
        $udpsh = $as.UserDrivenPreStageHosts
        if ($udpsh.configs -ne $null -and $udpsh.configs.Count -gt 0) {
            $userDrivenPreStageHosts = New-NmeUserDrivenPreStageHostsConfiguration `
                -Enable               $udpsh.enable `
                -Configs              $udpsh.configs `
                -PreStageIfUnassigned $udpsh.preStageIfUnassigned
        }
        else {
            $userDrivenPreStageHosts = $null
        }

        # Build AutoScaleTriggers
        # Force to array to handle single trigger objects from ConvertFrom-Json
        $triggerList = @($as.AutoScaleTriggers)
        $triggers    = @()

        foreach ($trigger in $triggerList) {
            Write-Host "    Building trigger: $($trigger.TriggerType)" -ForegroundColor Cyan
            $triggerParams = @{ TriggerType = $trigger.TriggerType }

            switch ($trigger.TriggerType) {

                "CPUUsage" {
                    $cpu      = $trigger.Cpu
                    $scaleOut = New-NmeHostUsage `
                        -HostChangeCount           $cpu.scaleOut.hostChangeCount `
                        -Value                     $cpu.scaleOut.value `
                        -AverageTimeRangeInMinutes $cpu.scaleOut.averageTimeRangeInMinutes
                    $scaleIn  = New-NmeHostUsage `
                        -HostChangeCount           $cpu.scaleIn.hostChangeCount `
                        -Value                     $cpu.scaleIn.value `
                        -AverageTimeRangeInMinutes $cpu.scaleIn.averageTimeRangeInMinutes
                    $triggerParams.Cpu = New-NmeHostUsageConfiguration `
                        -ScaleOut $scaleOut `
                        -ScaleIn  $scaleIn
                }

                "RAMUsage" {
                    $ram      = $trigger.Ram
                    $scaleOut = New-NmeHostUsage `
                        -HostChangeCount           $ram.scaleOut.hostChangeCount `
                        -Value                     $ram.scaleOut.value `
                        -AverageTimeRangeInMinutes $ram.scaleOut.averageTimeRangeInMinutes
                    $scaleIn  = New-NmeHostUsage `
                        -HostChangeCount           $ram.scaleIn.hostChangeCount `
                        -Value                     $ram.scaleIn.value `
                        -AverageTimeRangeInMinutes $ram.scaleIn.averageTimeRangeInMinutes
                    $triggerParams.Ram = New-NmeHostUsageConfiguration `
                        -ScaleOut $scaleOut `
                        -ScaleIn  $scaleIn
                }

                "AvgActiveSessions" {
                    $avg      = $trigger.AverageSessions
                    $scaleOut = New-NmeHostChange `
                        -HostChangeCount $avg.scaleOut.hostChangeCount `
                        -Value           $avg.scaleOut.value
                    $scaleIn  = New-NmeHostChange `
                        -HostChangeCount $avg.scaleIn.hostChangeCount `
                        -Value           $avg.scaleIn.value
                    $triggerParams.AverageSessions = New-NmeActiveSessionsConfiguration `
                        -ScaleOut $scaleOut `
                        -ScaleIn  $scaleIn
                }

                { $_ -in "AvailableUserSessionSingle","AvailableUserSessions" } {
                    $avail = $trigger.AvailableSessions
                    $triggerParams.AvailableSessions = New-NmeAvailableUserSessionsConfiguration `
                        -MinAvailableUserSessions    $avail.minAvailableUserSessions `
                        -MaxAvailableUserSessions    $avail.maxAvailableUserSessions `
                        -AvailableSessionRestriction $avail.availableSessionRestriction `
                        -OutsideWorkHoursSessions    $avail.outsideWorkHoursSessions `
                        -EndWorkHours                $avail.endWorkHours
                }

                "UserDriven" {
                    $tud = $trigger.UserDriven
                    $triggerParams.UserDriven = New-NmeUserDrivenRestConfiguration `
                        -StopDelayMinutes     $tud.stopDelayMinutes `
                        -MinAvailableSessions $tud.minAvailableSessions `
                        -BypassDrainMode      $tud.bypassDrainMode
                }
            }

            $triggers += New-NmeTriggerInfo @triggerParams
        }

        # Build params hashtable so we can conditionally omit null objects
        $asParams = @{
            IsEnabled             = $as.IsEnabled
            TimezoneId            = $as.TimezoneId
            VmTemplate            = $vmTemplate
            StoppedDiskType       = $as.StoppedDiskType
            IsSingleUserDesktop   = $as.IsSingleUserDesktop
            ActiveHostType        = $as.ActiveHostType
            ScalingMode           = $as.ScalingMode
            HostPoolCapacity      = $as.HostPoolCapacity
            MinActiveHostsCount   = $as.MinActiveHostsCount
            BurstCapacity         = $as.BurstCapacity
            AutoScaleCriteria     = $as.AutoScaleCriteria
            ScaleInAggressiveness = $as.ScaleInAggressiveness
            ScaleInRestriction    = $scaleInRestriction
            PreStageHosts         = $preStageHosts
            RemoveMessaging       = $removeMessaging
            AutoHeal              = $autoHeal
            ReImageUsedHosts      = $as.ReImageUsedHosts
            UserDriven            = $userDriven
            AutoScaleTriggers     = $triggers
            Extensions            = $extensions
            VmNamingMode          = $as.VmNamingMode
            SecondaryRegion       = $secondaryRegion
        }

        # Build HostUsageScaleCriteria if present (required for CPU/RAM trigger types)
        if ($as.HostUsageScaleCriteria -ne $null) {
            $huscScaleOut = New-NmeHostUsage `
                -HostChangeCount           $as.HostUsageScaleCriteria.scaleOut.hostChangeCount `
                -Value                     $as.HostUsageScaleCriteria.scaleOut.value `
                -AverageTimeRangeInMinutes $as.HostUsageScaleCriteria.scaleOut.averageTimeRangeInMinutes
            $huscScaleIn  = New-NmeHostUsage `
                -HostChangeCount           $as.HostUsageScaleCriteria.scaleIn.hostChangeCount `
                -Value                     $as.HostUsageScaleCriteria.scaleIn.value `
                -AverageTimeRangeInMinutes $as.HostUsageScaleCriteria.scaleIn.averageTimeRangeInMinutes
            $asParams.HostUsageScaleCriteria = New-NmeHostUsageConfiguration `
                -ScaleOut $huscScaleOut `
                -ScaleIn  $huscScaleIn
        }

        # Only add optional objects if successfully built
        if ($rollingDrainMode -ne $null) {
            $asParams.RollingDrainMode = $rollingDrainMode
        }
        if ($userDrivenPreStageHosts -ne $null) {
            $asParams.UserDrivenPreStageHosts = $userDrivenPreStageHosts
        }

        $asConfig = New-NmeDynamicPoolConfiguration @asParams

        Set-NmeHostPoolAutoScaleConfig `
            -SubscriptionId              $SubId `
            -ResourceGroup               $RG `
            -HostPoolName                $HPName `
            -NmeDynamicPoolConfiguration @($asConfig)

        Write-Host "    [OK] AutoScale config" -ForegroundColor Green
    }
    catch { Write-Host "    [FAIL] AutoScale config - $($_.Exception.Message)" -ForegroundColor Red }
}

# ============================================================
# RESTORE HOST POOL - Full end-to-end
# ============================================================
function Restore-NmeHostPool {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BackupFile,
        [string]$TargetSubscriptionId,
        [string]$TargetResourceGroup,
        [string]$TargetHostPoolName,
        [string]$TargetWorkspaceId
    )

    $backup = Get-Content $BackupFile -Raw | ConvertFrom-Json

    $SubId       = if ($TargetSubscriptionId) { $TargetSubscriptionId } else { $backup.AzureConfig.SubscriptionId }
    $RG          = if ($TargetResourceGroup)  { $TargetResourceGroup  } else { $backup.AzureConfig.ResourceGroupName }
    $HPName      = if ($TargetHostPoolName)   { $TargetHostPoolName   } else { $backup.AzureConfig.Name }
    $WorkspaceId = if ($TargetWorkspaceId)    { $TargetWorkspaceId    } else { $backup.WorkspaceId }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Restoring host pool: $HPName" -ForegroundColor Cyan
    Write-Host "  Sub       : $SubId"       -ForegroundColor Gray
    Write-Host "  RG        : $RG"          -ForegroundColor Gray
    Write-Host "  Workspace : $WorkspaceId" -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor Cyan

    $exists = $null
    try {
        $exists = Get-NmeHostPool `
            -SubscriptionId $SubId `
            -ResourceGroup  $RG `
            -HostPoolName   $HPName `
            -ErrorAction Stop
    } catch {}

    if ($exists) {
        Write-Host "  Host pool already exists in Nerdio - applying config only" -ForegroundColor Yellow
    }
    else {
        Write-Host "  Host pool not found - creating via Nerdio..." -ForegroundColor Cyan
        try {
            New-HostPoolFromBackup `
                -Backup      $backup `
                -SubId       $SubId `
                -RG          $RG `
                -HPName      $HPName `
                -WorkspaceId $WorkspaceId
        }
        catch {
            Write-Host "  Host pool creation failed - aborting restore" -ForegroundColor Red
            return
        }
    }

    Set-HostPoolConfig `
        -NerdioConfig $backup.NerdioConfig `
        -SubId        $SubId `
        -RG           $RG `
        -HPName       $HPName

    Write-Host ""
    Write-Host "Restore complete: $HPName" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
}

# ============================================================
# RESTORE ALL HOST POOLS
# ============================================================
function Restore-NmeAllHostPools {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BackupFolder
    )

    $manifest = Get-Content (Join-Path $BackupFolder "manifest.json") -Raw |
        ConvertFrom-Json

    Write-Host "Restoring $($manifest.HostPools.Count) host pools from: $($manifest.BackupDate)" -ForegroundColor Cyan

    foreach ($hp in $manifest.HostPools) {
        Restore-NmeHostPool -BackupFile (Join-Path $BackupFolder $hp.File)
    }

    Write-Host ""
    Write-Host "All host pools restored." -ForegroundColor Green
}

# ============================================================
# BACKUP SCRIPTED ACTIONS
# ============================================================
function Backup-NmeScriptedActions {

    $timestamp    = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $backupFolder = Join-Path "$BackupRoot\scripted-actions" $timestamp
    New-Item -ItemType Directory -Force -Path $backupFolder | Out-Null

    $actions = Get-NmeScriptedActions |
        Where-Object { $_.ExecutionEnvironment -eq "CustomScript" }

    Write-Host "Found $($actions.Count) CustomScript actions" -ForegroundColor Cyan

    $actions | ConvertTo-Json -Depth 10 |
        Out-File "$backupFolder\all-scripted-actions.json" -Encoding UTF8

    foreach ($action in $actions) {
        $safeName = $action.Name -replace '[^\w\s-]', '_'
        $action.Script | Out-File "$backupFolder\$safeName.ps1" -Encoding UTF8
        Write-Host "  Exported: $safeName.ps1" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Scripted actions backup complete: $backupFolder" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
}

# ============================================================
# RESTORE SCRIPTED ACTIONS
# ============================================================
function Restore-NmeScriptedActions {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BackupFile
    )

    $actions       = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $existing      = Get-NmeScriptedActions
    $existingNames = $existing | Select-Object -ExpandProperty Name

    $restored = 0
    $skipped  = 0
    $failed   = 0

    foreach ($action in $actions) {

        if ($existingNames -contains $action.Name) {
            Write-Host "  Skipping (exists): $($action.Name)" -ForegroundColor Yellow
            $skipped++
            continue
        }

        try {
            $request = New-NmeCreateScriptedActionRequest `
                -Name                 $action.Name `
                -Script               $action.Script `
                -ExecutionMode        $action.ExecutionMode `
                -ExecutionEnvironment $action.ExecutionEnvironment `
                -Tags                 $action.Tags `
                -Description          $action.Description

            New-NmeScriptedActions -NmeCreateScriptedActionRequest $request

            Write-Host "  Restored: $($action.Name)" -ForegroundColor Green
            $restored++
        }
        catch {
            Write-Host "  FAILED: $($action.Name) - $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Scripted actions restore summary" -ForegroundColor Cyan
    Write-Host "  Restored : $restored" -ForegroundColor Green
    Write-Host "  Skipped  : $skipped"  -ForegroundColor Yellow
    Write-Host "  Failed   : $failed"   -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Cyan
}

# ============================================================
# MAIN
# ============================================================
switch ($Action) {

    "Backup" {
        Backup-NmeHostPools
        Backup-NmeScriptedActions
    }

    "RestoreHostPool" {
        if (-not $BackupFile) { throw "Please provide -BackupFile" }
        Restore-NmeHostPool `
            -BackupFile           $BackupFile `
            -TargetSubscriptionId $TargetSubscriptionId `
            -TargetResourceGroup  $TargetResourceGroup `
            -TargetHostPoolName   $TargetHostPoolName `
            -TargetWorkspaceId    $TargetWorkspaceId
    }

    "RestoreAllHostPools" {
        if (-not $BackupFolder) { throw "Please provide -BackupFolder" }
        Restore-NmeAllHostPools -BackupFolder $BackupFolder
    }

    "BackupScriptedActions" {
        Backup-NmeScriptedActions
    }

    "RestoreScriptedActions" {
        if (-not $BackupFile) { throw "Please provide -BackupFile" }
        Restore-NmeScriptedActions -BackupFile $BackupFile
    }
}
