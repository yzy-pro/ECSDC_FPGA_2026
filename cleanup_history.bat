@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
if not exist "%ROOT%EmbFPGA.pds" (
    echo ERROR: EmbFPGA.pds was not found beside this script.
    exit /b 1
)
if not exist "%ROOT%src\" (
    echo ERROR: src directory was not found beside this script.
    exit /b 1
)

echo Project: "%ROOT%"
echo This removes generated builds, old verification snapshots, old bitstreams,
echo backup PDS files, generated logs, and temporary work files.
echo It keeps EmbFPGA.pds, source files, the latest candidate bitstream,
echo final verification evidence, and EmbFPGA.pds.lock.
echo.
choice /C YN /N /M "Continue with cleanup? [Y/N] "
if errorlevel 2 exit /b 0

if exist "%ROOT%build_rebuilt\" rmdir /S /Q "%ROOT%build_rebuilt"

if exist "%ROOT%verification\" (
    for /D %%D in ("%ROOT%verification\*") do (
        if /I not "%%~nxD"=="pose_tiled_20261010" if /I not "%%~nxD"=="pds_pose_adaptive_128x64_bounds_pipe_20261010" (
            rmdir /S /Q "%%~fD"
        )
    )
)

if exist "%ROOT%bitstream\" (
    for %%F in ("%ROOT%bitstream\*") do if exist "%%~fF" (
        if /I not "%%~nxF"=="EmbFPGA_1920_pose15_tiled_gamma_20261010_candidate.sbit" if /I not "%%~nxF"=="pose15_tiled_gamma_20261010_identity.json" if /I not "%%~nxF"=="SHA256_20261010_pose15_tiled_gamma.txt" (
            del /F /Q "%%~fF"
        )
    )
)

for %%F in ("%ROOT%EmbFPGA.backup_*.pds") do if exist "%%~fF" del /F /Q "%%~fF"
for %%N in (pose_tiled_synthesize.pds test.pds compile_capture.log flow.log run.log sources_info.log stderr.log stdout.log synth_capture.log transcript pds.log) do (
    if exist "%ROOT%%%N" del /F /Q "%ROOT%%%N"
)

for %%D in (log logbackup work build_imu\work) do if exist "%ROOT%%%D\" (
    for /D %%S in ("%ROOT%%%D\*") do if exist "%%~fS" rmdir /S /Q "%%~fS"
    del /F /Q "%ROOT%%%D\*" 2>nul
)

echo Cleanup complete. EmbFPGA.pds.lock was not modified.
exit /b 0
