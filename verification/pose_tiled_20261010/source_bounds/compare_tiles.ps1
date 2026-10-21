$ErrorActionPreference='Stop'
$auditRoot=$PSScriptRoot
$auditSource=Get-Content -Raw (Join-Path $auditRoot 'CapacityAudit.cs')
$auditOldWriter=[Console]::Out
$auditWriter=New-Object System.IO.StringWriter
try {
    [Console]::SetOut($auditWriter)
    foreach($auditSize in @(@(128,16),@(128,32),@(128,64),@(64,64),@(256,16),@(256,32))) {
        $auditClass='CapacityAudit'+$auditSize[0]+'x'+$auditSize[1]
        $auditCode=$auditSource.Replace('CapacityAudit',$auditClass).Replace('TW=128,TH=32','TW='+$auditSize[0]+',TH='+$auditSize[1]).Replace('x<x0+TW','x<Math.Min(W,x0+TW)')
        Add-Type -TypeDefinition $auditCode
        $auditType=([System.Management.Automation.PSTypeName]$auditClass).Type
        [Console]::WriteLine(('tile_width={0} tile_height={1}' -f $auditSize[0],$auditSize[1]))
        $auditType.GetMethod('Sweep').Invoke($null,@()) | Out-Null
    }
    $auditWriter.ToString() | Set-Content -Encoding UTF8 (Join-Path $auditRoot 'tile_comparison.txt')
} finally {
    [Console]::SetOut($auditOldWriter)
    $auditWriter.Dispose()
}
Get-Content (Join-Path $auditRoot 'tile_comparison.txt')
