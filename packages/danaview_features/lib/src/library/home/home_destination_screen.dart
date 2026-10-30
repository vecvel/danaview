// The full screens of the Files & Media Home (DESIGN_SYSTEM §10.4): Projects, Playlists and
// Folders, pushed on the navigator by a section's "See all". Each is the library's pushed-screen
// chrome (the opaque top bar with Back, the title and the screen's actions) around the body the
// Home shell builds, with the selection bar slot under it, so the bodies keep every behaviour they
// had as tabs (menus, keyboard, semantics, keys).

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../library_widgets.dart';
import 'home_tabs.dart';

/// The key of the screen of [destination].
ValueKey<String> homeDestinationScreenKey(HomeDestination destination) => ValueKey('home-screen-${destination.name}');

/// One full screen of the Home.
class HomeDestinationScreen extends StatelessWidget {
  /// The screen of [destination] around [body]; [actions] sit at the end of the top bar.
  const HomeDestinationScreen({
    super.key,
    required this.destination,
    required this.body,
    this.actions = const [],
    this.selectionBar,
  });

  /// Which screen.
  final HomeDestination destination;

  /// The screen's scrolling body.
  final Widget body;

  /// The top bar's actions (New, Manage).
  final List<Widget> actions;

  /// The multi-select bar under the body (HOM-12), or null.
  final WidgetBuilder? selectionBar;

  @override
  Widget build(BuildContext context) {
    final bar = selectionBar;
    return Scaffold(
      backgroundColor: DanaviewColors.background,
      bottomNavigationBar: bar == null
          ? null
          : KeyedSubtree(key: const ValueKey('home-screen-selection-bar'), child: Builder(builder: bar)),
      body: DanaviewLibraryFrame(
        // Whole logical pixels tall, so the body starts on a pixel row and its rows rasterise
        // exactly as they do on the Home (no half-pixel antialiasing shift).
        topBar: _WholePixelHeight(
          child: DanaviewLibraryTopBar(
            key: ValueKey('home-screen-top-bar-${destination.name}'),
            title: destination.label,
            onBack: () => Navigator.of(context).maybePop(),
            actions: actions,
          ),
        ),
        body: body,
      ),
    );
  }
}

/// Lays [child] out and rounds its height up to a whole logical pixel (the child sits at the top).
class _WholePixelHeight extends SingleChildRenderObjectWidget {
  const _WholePixelHeight({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderWholePixelHeight();
}

class _RenderWholePixelHeight extends RenderProxyBox {
  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen().copyWith(minWidth: constraints.minWidth), parentUsesSize: true);
    size = constraints.constrain(Size(child.size.width, child.size.height.ceilToDouble()));
  }

  @override
  double computeMinIntrinsicHeight(double width) => super.computeMinIntrinsicHeight(width).ceilToDouble();

  @override
  double computeMaxIntrinsicHeight(double width) => super.computeMaxIntrinsicHeight(width).ceilToDouble();
}
