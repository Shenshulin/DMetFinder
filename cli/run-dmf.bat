@echo off
chcp 65001 >nul
rem ===========================================================
rem  DMetFinder CLI wrapper (Windows)
rem  Usage: cli\run-dmf.bat <command> [options]
rem  Example:
rem    cli\run-dmf.bat diff --a demo_data\groupA.xlsx
rem                       --b demo_data\groupB.xlsx --out out\run1
rem
rem  This file exists only to pin down the Windows environment traps
rem  so that neither a human nor an agent has to remember them:
rem    1. LOCALAPPDATA missing or POSIX-style -> R cannot find its
rem       user library ("there is no package called 'jsonlite'").
rem       Git Bash exports /c/Users/... which R cannot use, so the
rem       value is always rebuilt from USERPROFILE.
rem    2. LANG / LC_ALL left over -> cairo renders Chinese as garbage.
rem    3. Rscript path contains spaces.
rem
rem  Keep this file pure ASCII: cmd.exe parses .bat in the OEM code
rem  page, so non-ASCII comments split into bogus commands.
rem ===========================================================

rem ---- 0. restore the shell variables R depends on ----
rem Git Bash does not always pass these in Windows form, so put back the
rem defaults FIRST -- everything below uses them.
if not defined USERPROFILE set "USERPROFILE=%HOMEDRIVE%%HOMEPATH%"
if not defined ProgramFiles set "ProgramFiles=C:\Program Files"

rem ---- 1. rebuild LOCALAPPDATA in Windows form ----
set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"

rem ---- 2. clear locale vars that force R into ASCII native encoding ----
set "LANG="
set "LC_ALL="
set "LC_CTYPE="
set "LANGUAGE="

rem ---- 3. locate Rscript: PATH -> R_HOME -> usual install dirs ----
set "RSCRIPT="

rem Git Bash does not always pass ProgramFiles / USERPROFILE in Windows form,
rem so restore the defaults before using them.
if not defined ProgramFiles set "ProgramFiles=C:\Program Files"
if not defined USERPROFILE set "USERPROFILE=%HOMEDRIVE%%HOMEPATH%"

rem 3a. ask Windows (works even when PATH is POSIX-style, e.g. from Git Bash)
for /f "delims=" %%P in ('where Rscript.exe 2^>nul') do (
  if not defined RSCRIPT set "RSCRIPT=%%P"
)

rem 3b. R_HOME
if not defined RSCRIPT (
  if defined R_HOME if exist "%R_HOME%\bin\Rscript.exe" set "RSCRIPT=%R_HOME%\bin\Rscript.exe"
)

rem 3c. scan the usual install roots
if not defined RSCRIPT (
  if exist "%ProgramFiles%\R" (
    for /d %%D in ("%ProgramFiles%\R\R-*") do (
      if not defined RSCRIPT if exist "%%D\bin\Rscript.exe" set "RSCRIPT=%%D\bin\Rscript.exe"
    )
  )
)
if not defined RSCRIPT (
  if exist "%LOCALAPPDATA%\Programs\R" (
    for /d %%D in ("%LOCALAPPDATA%\Programs\R\R-*") do (
      if not defined RSCRIPT if exist "%%D\bin\Rscript.exe" set "RSCRIPT=%%D\bin\Rscript.exe"
    )
  )
)

if not defined RSCRIPT (
  echo [ERROR] Rscript.exe not found.
  echo         Install R, or add its bin directory to PATH, or set R_HOME.
  echo         ProgramFiles=%ProgramFiles%
  exit /b 3
)

"%RSCRIPT%" "%~dp0dmf.R" %*
exit /b %ERRORLEVEL%
