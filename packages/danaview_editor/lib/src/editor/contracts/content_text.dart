// OWNER: UX-01
//
// Marks user-content text regions (ARCH §1.3 rule 6, §17.8): text overlays and subtitles in the
// preview, and the font picker's previews, may use the content fonts; everything else is chrome and
// must resolve to Figtree. `expectOwnerUiRules` (test/support/) skips text below this widget.

import 'package:flutter/widgets.dart';

/// Wraps user-content text (preview text overlay, font previews) so the owner UI rules exempt it.
/// It has no visual effect.
///
/// See ARCH §1.3, §17.8.
class EditorContentTextRegion extends StatelessWidget {
  /// Creates the region.
  const EditorContentTextRegion({super.key, required this.child});

  /// The content.
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
