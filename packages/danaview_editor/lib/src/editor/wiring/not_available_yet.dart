// OWNER: UX-01
//
// The "not available yet" surface shown by D-33 placeholder widgets until their owner ticket lands.
// It fits any constraints (one ellipsized line when space is short, never an overflow error) and
// uses Figtree, so screens composed of placeholders pass the overflow matrix and the owner UI rules.

import 'package:flutter/widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// A neutral region labelled "[label] · not available yet".
///
/// See ARCH §4.6 (placeholder rule, D-33).
class EditorNotAvailableYet extends StatelessWidget {
  /// Creates the placeholder surface for the region or panel named [label], owned by [owner].
  const EditorNotAvailableYet({super.key, required this.label, required this.owner});

  /// Visible name of the region or panel ("Timeline", "Transform panel").
  final String label;

  /// The owner ticket ("UX-12"); exposed for tests and debugging only, never shown.
  final String owner;

  /// The text shown.
  String get message => '$label · not available yet';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: message,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final roomy = constraints.maxHeight >= 72 && constraints.maxWidth >= 160;
          return ClipRect(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(roomy ? DanaviewSpacing.md : DanaviewSpacing.xs),
                child: Text(
                  message,
                  maxLines: roomy ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
