$ErrorActionPreference = "Stop"

Write-Host "=== Compiling shaders ==="
glslc shaders/slug.vert -o shaders/slug_vert.spv
glslc shaders/slug.frag -o shaders/slug_frag.spv
Write-Host "Shaders compiled."

Write-Host "=== Building slugvibes ==="
odin build . -out:slugvibes.exe -debug
Write-Host "Build complete: slugvibes.exe"
