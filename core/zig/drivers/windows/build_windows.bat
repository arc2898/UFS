@echo off
REM UFS Windows IFS Driver Build Script
REM Builds the driver, signs it, and creates installation package
REM Usage: build_windows.bat [debug|release] [clean|build|sign|package|all]

setlocal enabledelayedexpansion

set BUILD_TYPE=%1
if "%BUILD_TYPE%"=="" set BUILD_TYPE=release

set ACTION=%2
if "%ACTION%"=="" set ACTION=build

set SCRIPT_DIR=%~dp0
set ZIG_DIR=%SCRIPT_DIR%..\zig
set WDK_DIR=C:\Program Files (x86)\Windows Kits\10
set SDK_VERSION=10.0.22621.0

REM Colors (using ANSI if supported)
for /f %%a in ('echo prompt $E ^| cmd') do set ESC=%%a
set GREEN=%ESC%[0;32m
set YELLOW=%ESC%[1;33m
set RED=%ESC%[0;31m
set NC=%ESC%[0m

:log_info
echo %GREEN%[INFO]%NC% %1
goto :eof

:log_warn
echo %YELLOW%[WARN]%NC% %1
goto :eof

:log_error
echo %RED%[ERROR]%NC% %1
goto :eof

:build_zig_core
call :log_info Building Zig core library for Windows...
cd /d "%ZIG_DIR%"

if "%BUILD_TYPE%"=="debug" (
    zig build -Dtarget=x86_64-windows-gnu -Doptimize=Debug -Dstrip=false
) else (
    zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -Dstrip=true
)

set UFS_CORE_LIB=%ZIG_DIR%\zig-out\lib\libufs_core.lib
if not exist "%UFS_CORE_LIB%" (
    call :log_error Zig core library not found at %UFS_CORE_LIB%
    exit /b 1
)

copy "%UFS_CORE_LIB%" "%SCRIPT_DIR%\"

call :log_info Zig core library built: %UFS_CORE_LIB%
goto :eof

:build_driver
call :log_info Building UFS IFS driver...
cd /d "%SCRIPT_DIR%"

set MSBUILD="%ProgramFiles%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
if not exist "%MSBUILD%" set MSBUILD="%ProgramFiles(x86)%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
if not exist "%MSBUILD%" set MSBUILD=msbuild

set CONFIG=Release
if "%BUILD_TYPE%"=="debug" set CONFIG=Debug

"%MSBUILD%" UFS.vcxproj /p:Configuration=%CONFIG% /p:Platform=x64 /t:Build /v:minimal

if not exist "x64\%CONFIG%\ufs.sys" (
    call :log_error Driver not built
    exit /b 1
)

call :log_info Driver built: x64\%CONFIG%\ufs.sys
goto :eof

:sign_driver
call :log_info Signing driver...
REM Requires signtool and valid EV certificate
REM set SIGNTOOL="%WDK_DIR%\bin\%SDK_VERSION%\x64\signtool.exe"
REM %SIGNTOOL% sign /a /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /d "UFS Filesystem Driver" /du "https://ufs.example.com" "x64\%CONFIG%\ufs.sys"
REM %SIGNTOOL% sign /a /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 "x64\%CONFIG%\ufs.cat"
call :log_warn Signing skipped - configure certificate in script
goto :eof

:create_catalog
call :log_info Creating catalog file...
REM %SIGNTOOL% inf2cat /driver:x64\%CONFIG% /os:10_X64,10_ARM64,Server10_X64,Server10_ARM64
call :log_warn Catalog creation skipped - configure in script
goto :eof

:package_driver
call :log_info Creating driver installation package...
cd /d "%SCRIPT_DIR%"

set PKG_DIR=x64\%CONFIG%\Package
if exist "%PKG_DIR%" rmdir /s /q "%PKG_DIR%"
mkdir "%PKG_DIR%"

copy "x64\%CONFIG%\ufs.sys" "%PKG_DIR%\"
copy "ufs.inf" "%PKG_DIR%\"
if exist "x64\%CONFIG%\ufs.cat" copy "x64\%CONFIG%\ufs.cat" "%PKG_DIR%\"

REM Create DIFx installer
REM Requires dpinst.exe from WDK
call :log_info Driver package created at %PKG_DIR%
goto :eof

:clean_all
call :log_info Cleaning build artifacts...
cd /d "%SCRIPT_DIR%"
if exist "x64" rmdir /s /q "x64"
if exist "libufs_core.lib" del "libufs_core.lib"
call :log_info Clean complete
goto :eof

:main
call :log_info UFS Windows IFS Driver Build Script
call :log_info Build type: %BUILD_TYPE%
call :log_info Action: %ACTION%

if "%ACTION%"=="build" (
    call :build_zig_core
    call :build_driver
) else if "%ACTION%"=="sign" (
    call :sign_driver
    call :create_catalog
) else if "%ACTION%"=="package" (
    call :package_driver
) else if "%ACTION%"=="clean" (
    call :clean_all
) else if "%ACTION%"=="all" (
    call :build_zig_core
    call :build_driver
    call :sign_driver
    call :create_catalog
    call :package_driver
) else (
    call :log_error Unknown action: %ACTION%
    echo Usage: %0 [debug^|release] [build^|sign^|package^|clean^|all]
    exit /b 1
)

call :log_info Build completed successfully