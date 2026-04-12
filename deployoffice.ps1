#Detection Script

$basePaths = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)}
)

$programFolderName = "Microsoft Office\root\Office16"
$programFileName = "WINWORD.EXE"

foreach ($basePath in $basePaths) {
    if ([string]::IsNullOrWhiteSpace($basePath)) {
        continue
    }

    $programFolderFullPath = Join-Path $basePath $programFolderName
    $programFolderExists = Test-Path $programFolderFullPath

    if (!$programFolderExists) {
        continue
    }

    $programFileFullPath = Join-Path $programFolderFullPath $programFileName

    if (Test-Path $programFileFullPath) {
        return $true
    }
}

return $false

#Install Script

$ErrorActionPreference = 'Stop'

$WorkingPath = "C:\ProgramData\Nerdio\ShellApps\Office"
$OdtExePath  = Join-Path $WorkingPath "officedeploymenttool_19725-20126.exe"
$ExtractPath = Join-Path $WorkingPath "ODT"
$SetupExe    = Join-Path $ExtractPath "setup.exe"
$ConfigXml   = Join-Path $WorkingPath "Install-Office.xml"
$LogPath     = Join-Path $WorkingPath "Install.log"
$DetailsUrl  = "https://www.microsoft.com/en-us/download/details.aspx?id=49117"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $Message"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

