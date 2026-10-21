[CmdletBinding()]
param(
    [ValidateSet('compile', 'synthesize', 'dev_map', 'pnr', 'report_timing', 'gen_bit_stream', 'full')]
    [string]$Run = 'report_timing',
    [string]$PdsShell = 'D:\pango\PDS_2025.2-ads\bin\pds_shell.exe',
    [string]$PythonExe = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Generator = Join-Path $ProjectRoot 'generate_project.ps1'
$ProjectFile = Join-Path $ProjectRoot 'EmbFPGA.pds'
if (-not $PythonExe) {
    $ReferencePython = Join-Path $ProjectRoot 'reference\imu_cboard\.venv\Scripts\python.exe'
    $PythonExe = if (Test-Path -LiteralPath $ReferencePython) { $ReferencePython } else { 'python' }
}

& $Generator

& $PythonExe (Join-Path $ProjectRoot 'tools\generate_undistort_cache.py')
if ($LASTEXITCODE -ne 0) {throw 'Calibration/cache schedule check failed.'}
& $PythonExe (Join-Path $ProjectRoot 'tests\verify_main_contract.py')
if ($LASTEXITCODE -ne 0) {throw 'Local project source check failed.'}

if (-not (Test-Path -LiteralPath $PdsShell -PathType Leaf)) {
    throw "PDS shell was not found: $PdsShell"
}

Push-Location $ProjectRoot
try {
    $RunDirectory = Join-Path $ProjectRoot ('verification\pds_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $RunDirectory | Out-Null
    $IdentityFile = Join-Path $RunDirectory 'source_identity.json'
    & $PythonExe (Join-Path $ProjectRoot 'tools\build_identity.py') $IdentityFile
    if ($LASTEXITCODE -ne 0) {throw 'Failed to record local source identity.'}
    Write-Host "Building actual project: $ProjectFile"
    Write-Host "Verification directory: $RunDirectory"
    # PDS 2022.2 runs timing, power, and netlist generation on the path to
    # gen_bit_stream, so the full flow needs only this target action.
    $Actions = if ($Run -eq 'full') { @('gen_bit_stream') } else { @($Run) }
    foreach ($Action in $Actions) {
        $Started = [DateTime]::UtcNow
        $LogFile = Join-Path $RunDirectory ($Action + '.log')
        & $PdsShell -project $ProjectFile -run $Action -work_dir $ProjectRoot *> $LogFile
        $PdsExit = $LASTEXITCODE
        if ($PdsExit -ne 0 -or (Select-String -LiteralPath $LogFile -Pattern '^E:' -Quiet)) {
            Get-Content -LiteralPath $LogFile -Tail 40
            throw "PDS action $Action failed (exit $PdsExit). See $LogFile"
        }
    }

    & $PythonExe (Join-Path $ProjectRoot 'tools\build_identity.py') $IdentityFile --check
    if ($LASTEXITCODE -ne 0) {throw 'Local sources changed during PDS execution.'}
    if ($Run -in @('report_timing', 'gen_bit_stream', 'full')) {
        $TimingReport = Join-Path $ProjectRoot 'prj_tasks\pnr_1\report_timing\hdmi_ddr3_top.rtr'
        if (-not (Test-Path -LiteralPath $TimingReport)) {
            $TimingReport = Join-Path $ProjectRoot 'report_timing\hdmi_ddr3_top.rtr'
        }
        if (-not (Test-Path -LiteralPath $TimingReport -PathType Leaf)) {
            throw "PDS did not produce the expected timing report: $TimingReport"
        }
        if ((Get-Item -LiteralPath $TimingReport).LastWriteTimeUtc -lt $Started) {
            throw 'Timing report is stale; the current run did not generate it.'
        }
        if (-not (Select-String -LiteralPath $TimingReport -Pattern 'Design Summary\s*:\s*All Constraints Met' -Quiet)) {
            throw 'Implementation completed, but timing constraints were violated. Do not program the generated bitstream.'
        }
        Copy-Item -LiteralPath $TimingReport -Destination (Join-Path $RunDirectory 'hdmi_ddr3_top.rtr')
        # PDS can leave the text summary green even when max-skew fails.
        # The active pose path must cover all 40 Gray-pointer destination bits
        # and satisfy the separate XML skew report in both operating corners.
        $PoseTimingDb = Join-Path (Split-Path -Parent $TimingReport) 'report_db'
        $PoseSkewReports = @('report_timing_slow_path_max_skew.db', 'report_timing_fast_path_max_skew.db')
        foreach ($PoseSkewName in $PoseSkewReports) {
            $PoseSkewPath = Join-Path $PoseTimingDb $PoseSkewName
            if (-not (Test-Path -LiteralPath $PoseSkewPath) -or
                (Get-Item -LiteralPath $PoseSkewPath).LastWriteTimeUtc -lt $Started) {
                throw "Missing or stale FIFO CDC skew report: $PoseSkewPath"
            }
            Copy-Item -LiteralPath $PoseSkewPath -Destination (Join-Path $RunDirectory $PoseSkewName)
        }
        & $PythonExe (Join-Path $ProjectRoot 'tools\audit_pose_fifo_cdc.py') $PoseTimingDb `
            --output (Join-Path $RunDirectory 'pose_fifo_cdc.json')
        if ($LASTEXITCODE -ne 0) {throw 'Routed FIFO Gray-pointer CDC checks failed.'}
        Write-Host "Local project timing passed: $TimingReport"
    }
    if ($Run -in @('gen_bit_stream', 'full')) {
        $Bitstream = Join-Path $ProjectRoot 'prj_tasks\pnr_1\generate_bitstream\hdmi_ddr3_top.sbit'
        if (-not (Test-Path -LiteralPath $Bitstream)) {
            $Bitstream = Join-Path $ProjectRoot 'generate_bitstream\hdmi_ddr3_top.sbit'
        }
        if (-not (Test-Path -LiteralPath $Bitstream) -or (Get-Item -LiteralPath $Bitstream).LastWriteTimeUtc -lt $Started) {
            throw 'No fresh bitstream was generated.'
        }
        Get-FileHash -LiteralPath $Bitstream -Algorithm SHA256 | Format-List
        Write-Host 'Candidate generated from test/EmbFPGA.pds; board validation is still required.'
    }
}
finally {
    Pop-Location
}
