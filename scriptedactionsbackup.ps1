# ============================================================
# Nerdio Scripted Actions - Backup (CustomScript only)
# ============================================================

$timestamp    = Get-Date -Format "yyyy-MM-dd_HH-mm"
$backupFolder = "C:\backups\scripted-actions\$timestamp"
New-Item -ItemType Directory -Force -Path $backupFolder | Out-Null

# Get CustomScript actions only
$actions = Get-NmeScriptedActions | 
    Where-Object { $_.ExecutionEnvironment -eq "CustomScript" }

Write-Host "Found $($actions.Count) CustomScript scripted actions" -ForegroundColor Cyan

# Save full JSON for restore
$actions | ConvertTo-Json -Depth 10 | 
    Out-File "$backupFolder\all-scripted-actions.json" -Encoding UTF8

# Save each as individual .ps1
foreach ($action in $actions) {
    $safeName = $action.Name -replace '[^\w\s-]', '_'
    $action.Script | Out-File "$backupFolder\$safeName.ps1" -Encoding UTF8
    Write-Host "  Exported: $safeName.ps1" -ForegroundColor Green
}

Write-Host "Backup complete: $backupFolder" -ForegroundColor Green
