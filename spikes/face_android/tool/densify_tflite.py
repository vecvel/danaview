"""Rewrite a TFLite model so every DENSIFY op's output becomes a plain constant (VED-33A spike).

tf2onnx 1.17 cannot read sparse weights (pose_detector.tflite uses DENSIFY). The dense values are
taken from the TFLite interpreter itself, so the math is unchanged.
usage: python -I densify_tflite.py in.tflite out.tflite
"""
import sys
import numpy as np
import tensorflow as tf
from tensorflow.lite.tools import flatbuffer_utils as fu
from tensorflow.lite.python import schema_py_generated as schema

src, dst = sys.argv[1], sys.argv[2]
it = tf.lite.Interpreter(model_path=src, experimental_preserve_all_tensors=True,
                         experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
it.allocate_tensors()
inp = it.get_input_details()[0]
it.set_tensor(inp['index'], np.zeros(inp['shape'], np.float32))
it.invoke()
model = fu.read_model(src)
g = model.subgraphs[0]
dens = [i for i, c in enumerate(model.operatorCodes)
        if max(c.builtinCode, c.deprecatedBuiltinCode) == schema.BuiltinOperator.DENSIFY]
keep, n = [], 0
for op in g.operators:
    if op.opcodeIndex in dens:
        out = op.outputs[0]
        val = it.get_tensor(out)
        t = g.tensors[out]
        buf = schema.BufferT(); buf.data = np.frombuffer(val.tobytes(), np.uint8)
        model.buffers.append(buf); t.buffer = len(model.buffers) - 1
        t.sparsity = None
        sparse = g.tensors[op.inputs[0]]  # orphaned now: drop its data so no tool parses it
        sparse.buffer = 0; sparse.sparsity = None
        n += 1
        continue
    keep.append(op)
g.operators = keep
fu.write_model(model, dst)
print(f"densified {n} tensors -> {dst}")