function Get-OdtDownload {
    param(
        [string]$DownloadPageUrl,
        [string]$DestinationPath
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Log "Reading Microsoft ODT download page: $DownloadPageUrl"
    $page = Invoke-WebRequest -Uri $DownloadPageUrl -UseBasicParsing

    $downloadLink = ($page.Links | Where-Object {
        $_.href -match 'officedeploymenttool_19725-20126\.exe'
    } | Select-Object -First 1 -ExpandProperty href)

    if (-not $downloadLink) {
        throw "Could not find direct ODT EXE link on Microsoft page."
    }

    if ($downloadLink -notmatch '^https?://') {
        $downloadLink = [System.Uri]::new([System.Uri]$DownloadPageUrl, $downloadLink).AbsoluteUri
    }

    Write-Log "Downloading ODT from: $downloadLink"
    Invoke-WebRequest -Uri $downloadLink -OutFile $DestinationPath -UseBasicParsing

    if (-not (Test-Path $DestinationPath)) {
        throw "ODT download failed."
    }

    $file = Get-Item $DestinationPath
    Write-Log "Downloaded ODT size: $($file.Length) bytes"

    if ($file.Length -lt 1000000) {
        throw "Downloaded file is too small to be a valid ODT EXE. Size: $($file.Length)"
    }
}

New-Item -Path $WorkingPath -ItemType Directory -Force | Out-Null
New-Item -Path $ExtractPath -ItemType Directory -Force | Out-Null

Write-Log "Starting Microsoft 365 Apps install."

$ClickToRun = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue
$WordPath64 = "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE"
$WordPath32 = "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE"

if ($ClickToRun -and ((Test-Path $WordPath64) -or (Test-Path $WordPath32))) {
    Write-Log "Office already installed. Exiting."
    exit 0
}

if (-not (Test-Path $OdtExePath)) {
    Write-Log "ODT not found locally. Downloading latest tested EXE."
    Get-OdtDownload -DownloadPageUrl $DetailsUrl -DestinationPath $OdtExePath
}
else {
    $existingFile = Get-Item $OdtExePath
    Write-Log "Using existing ODT file: $OdtExePath ($($existingFile.Length) bytes)"
}

Write-Log "Extracting Office Deployment Tool."
$ExtractArgs = "/quiet /extract:`"$ExtractPath`""
$ExtractProc = Start-Process -FilePath $OdtExePath -ArgumentList $ExtractArgs -Wait -PassThru -NoNewWindow

if ($ExtractProc.ExitCode -ne 0) {
    Write-Log "ODT extraction failed with exit code $($ExtractProc.ExitCode)"
    exit $ExtractProc.ExitCode
}

if (-not (Test-Path $SetupExe)) {
    Write-Log "setup.exe not found after extraction."
    exit 1
}

$Xml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="1" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Property Name="PinIconsToTaskbar" Value="FALSE" />
  <RemoveMSI />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@

Set-Content -Path $ConfigXml -Value $Xml -Encoding UTF8
Write-Log "Created Office configuration XML."

Write-Log "Starting Office install."
$InstallArgs = "/configure `"$ConfigXml`""
$InstallProc = Start-Process -FilePath $SetupExe -ArgumentList $InstallArgs -Wait -PassThru -NoNewWindow

Write-Log "Office installer exited with code $($InstallProc.ExitCode)"

Start-Sleep -Seconds 15

$ClickToRunPost = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue
if ($ClickToRunPost -and ((Test-Path $WordPath64) -or (Test-Path $WordPath32))) {
    Write-Log "Microsoft 365 Apps installed successfully."
    exit 0
}

Write-Log "Office install validation failed."
exit 1

#Uninstall Script
$ErrorActionPreference = 'Stop'

$WorkingPath = "C:\ProgramData\Nerdio\ShellApps\Office"
$OdtExePath  = Join-Path $WorkingPath "officedeploymenttool.exe"
$ExtractPath = Join-Path $WorkingPath "ODT"
$SetupExe    = Join-Path $ExtractPath "setup.exe"
$ConfigXml   = Join-Path $WorkingPath "Uninstall-Office.xml"
$LogPath     = Join-Path $WorkingPath "Uninstall.log"

$OdtDownloadUrl = "https://go.microsoft.com/fwlink/?linkid=2086640"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $Message"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

New-Item -Path $WorkingPath -ItemType Directory -Force | Out-Null
New-Item -Path $ExtractPath -ItemType Directory -Force | Out-Null

Write-Log "Starting Microsoft 365 Apps uninstall."

$ClickToRun = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue
if (-not $ClickToRun) {
    Write-Log "Office not installed. Exiting."
    exit 0
}

if (-not (Test-Path $OdtExePath)) {
    Write-Log "ODT not found locally. Downloading."
    Invoke-WebRequest -Uri $OdtDownloadUrl -OutFile $OdtExePath -UseBasicParsing
}

Write-Log "Extracting Office Deployment Tool."
$ExtractArgs = "/quiet /extract:`"$ExtractPath`""
$ExtractProc = Start-Process -FilePath $OdtExePath -ArgumentList $ExtractArgs -Wait -PassThru -NoNewWindow

if ($ExtractProc.ExitCode -ne 0) {
    Write-Log "ODT extraction failed with exit code $($ExtractProc.ExitCode)"
    exit $ExtractProc.ExitCode
}

if (-not (Test-Path $SetupExe)) {
    Write-Log "setup.exe not found after extraction."
    exit 1
}

$Xml = @"
<Configuration>
  <Remove All="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@

Set-Content -Path $ConfigXml -Value $Xml -Encoding UTF8
Write-Log "Created uninstall XML."

Write-Log "Starting Office uninstall."
$UninstallArgs = "/configure `"$ConfigXml`""
$UninstallProc = Start-Process -FilePath $SetupExe -ArgumentList $UninstallArgs -Wait -PassThru -NoNewWindow

Write-Log "Office uninstall exited with code $($UninstallProc.ExitCode)"

Start-Sleep -Seconds 10

$WordPath64 = "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE"
$WordPath32 = "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE"
$ClickToRunPost = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue

if ((-not $ClickToRunPost) -and (-not (Test-Path $WordPath64)) -and (-not (Test-Path $WordPath32))) {
    Write-Log "Microsoft 365 Apps uninstalled successfully."
    exit 0
}

Write-Log "Office uninstall validation failed."
exit 1
