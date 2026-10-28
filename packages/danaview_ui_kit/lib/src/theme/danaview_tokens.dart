import 'package:flutter/material.dart';

import 'danaview_theme.dart';

/// Corner radii (§4). Kit surfaces draw them as iOS continuous corners through
/// [RoundedSuperellipseBorder] (see `DanaviewDepth`); the `*All` constants are for clipping and
/// for plain [BoxDecoration]s.
abstract final class DanaviewRadius {
  /// Badges, duration labels on thumbnails, small chips.
  static const double xs = 6;

  /// Same as [tile]. Older name.
  static const double sm = 8;

  /// Same as [thumb]. Older name.
  static const double md = 10;

  /// Same as [media]. Older name.
  static const double lg = 14;

  /// Same as [card]. Older name.
  static const double dialog = 16;

  /// Same as [toast]. Older name.
  static const double xl = 20;

  /// 28 pt icon tiles in lists.
  static const double tile = 8;

  /// Thumbnails inside a card, timeline clips.
  static const double thumb = 10;

  /// Buttons, text and search fields, the filter button, grouped lists.
  static const double control = 12;

  /// Media cards (Continue watching, projects), the photo strip container, menus.
  static const double media = 14;

  /// Large cards and panels.
  static const double card = 16;

  /// Toasts, snackbars, popovers.
  static const double toast = 20;

  /// Bottom sheets (top corners only) and dialogs.
  static const double sheet = 24;

  /// Tab pills, chips, segmented controls, round toolbar buttons.
  static const double capsule = 999;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius dialogAll = BorderRadius.all(Radius.circular(dialog));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));

  static const BorderRadius tileAll = BorderRadius.all(Radius.circular(tile));
  static const BorderRadius thumbAll = BorderRadius.all(Radius.circular(thumb));
  static const BorderRadius controlAll = BorderRadius.all(Radius.circular(control));
  static const BorderRadius mediaAll = BorderRadius.all(Radius.circular(media));
  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(card));
  static const BorderRadius toastAll = BorderRadius.all(Radius.circular(toast));
  static const BorderRadius sheetAll = BorderRadius.all(Radius.circular(sheet));
  static const BorderRadius capsuleAll = BorderRadius.all(Radius.circular(capsule));

  /// Top corners of a bottom sheet or docked panel ([sheet], 24).
  static const BorderRadius sheetTop = BorderRadius.vertical(top: Radius.circular(sheet));

  /// Inner radius of content inset by [padding] in a shape of [outer] radius (§4), never below 0.
  static double inner(double outer, double padding) => outer - padding < 0 ? 0 : outer - padding;
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

  /// Two-layer card shadow: `0 1 2 #000 @60 %` + `0 8 20 #000 @35 %`.
  static const List<BoxShadow> card = <BoxShadow>[
    BoxShadow(color: Color(0x99000000), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x59000000), blurRadius: 20, offset: Offset(0, 8)),
  ];

  /// Raised (primary) button: `0 2 8 #000 @50 %`.
  static const List<BoxShadow> raised = <BoxShadow>[
    BoxShadow(color: Color(0x80000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
}

enum DanaviewShadow {
  none(DanaviewShadows.none),
  subtle(DanaviewShadows.subtle),
  soft(DanaviewShadows.soft),
  card(DanaviewShadows.card),
  raised(DanaviewShadows.raised);

  const DanaviewShadow(this.boxShadows);

  final List<BoxShadow> boxShadows;
}

/// Hairlines (§3): 0.5 pt, white at 7 %. Never accent, status or bright.
abstract final class DanaviewBorders {
  static const double width = 0.5;

  /// Keyboard focus ring width (2 pt).
  static const double focusWidth = 2;
  static const BorderSide hairline = BorderSide(color: DanaviewColors.hairline, width: width);
  static const BorderSide subtle = BorderSide(color: DanaviewColors.hairlineSubtle, width: width);

  /// Icon tiles: white at 10 %.
  static const BorderSide tile = BorderSide(color: DanaviewColors.border, width: width);

  /// Selected tab pill: white at 12 %.
  static const BorderSide bright = BorderSide(color: DanaviewColors.borderBright, width: width);

  /// List dividers: white at 6 %.
  static const BorderSide divider = BorderSide(color: DanaviewColors.divider, width: width);

  /// Keyboard-only focus ring: [DanaviewColors.focusRing], 2 pt.
  static const BorderSide focus = BorderSide(color: DanaviewColors.focusRing, width: focusWidth);
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

  /// Height of every control that sits in a row with an input: text and search fields, the
  /// field-sized dropdown, [DanaviewButtonSize.field] buttons and icon buttons of this size, so a
  /// row of field + button + icon button lines up exactly. Equals [minTapTarget].
  static const double controlHeight = minTapTarget;

  /// Side margin of a full-width page or panel at [width]: 16 below 600, 24 below 1024,
  /// 32 from 1024. Content is never width-capped; it spans [width] minus this gutter
  /// on each side.
  static double pageGutter(double width) => width < 600 ? lg : (width < 1024 ? xl : xxl);

  /// Symmetric horizontal padding of [pageGutter] at [width].
  static EdgeInsets pageInsets(double width) => EdgeInsets.symmetric(horizontal: pageGutter(width));
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
