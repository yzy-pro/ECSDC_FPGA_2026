$ErrorActionPreference='Stop'
$auditSource=Get-Content -Raw (Join-Path $PSScriptRoot 'CapacityAudit.cs')
$auditSource=$auditSource.Replace('CapacityAudit','CapacityAudit128x64Fine').Replace('TW=128,TH=32','TW=128,TH=64')
Add-Type -TypeDefinition $auditSource
$auditRows=New-Object 'System.Collections.Generic.List[string]'
$auditRows.Add('yaw_q2048,pitch_q2048,max_source_beats,tile_x,tile_y,bbox_words,bbox_rows,source_beats,source_commands,valid_pixels')
for($auditYaw=-256;$auditYaw -le 256;$auditYaw+=16){
    for($auditPitch=-64;$auditPitch -le 64;$auditPitch+=16){
        $auditRows.Add([CapacityAudit128x64Fine]::Frame($auditYaw,$auditPitch))
    }
}
$auditOutput=Join-Path $PSScriptRoot 'fine_128x64_297_poses.csv'
$auditRows | Set-Content -Encoding UTF8 $auditOutput
Import-Csv $auditOutput | Sort-Object {[int]$_.source_commands} -Descending |
    Select-Object -First 10 yaw_q2048,pitch_q2048,source_commands,source_beats,valid_pixels | Format-Table
