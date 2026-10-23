"""Print each TFLite / ONNX model's inputs, outputs and op set (VED-33A spike, host only)."""
import sys
for p in sys.argv[1:]:
    print("==", p)
    if p.endswith(".onnx"):
        import onnx
        m = onnx.load(p)
        for i in m.graph.input: print("  in ", i.name, [d.dim_value for d in i.type.tensor_type.shape.dim])
        for o in m.graph.output: print("  out", o.name, [d.dim_value for d in o.type.tensor_type.shape.dim])
        print("  ops", sorted({n.op_type for n in m.graph.node}), "opset", [o.version for o in m.opset_import])
        continue
    import tensorflow as tf
    it = tf.lite.Interpreter(model_path=p)
    it.allocate_tensors()
    for d in it.get_input_details(): print("  in ", d['name'], d['shape'], d['dtype'].__name__)
    for d in it.get_output_details(): print("  out", d['name'], d['shape'], d['dtype'].__name__)
    ops = sorted({o['op_name'] for o in it._get_ops_details()})
    print("  ops", ops)
