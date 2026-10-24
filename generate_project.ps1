[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $ProjectRoot 'test.pds'
$OutputPath = Join-Path $ProjectRoot 'EmbFPGA.pds'

$ApplicationFiles = @(
    'src/top/hdmi_ddr3_top.v'
    'src/control/uart_tx.v'
    'src/control/cdc_snapshot.v'
    'src/control/video_control_cdc.v'
    'src/control/gamma_telemetry.v'
    'src/control/cp2102_control.v'
    'src/imu/imu_uart_rx_50m.v'
    'src/imu/imu_protocol_50m.v'
    'src/imu/attitude_cdc.v'
    'src/imu/imu_affine_q14.v'
    'src/video/pose/pose_frame_bank_allocator.v'
    'src/video/preprocess/adaptive_preprocess_stream.v'
    'src/video/preprocess/adaptive_gamma_stream.v'
    'src/video/preprocess/adaptive_gamma_lut.v'
    'src/video/pose/pose_tile_read_scheduler.v'
    'src/video/pose/pose_inverse_project_q14.v'
    'src/video/pose/pose_reciprocal_lut.v'
    'src/video/pose/pose_renderer_dma.v'
    'src/video/pose/pose_renderer_tiled.v'
    'src/video/pose/pose_ddr_arbiter.v'
    'src/video/pose/pose_async_fifo.v'
    'src/video/pose/fram_buf_pose.v'
    'src/board/iic_dir.v'
    'src/board/ms72xx_ctl.v'
    'src/board/ms7200_ctl.v'
    'src/board/ms7210_ctl.v'
    'src/video/undistort/fram_buf_undistort.v'
    'src/video/frame_buffer/fram_buf_linear.v'
    'src/video/undistort/undistort_rd_buf.v'
    'src/video/undistort/undistort_band_cache.v'
    'src/video/undistort/undistort_band_tables.v'
    'src/video/frame_buffer/rd_buf.v'
    'src/video/frame_buffer/wr_buf.v'
    'src/video/frame_buffer/wr_cmd_trans.v'
    'src/video/frame_buffer/wr_rd_ctrl_top.v'
    'src/video/frame_buffer/wr_ctrl.v'
    'src/video/frame_buffer/rd_ctrl.v'
    'src/video/timing/sync_vg.v'
    'src/video/format/rgb888_to_rgb565.v'
    'src/video/format/rgb565_to_rgb888.v'
    'src/video/preprocess/gamma_correct_rgb888.v'
    'src/video/timing/video_raster_delay.v'
)

$DdrRoot = Join-Path $ProjectRoot 'ipcore/DDR3_50H'
$DdrFiles = Get-ChildItem (Join-Path $DdrRoot 'rtl') -Recurse -File |
    Where-Object { $_.Extension -in '.v', '.vp' } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName.Substring($ProjectRoot.Length + 1).Replace('\', '/') }

$DesignFiles = @($ApplicationFiles) + @($DdrFiles) + @(
    'ipcore/DDR3_50H/DDR3_50H.v'
    'ipcore/DDR3_50H/DDR3_50H_ddrphy_top.v'
)

foreach ($RelativePath in $DesignFiles + @('src/constraints/hdmi_ddr3_top.fdc')) {
    $AbsolutePath = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $AbsolutePath -PathType Leaf)) {
        throw "Required project file is missing: $RelativePath"
    }
}

$Entries = foreach ($RelativePath in $DesignFiles) {
    $TopMarker = if ($RelativePath -eq 'src/top/hdmi_ddr3_top.v') { ' + "hdmi_ddr3_top"' } else { '' }
    $Timestamp = (Get-Item -LiteralPath (Join-Path $ProjectRoot $RelativePath)).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
    @"
                (_file "$RelativePath"$TopMarker
                    (_format verilog)
                    (_timespec "$Timestamp")
                )
"@
}

$DesignBlock = @"
        (_widget wgt_my_design_src
            (_input
$($Entries -join "`n")
            )
        )
"@

$ConstraintTimestamp = (Get-Item -LiteralPath (Join-Path $ProjectRoot 'src/constraints/hdmi_ddr3_top.fdc')).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
$ConstraintBlock = @"
        (_widget wgt_import_logic_con_file
            (_input
                (_file "src/constraints/hdmi_ddr3_top.fdc"
                    (_format fdc)
                    (_timespec "$ConstraintTimestamp")
                )
            )
        )
"@

$Template = Get-Content -Raw -Encoding UTF8 -LiteralPath $TemplatePath
$DesignPattern = '(?ms)^        \(_widget wgt_my_design_src\r?\n        \)'
$ConstraintPattern = '(?ms)^        \(_widget wgt_import_logic_con_file\r?\n        \)'
$ProjectPattern = '(?ms)^    \(_project\s*.*?^    \)'

if ([regex]::Matches($Template, $DesignPattern).Count -ne 1) {
    throw 'The test.pds design-source placeholder was not found exactly once.'
}
if ([regex]::Matches($Template, $ConstraintPattern).Count -ne 1) {
    throw 'The test.pds constraint placeholder was not found exactly once.'
}

$Project = [regex]::Replace($Template, $DesignPattern, $DesignBlock)
$Project = [regex]::Replace($Project, $ConstraintPattern, $ConstraintBlock)
$Project = [regex]::Replace($Project, $ProjectPattern, "    (_project`r`n    )")
$Project = $Project.Replace('(_gci_state (_integer 4))', '(_gci_state (_integer 0))')
$Project = $Project.Replace(
    '(_option selected_syn_tool_opt (_integer 1))',
    "(_option ads (_switch ON))`r`n            (_option selected_syn_tool_opt (_integer 2))"
)
$Project = $Project.Replace(
    '(_command cmd_compile',
    "(_command cmd_compile`r`n            (_option top_module (_string `"hdmi_ddr3_top`"))"
)
# Match the PDS 2022 implementation options used for the verified adaptation.
$PnrOptions = @'
(_command cmd_pnr
            (_option optimize_multi_corner_timing (_switch ON))
            (_option fix_hold_violation (_switch ON))
            (_option optimize_gp_recovery (_switch ON))
            (_option optimize_dp_recovery (_switch ON))
            (_option optimize_rp_recovery (_switch ON))
'@
$Project = $Project.Replace('(_command cmd_pnr', $PnrOptions.TrimEnd())
# PDS omits skew checks from its text summary; retain every FIFO pointer bit
# in both corner XML reports for the mandatory build audit.
$SkewReportOptions = @'
(_command cmd_report_post_pnr_timing
            (_option report_max_skew (_switch ON))
            (_option max_path (_integer 64))
            (_option nworst (_integer 64))
'@
$Project = $Project.Replace('(_command cmd_report_post_pnr_timing', $SkewReportOptions.TrimEnd())
[System.IO.File]::WriteAllText($OutputPath, $Project, [System.Text.UTF8Encoding]::new($false))

Write-Host "Generated $OutputPath with $($DesignFiles.Count) Verilog files and one FDC constraint."


