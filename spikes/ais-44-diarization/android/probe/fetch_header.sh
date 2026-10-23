#!/usr/bin/env bash
# Fetch the sherpa-onnx C API header for the exact version the pub packages ship.
set -euo pipefail
cd "$(dirname "$0")/../.."
D=build/android/include/sherpa-onnx/c-api
mkdir -p $D
curl -sSfL -o $D/c-api.h https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h
echo "2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce  $D/c-api.h" | sha256sum -c
