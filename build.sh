#!/bin/bash
set -e

echo "=== Compiling shaders ==="
glslc shaders/slug.vert -o shaders/slug_vert.spv
glslc shaders/slug.frag -o shaders/slug_frag.spv
echo "Shaders compiled."

echo "=== Building slugvibes ==="
odin build . -out:slugvibes -debug
echo "Build complete: ./slugvibes"
