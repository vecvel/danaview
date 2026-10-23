"""Host check that each converted ONNX model matches its TFLite source (VED-33A spike).
usage: python -I verify_onnx.py <models dir>   (prints max |diff| per output on 3 random inputs)
"""
import sys, os
import numpy as np, tensorflow as tf, onnxruntime as ort
d = sys.argv[1]
pairs = {
  "face_detector": "extracted/face_landmarker/face_detector.tflite",
  "face_landmarks_detector": "extracted/face_landmarker/face_landmarks_detector.tflite",
  "pose_detector": "extracted/pose_landmarker_full/pose_detector.tflite",
  "pose_landmarks_lite": "extracted/pose_landmarker_lite/pose_landmarks_detector.tflite",
  "pose_landmarks_full": "extracted/pose_landmarker_full/pose_landmarks_detector.tflite",
  "selfie_multiclass": "mediapipe/selfie_multiclass_256x256.tflite",
  "selfie_segmenter": "mediapipe/selfie_segmenter.tflite",
  "hair_segmenter": "mediapipe/hair_segmenter.tflite",
}
def noise(shape, k):  # numpy.random DLL is blocked by Application Control on this laptop
    n = int(np.prod(shape)); i = np.arange(n, dtype=np.float64)
    return (0.5 + 0.5 * np.sin(i * (12.9898 + k) + k * 78.233)).reshape(shape).astype(np.float32)
for name, tfl in pairs.items():
    it = tf.lite.Interpreter(model_path=os.path.join(d, tfl)); it.allocate_tensors()
    try:
        s = ort.InferenceSession(os.path.join(d, "onnx", name + ".onnx"), providers=["CPUExecutionProvider"])
    except Exception as e:  # MediaPipe custom ops (Convolution2DTransposeBias, MaxPoolingWithArgmax2D) stay TFL_* nodes
        print("RESULT", name, "NOT LOADABLE:", str(e).split("Error ")[-1][:90]); continue
    inp = it.get_input_details()[0]
    worst = {}
    for k in range(3):
        x = noise(inp["shape"], k)
        it.set_tensor(inp['index'], x); it.invoke()
        ref = {o['name']: it.get_tensor(o['index']) for o in it.get_output_details()}
        got = s.run(None, {s.get_inputs()[0].name: x})
        for o, g in zip(s.get_outputs(), got):
            r = ref.get(o.name)
            if r is None: r = [v for v in ref.values() if v.size == g.size][0]
            worst[o.name] = max(worst.get(o.name, 0), float(np.abs(r.reshape(-1) - g.reshape(-1)).max()))
    print("RESULT", name, {k: f"{v:.2e}" for k, v in worst.items()})
