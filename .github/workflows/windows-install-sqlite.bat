@echo off
REM ci.yml originally called this before V was built, when neither `v` nor
REM `v.exe` existed yet, so the script could not delegate to V's own
REM downloader. It is now run after "Build V" and shells out to the
REM installer V ships, which verifies both the size and the SHA3 of the
REM amalgamation instead of trusting a pinned checksum maintained by hand.
.\v.exe run vlib\db\sqlite\install_thirdparty_sqlite.vsh
if errorlevel 1 exit /b 1
dir thirdparty\sqlite\
