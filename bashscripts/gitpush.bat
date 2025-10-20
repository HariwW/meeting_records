@echo off
setlocal enabledelayedexpansion

if "%~1"=="" (
    set /p comment=Enter commit message:
) else (
    set comment=%*
)

git diff --quiet
if %errorlevel%==0 (
    echo No changes detected. Push canceled.
    pause
    exit /b
)

echo.
echo Adding changes...
git add .

echo.
echo Committing: "!comment!"
git commit -m "!comment!"

echo.
echo Pushing to remote...
git push

if %errorlevel%==0 (
    echo Push successful: "!comment!"
) else (
    echo Push failed. Please check network or repo status.
)

pause
