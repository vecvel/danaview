import 'package:flutter/material.dart';

import 'danaview_theme.dart';

abstract final class DanaviewRadius {
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 14;
  static const double dialog = 16;
  static const double xl = 20;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius dialogAll = BorderRadius.all(Radius.circular(dialog));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius sheetTop = BorderRadius.vertical(top: Radius.circular(xl));
}

abstract final class DanaviewShadows {
  static const List<BoxShadow> none = <BoxShadow>[];

  static const List<BoxShadow> subtle = <BoxShadow>[
    BoxShadow(
      color: Color(0x2E000000),
      blurRadius: 16,
      spreadRadius: -4,
      offset: Offset(0, 2),
    ),
  ];

  static const List<BoxShadow> soft = <BoxShadow>[
    BoxShadow(
      color: Color(0x59000000),
      blurRadius: 32,
      spreadRadius: -8,
      offset: Offset(0, 8),
    ),
  ];
}

enum DanaviewShadow {
  none(DanaviewShadows.none),
  subtle(DanaviewShadows.subtle),
  soft(DanaviewShadows.soft);

  const DanaviewShadow(this.boxShadows);

  final List<BoxShadow> boxShadows;
}

abstract final class DanaviewBorders {
  static const double width = 0.8;
  static const BorderSide hairline = BorderSide(color: DanaviewColors.hairline, width: width);
  static const BorderSide subtle = BorderSide(color: DanaviewColors.hairlineSubtle, width: width);
  static const BorderSide focus = BorderSide(color: DanaviewColors.focusRing, width: 1);
  static const Border all = Border.fromBorderSide(hairline);
}

abstract final class DanaviewSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double minTapTarget = 44;
}

abstract final class DanaviewBreakpoints {
  static const double compact = 560;
  static const double medium = 900;

  static bool isCompactWidth(double width) => width < compact;
  static bool isMediumWidth(double width) => width >= compact && width < medium;
  static bool isExpandedWidth(double width) => width >= medium;
}

abstract final class DanaviewMotion {
  static const Duration press = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 250);
  static const Curve curve = Curves.easeOutCubic;
}

extension DanaviewContextX on BuildContext {
  double get danaviewWidth => MediaQuery.sizeOf(this).width;
  bool get isCompact => DanaviewBreakpoints.isCompactWidth(danaviewWidth);
  bool get isMedium => DanaviewBreakpoints.isMediumWidth(danaviewWidth);
  bool get isExpanded => DanaviewBreakpoints.isExpandedWidth(danaviewWidth);

  bool get isTouchPlatform {
    switch (Theme.of(this).platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return true;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return false;
    }
  }
}
