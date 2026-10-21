param([int]$PoseStep=16,[int]$PixelStep=8)
$ErrorActionPreference='Stop'
$auditRoot=$PSScriptRoot
$repoRoot=(Resolve-Path (Join-Path $auditRoot '../../..')).Path
Add-Type -Path (Join-Path $auditRoot 'CapacityAudit.cs')
# Redirect Console.Out to capture the C# audit verbatim, without changing RTL.
$auditOldWriter=[Console]::Out
$auditWriter=New-Object System.IO.StringWriter
try {
    [Console]::SetOut($auditWriter)
    [CapacityAudit]::Sweep()
    $auditWriter.ToString() | Set-Content -Encoding UTF8 (Join-Path $auditRoot 'sampled_49_poses.csv')
    $auditWriter.GetStringBuilder().Clear() | Out-Null
    try {[CapacityAudit]::Bound($PoseStep,$PixelStep)}
    finally {$auditWriter.ToString() | Set-Content -Encoding UTF8 (Join-Path $auditRoot 'conservative_bound.txt')}
} finally {
    [Console]::SetOut($auditOldWriter)
    $auditWriter.Dispose()
}
$auditFiles=@('src/video/pose_inverse_project_q14.v','src/video/pose_renderer_tiled.v',
    'verification/pose_tiled_20261010/source_bounds/CapacityAudit.cs')
$auditHashes=@{}
foreach($auditFile in $auditFiles){$auditHashes[$auditFile]=(Get-FileHash -Algorithm SHA256 (Join-Path $repoRoot $auditFile)).Hash}
$auditHashes | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $auditRoot 'input_sha256.json')
Get-Content (Join-Path $auditRoot 'conservative_bound.txt')
