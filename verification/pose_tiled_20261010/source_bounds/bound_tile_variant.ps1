param([int]$TileWidth=256,[int]$TileHeight=32,[int]$PoseStep=8,[int]$PixelStep=4)
$ErrorActionPreference='Stop'
$auditSource=Get-Content -Raw (Join-Path $PSScriptRoot 'CapacityAudit.cs')
$auditSource=$auditSource.Replace('CapacityAudit','CapacityVariant').Replace('TW=128,TH=32',('TW={0},TH={1}' -f $TileWidth,$TileHeight)).Replace('128x32',('{0}x{1}' -f $TileWidth,$TileHeight)).Replace('bx<tx+TW','bx<Math.Min(W,tx+TW)').Replace('X[Math.Min(tx+TW-1,bx+pixelStep-1)]','X[Math.Min(W-1,Math.Min(tx+TW-1,bx+pixelStep-1))]')
Add-Type -TypeDefinition $auditSource
$auditOldWriter=[Console]::Out
$auditWriter=New-Object System.IO.StringWriter
try {
    [Console]::SetOut($auditWriter)
    [CapacityVariant]::Bound($PoseStep,$PixelStep)
} finally {
    [Console]::SetOut($auditOldWriter)
    $auditOutput=Join-Path $PSScriptRoot ('conservative_bound_{0}x{1}.txt' -f $TileWidth,$TileHeight)
    $auditWriter.ToString() | Set-Content -Encoding UTF8 $auditOutput
    $auditWriter.Dispose()
    Get-Content $auditOutput
}
