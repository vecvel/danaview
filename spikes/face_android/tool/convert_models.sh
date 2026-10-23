#!/usr/bin/env bash
# VED-33A: build the model pack the bench pushes, outside the repo (never commit models).
#   tool/convert_models.sh [models dir, default /c/dev/models/face_runtime]
# Expects <dir>/mediapipe/ (downloaded .task/.tflite, SHA-256 in <dir>/SHA256SUMS) and a Python venv
# at <dir>/tools/venv with tensorflow-cpu, tf2onnx, onnx, onnxruntime (owner-approved downloads).
# Produces <dir>/pack/{*.task,*.tflite,tflite/,onnx/} and prints the host TFLite-vs-ONNX check.
set -euo pipefail
TOOL="$(cd "$(dirname "$0")" && pwd)"
D="${1:-/c/dev/models/face_runtime}"
PY="$D/tools/venv/Scripts/python.exe"
export TF_CPP_MIN_LOG_LEVEL=3 TF_ENABLE_ONEDNN_OPTS=0
cd "$D"
mkdir -p extracted onnx pack/tflite pack/onnx
for t in face_landmarker pose_landmarker_full pose_landmarker_lite; do
  mkdir -p "extracted/$t" && unzip -oq "mediapipe/$t.task" -d "extracted/$t"
done
# pose_detector uses DENSIFY (sparse weights) which tf2onnx 1.17 cannot read: densify it first.
"$PY" -I "$TOOL/densify_tflite.py" extracted/pose_landmarker_full/pose_detector.tflite onnx/pose_detector_dense.tflite
conv() { "$PY" -m tf2onnx.convert --tflite "$2" --output "onnx/$1.onnx" --opset 17 > "onnx/$1.log" 2>&1 || echo "convert $1 FAILED"; }
conv face_detector extracted/face_landmarker/face_detector.tflite
conv face_landmarks_detector extracted/face_landmarker/face_landmarks_detector.tflite
conv pose_detector onnx/pose_detector_dense.tflite
conv pose_landmarks_lite extracted/pose_landmarker_lite/pose_landmarks_detector.tflite
conv pose_landmarks_full extracted/pose_landmarker_full/pose_landmarks_detector.tflite
conv selfie_multiclass mediapipe/selfie_multiclass_256x256.tflite
# These two keep MediaPipe custom ops (Convolution2DTransposeBias, MaxPoolingWithArgmax2D/MaxUnpooling2D):
# they convert, but no stock ONNX Runtime can load them. Kept only to show that.
conv selfie_segmenter mediapipe/selfie_segmenter.tflite
conv hair_segmenter mediapipe/hair_segmenter.tflite
"$PY" -I "$TOOL/verify_onnx.py" . 2>&1 | grep -a -o "RESULT.*" | tee onnx/verify.txt
# The pack the bench pushes.
cp mediapipe/face_landmarker.task mediapipe/pose_landmarker_full.task mediapipe/pose_landmarker_lite.task \
   mediapipe/selfie_multiclass_256x256.tflite mediapipe/selfie_segmenter.tflite mediapipe/hair_segmenter.tflite pack/
cp extracted/face_landmarker/face_detector.tflite extracted/face_landmarker/face_landmarks_detector.tflite pack/tflite/
cp extracted/pose_landmarker_full/pose_detector.tflite pack/tflite/pose_detector.tflite
cp extracted/pose_landmarker_full/pose_landmarks_detector.tflite pack/tflite/pose_landmarks_full.tflite
cp extracted/pose_landmarker_lite/pose_landmarks_detector.tflite pack/tflite/pose_landmarks_lite.tflite
cp mediapipe/selfie_multiclass_256x256.tflite pack/tflite/selfie_multiclass.tflite
for m in face_detector face_landmarks_detector pose_detector pose_landmarks_full pose_landmarks_lite selfie_multiclass; do
  cp "onnx/$m.onnx" pack/onnx/
done
(cd pack && find . -type f | sort | xargs sha256sum && find . -type f | sort | xargs stat -c '%s %n') > pack.sums
cat pack.sums
