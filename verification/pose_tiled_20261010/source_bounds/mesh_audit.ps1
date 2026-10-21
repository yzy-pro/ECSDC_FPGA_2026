$ErrorActionPreference='Stop'
$auditOldWriter=[Console]::Out
$auditWriter=New-Object System.IO.StringWriter
Add-Type -Path (Join-Path $PSScriptRoot 'MeshAudit.cs')
try {
    [Console]::SetOut($auditWriter)
    [MeshAudit]::Run()
    $auditWriter.ToString() | Set-Content -Encoding UTF8 (Join-Path $PSScriptRoot 'mesh_error_samples.csv')
} finally {
    [Console]::SetOut($auditOldWriter)
    $auditWriter.Dispose()
}
Import-Csv (Join-Path $PSScriptRoot 'mesh_error_samples.csv') |
    Where-Object {$_.grid_step -eq '16' -or $_.grid_step -eq '32'} |
    Select-Object yaw_q2048,pitch_q2048,grid_step,rms_coordinate_error_px,p99_coordinate_error_px,max_coordinate_error_px,fallback_pixels,false_valid_interior_pixels,valid_pixels_with_all_invalid_corners |
    Format-Table -AutoSize
