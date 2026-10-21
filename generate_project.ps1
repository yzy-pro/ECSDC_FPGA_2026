[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $ProjectRoot 'test.pds'
$OutputPath = Join-Path $ProjectRoot 'EmbFPGA.pds'

$ApplicationFiles = @(
    'src/hdmi_ddr3_top.v'
    'src/imu/imu_uart_rx_50m.v'
    'src/imu/imu_protocol_50m.v'
    'src/imu/attitude_cdc.v'
    'src/imu/imu_affine_q14.v'
    'src/video/pose_frame_bank_allocator.v'
    'src/video/adaptive_preprocess_stream.v'
    'src/video/adaptive_gamma_stream.v'
    'src/video/adaptive_gamma_lut.v'
    'src/video/pose_tile_read_scheduler.v'
    'src/video/pose_inverse_project_q14.v'
    'src/video/pose_reciprocal_lut.v'
    'src/video/pose_renderer_dma.v'
    'src/video/pose_renderer_tiled.v'
    'src/video/pose_ddr_arbiter.v'
    'src/video/pose_async_fifo.v'
    'src/video/fram_buf_pose.v'
    'src/iic_dir.v'
    'src/ms72xx_ctl.v'
    'src/ms7200_ctl.v'
    'src/ms7210_ctl.v'
    'src/video/fram_buf_undistort.v'
    'src/video/fram_buf_linear.v'
    'src/video/undistort_rd_buf.v'
    'src/video/undistort_band_cache.v'
    'src/video/undistort_band_tables.v'
    'src/video/rd_buf.v'
    'src/video/wr_buf.v'
    'src/video/wr_cmd_trans.v'
    'src/video/wr_rd_ctrl_top.v'
    'src/video/wr_ctrl.v'
    'src/video/rd_ctrl.v'
    'src/video/sync_vg.v'
    'src/video/rgb888_to_rgb565.v'
    'src/video/rgb565_to_rgb888.v'
    'src/video/gamma_correct_rgb888.v'
    'src/video/video_raster_delay.v'
    'src/ip/video_pll/pll.v'
    'src/ip/wr_fram_buf/rtl/ipml_sdpram_v1_10_wr_fram_buf.v'
    'src/ip/wr_fram_buf/wr_fram_buf.v'
    'src/ip/rd_fram_buf/rtl/ipml_sdpram_v1_10_rd_fram_buf.v'
    'src/ip/rd_fram_buf/rd_fram_buf.v'
)

$DdrRoot = Join-Path $ProjectRoot 'DDR3_50H'
$DdrFiles = Get-ChildItem (Join-Path $DdrRoot 'rtl') -Recurse -File |
    Where-Object { $_.Extension -in '.v', '.vp' } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName.Substring($ProjectRoot.Length + 1).Replace('\', '/') }

$DesignFiles = @($ApplicationFiles) + @($DdrFiles) + @(
    'DDR3_50H/DDR3_50H.v'
    'DDR3_50H/DDR3_50H_ddrphy_top.v'
)

foreach ($RelativePath in $DesignFiles + @('src/hdmi_ddr3_top.fdc')) {
    $AbsolutePath = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $AbsolutePath -PathType Leaf)) {
        throw "Required project file is missing: $RelativePath"
    }
}

$Entries = foreach ($RelativePath in $DesignFiles) {
    $TopMarker = if ($RelativePath -eq 'src/hdmi_ddr3_top.v') { ' + "hdmi_ddr3_top"' } else { '' }
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

$ConstraintTimestamp = (Get-Item -LiteralPath (Join-Path $ProjectRoot 'src/hdmi_ddr3_top.fdc')).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
$ConstraintBlock = @"
        (_widget wgt_import_logic_con_file
            (_input
                (_file "src/hdmi_ddr3_top.fdc"
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


