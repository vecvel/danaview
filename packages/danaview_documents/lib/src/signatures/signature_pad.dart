// OWNER: HOM-30
//
// The drawing pad of a new signature (HOM plan §8.5 "draw a signature"): a light "paper" panel with
// a baseline, where a finger, Apple Pencil or the pointer draws smooth strokes (quadratic curves
// through the touch points, round caps) in the chosen ink. The pad wins every drag that starts on
// it, so drawing never scrolls or dismisses the sheet. Screen readers hear "Signature drawing area"
// and how many strokes it holds. The strokes stay in memory until the sheet saves them.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'signature_image.dart';

/// The paper colour of the pad and the type previews.
const Color signaturePaperColor = Color(0xFFF6F5F2);

/// The strokes of a pad.
class SignaturePadController extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];

  /// The strokes, oldest first (each a list of pad points).
  List<List<Offset>> get strokes => List.unmodifiable(_strokes);

  /// Nothing drawn yet.
  bool get isEmpty => _strokes.every((s) => s.isEmpty);

  /// Starts a stroke at [p].
  void start(Offset p) {
    _strokes.add([p]);
    notifyListeners();
  }

  /// Extends the current stroke to [p] (points closer than half a pixel are skipped).
  void extend(Offset p) {
    if (_strokes.isEmpty) return start(p);
    final s = _strokes.last;
    if ((s.last - p).distanceSquared < 0.25) return;
    s.add(p);
    notifyListeners();
  }

  /// Removes the last stroke.
  void undo() {
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    notifyListeners();
  }

  /// Removes every stroke.
  void clear() {
    if (_strokes.isEmpty) return;
    _strokes.clear();
    notifyListeners();
  }
}

class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// The drawing pad.
class SignaturePad extends StatelessWidget {
  /// A pad drawing into [controller] in [color].
  const SignaturePad({super.key, required this.controller, required this.color, this.enabled = true});

  /// The strokes.
  final SignaturePadController controller;

  /// The ink.
  final Color color;

  /// False while saving.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final count = controller.strokes.where((s) => s.isNotEmpty).length;
        return Semantics(
          label: 'Signature drawing area',
          value: count == 0 ? 'Empty' : (count == 1 ? '1 stroke' : '$count strokes'),
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              if (enabled)
                _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
                  _EagerPan.new,
                  (r) {
                    r
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onStart = ((DragStartDetails d) => controller.start(d.localPosition))
                      ..onUpdate = ((DragUpdateDetails d) => controller.extend(d.localPosition));
                  },
                ),
            },
            child: DecoratedBox(
              decoration: const ShapeDecoration(
                color: signaturePaperColor,
                shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.controlAll, side: DanaviewBorders.hairline),
              ),
              child: ClipRRect(
                borderRadius: DanaviewRadius.controlAll,
                child: CustomPaint(
                  painter: _PadPainter(controller.strokes, color),
                  child: Stack(
                    children: [
                      if (count == 0)
                        const Center(
                          child: ExcludeSemantics(
                            child: Text('Sign here', style: TextStyle(fontSize: 15, color: Color(0xFF8A8A8E), decoration: TextDecoration.none)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.color);

  final List<List<Offset>> strokes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The baseline, a quarter up from the bottom.
    final y = size.height * 0.75;
    canvas.drawLine(Offset(DanaviewSpacing.lg, y), Offset(size.width - DanaviewSpacing.lg, y), Paint()
      ..color = const Color(0x33000000)
      ..strokeWidth = 1);
    final paint = signatureInkPaint(color, signatureStrokeWidth);
    for (final s in strokes) {
      if (s.isNotEmpty) canvas.drawPath(smoothStrokePath(s), paint);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}
