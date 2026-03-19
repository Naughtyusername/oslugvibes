@echo off
setlocal

echo === Compiling shaders ===
glslc shaders\slug.vert -o shaders\slug_vert.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
glslc shaders\slug.frag -o shaders\slug_frag.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo Shaders compiled.

echo === Building slugvibes ===
odin build . -out:slugvibes.exe -debug
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo Build complete: slugvibes.exe
