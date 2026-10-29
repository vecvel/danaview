import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'danaview_tokens.dart';

/// The app's single typeface, bundled with this package and applied through [DanaviewTheme].
/// Text inherits it, so styles should not set their own family.
abstract final class DanaviewFonts {
  /// Fonts declared by a package are registered under `packages/<name>/<family>`.
  static const String family = 'packages/danaview_ui_kit/Figtree';

  /// Weights bundled in `fonts/`; other weights render with the nearest of these.
  static const List<String> files = [
    'packages/danaview_ui_kit/fonts/Figtree-Regular.ttf',
    'packages/danaview_ui_kit/fonts/Figtree-Medium.ttf',
    'packages/danaview_ui_kit/fonts/Figtree-SemiBold.ttf',
    'packages/danaview_ui_kit/fonts/Figtree-Bold.ttf',
  ];

}

/// Cinema B palette (docs/design/DESIGN_SYSTEM.md §2): true black, neutral greys, one deep red
/// accent. Status colours never use red: errors are orange, and red text on dark is [primaryLight].
abstract final class DanaviewColors {
  /// Screen background: true black (OLED).
  static const Color background = Color(0xFF000000);

  /// Cards, grouped lists, the tab bar.
  static const Color surface = Color(0xFF141414);

  /// Raised items on a card: idle tab pills, fields, secondary buttons, toasts.
  static const Color surfaceElevated = Color(0xFF222222);

  /// Icon tiles, menus, popovers.
  static const Color surfaceElevatedHigher = Color(0xFF2A2A2C);
  static const Color overlayDark = Color(0xD9000000);

  /// Retired glass card fill; now the same as [surface].
  static const Color cardGlass = Color(0xFF141414);

  /// Behind sheets and dialogs: black at 60 %.
  static const Color scrim = Color(0x99000000);

  /// Neutral tile behind a loading thumbnail (§2.5), with a 20 pt type icon in [textSecondary].
  static const Color mediaPlaceholder = Color(0xFF1C1C1E);

  /// 0.5 pt hairline around a surface: white at 7 %.
  static const Color hairline = Color(0x12FFFFFF);

  /// Inner tiles on a card: white at 5 %.
  static const Color hairlineSubtle = Color(0x0DFFFFFF);

  /// List dividers: white at 6 %, inset to start after the icon tile.
  static const Color divider = Color(0x0FFFFFFF);

  /// Icon-tile hairline: white at 10 %.
  static const Color border = Color(0x1AFFFFFF);

  /// Selected tab-pill hairline: white at 12 %.
  static const Color borderBright = Color(0x1FFFFFFF);

  /// 1 px inner top highlight on cards, secondary buttons and toolbar circles: white at 6 %.
  static const Color highlight = Color(0x0FFFFFFF);

  /// Top highlight on icon tiles: white at 12 %.
  static const Color highlightTile = Color(0x1FFFFFFF);

  /// Top highlight on the primary button and the selected tab pill: white at 18 %.
  static const Color highlightStrong = Color(0x2EFFFFFF);

  /// Owner rule: kit controls never paint hover or press. Kept for the keyboard-focus tint.
  static const Color hover = Color(0x0FFFFFFF);
  static const Color pressed = Color(0x1AFFFFFF);

  /// Deep red: selected tab, primary button, progress, slider track, switch on. White text on it
  /// is 7.2:1. Never use it for text on black; use [primaryLight].
  static const Color primary = Color(0xFFB20710);

  /// Accent text and icons on dark: links, section actions, selected tab-bar item, active icon.
  /// #FF5A62 keeps 4.5:1 on every surface up to [surfaceElevated] (5.2:1 there, 6.9:1 on black).
  static const Color primaryLight = Color(0xFFFF5A62);

  /// Retired darker accent; now the same as [primary].
  static const Color primaryDark = Color(0xFFB20710);

  /// Red at 22 %: tonal fills.
  static const Color primaryTonal = Color(0x38B20710);

  /// Red at 16 %: selected-row wash, keyboard focus fill.
  static const Color primarySoft = Color(0x29B20710);

  /// Keyboard-only focus ring (2 pt): [primaryLight] at 55 %.
  static const Color focusRing = Color(0x8CFF5A62);

  /// Focused field / open trigger: one step brighter than the resting [surfaceElevated] fill,
  /// neutral (no accent outline or tint).
  static const Color fieldActive = Color(0xFF2A2A2C);
  static const Color onPrimary = Color(0xFFFFFFFF);

  /// Product hue (Camera logo fold). Not for app UI: use neutral or [primary] (§2.4).
  static const Color cyan = Color(0xFF06B6D4);

  /// Product hue (Editor logo fold). Not for app UI: use neutral or [primary] (§2.4).
  static const Color purple = Color(0xFF8B5CF6);

  /// Volume-slider boost band: keeps its orange/red meaning.
  static const Color boostBand = Color(0xFFF59E0B);
  static const Color boostBandHigh = Color(0xFFEF4444);

  /// Saved, done, connected.
  static const Color success = Color(0xFF30D158);

  /// Unsaved, attention, low storage.
  static const Color warning = Color(0xFFFFD60A);

  /// Failed, invalid input, audio clipping. Orange, because red is the accent.
  static const Color error = Color(0xFFFF9F0A);

  /// Error text and icons on dark surfaces.
  static const Color errorLight = Color(0xFFFFB340);

  /// Delete and remove actions (always with a trash icon and a confirm dialog). The same red as
  /// [primaryLight] so a Delete row keeps 4.5:1 on menus ([surfaceElevatedHigher], 4.7:1).
  static const Color destructive = Color(0xFFFF5A62);

  /// Fill behind a destructive button: [destructive] at 10 % (its label keeps 4.5:1 on cards).
  static const Color destructiveSoft = Color(0x1AFF5A62);

  static const Color textPrimary = Color(0xFFFFFFFF);

  /// Metadata, idle tab labels, counts.
  static const Color textSecondary = Color(0xFF9A9A9A);

  /// Placeholders, captions and disabled labels. #929292 keeps 4.5:1 on every chrome surface up to
  /// [surfaceElevatedHigher] and the focused field fill ([fieldActive]), 4.6:1 there.
  static const Color textMuted = Color(0xFF929292);

  /// Chevrons in rows.
  static const Color chevron = Color(0xFF5A5A5A);

  /// Idle tab-bar items.
  static const Color tabIdle = Color(0xFF8A8A8A);
  static const Color textOnLight = Color(0xFF0B0C10);

  static const Color bufferTrack = Color(0x47FFFFFF);

  /// Inactive track of switches, sliders and progress: white at 18 %.
  static const Color trackBackground = Color(0x2EFFFFFF);

  static const double disabledOpacity = 0.4;

  static Color disabled(Color color) => color.withValues(alpha: color.a * disabledOpacity);

  /// Translucent colors are composited over [DanaviewColors.background] first.
  static Color foregroundOn(Color background) {
    return contrastRatio(textPrimary, background) >= contrastRatio(textOnLight, background)
        ? textPrimary
        : textOnLight;
  }

  /// WCAG contrast ratio of [foreground] drawn on [background] (1.0–21.0).
  static double contrastRatio(Color foreground, Color background) {
    final bg = background.a >= 1.0 ? background : Color.alphaBlend(background, DanaviewColors.background);
    final fg = foreground.a >= 1.0 ? foreground : Color.alphaBlend(foreground, bg);
    final lf = fg.computeLuminance();
    final lb = bg.computeLuminance();
    return (math.max(lf, lb) + 0.05) / (math.min(lf, lb) + 0.05);
  }
}

/// Type scale (§6). Figtree comes from the theme, so styles do not set a family.
///
/// The iOS-scale styles are [largeTitle], [sheetTitle], [sectionHeader], [rowTitle], [bodyLarge],
/// [subhead], [sectionAction], [footnote], [captionStrong] and [tabLabel]. The older compact styles
/// ([title], [headline], [body], [label], [caption], [micro]) keep their sizes so existing screens
/// do not reflow; restyled screens move to the iOS-scale names.
abstract final class DanaviewTextStyles {
  /// 30 / 700, tracking -0.5: screen title ("Danaview" on Home, "Settings").
  static const TextStyle largeTitle = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.15,
    color: DanaviewColors.textPrimary,
  );

  /// 22 / 700: sheet and dialog titles (§6 `title`).
  static const TextStyle sheetTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.2,
    color: DanaviewColors.textPrimary,
  );

  /// 20 / 700: section headers on Home and tabs.
  static const TextStyle sectionHeader = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    height: 1.2,
    color: DanaviewColors.textPrimary,
  );

  /// 17 / 600: card titles and list-row titles (§6 `headline`).
  static const TextStyle rowTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.25,
    color: DanaviewColors.textPrimary,
  );

  /// 17 / 400: body text and list rows (§6 `body`).
  static const TextStyle bodyLarge = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.2,
    height: 1.3,
    color: DanaviewColors.textPrimary,
  );

  /// 15 / 400: secondary row text.
  static const TextStyle subhead = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: DanaviewColors.textSecondary,
  );

  /// 15 / 600 in [DanaviewColors.primaryLight]: section actions and text buttons ("See all").
  static const TextStyle sectionAction = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: DanaviewColors.primaryLight,
  );

  /// 13 / 400 with tabular figures: metadata (duration · size).
  static const TextStyle footnote = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: DanaviewColors.textSecondary,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 12 / 500: badges and duration labels (§6 `caption`), tabular figures.
  static const TextStyle captionStrong = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: DanaviewColors.textPrimary,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 11 / 500: tab-bar labels.
  static const TextStyle tabLabel = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: DanaviewColors.tabIdle,
  );

  static const TextStyle title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: DanaviewColors.textPrimary,
  );
  static const TextStyle headline = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: DanaviewColors.textPrimary,
  );
  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.35,
    color: DanaviewColors.textPrimary,
  );
  static const TextStyle bodySecondary = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.35,
    color: DanaviewColors.textSecondary,
  );
  static const TextStyle label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: DanaviewColors.textPrimary,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: DanaviewColors.textMuted,
  );
  static const TextStyle micro = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: DanaviewColors.textMuted,
  );
}

abstract final class DanaviewTheme {
  static ThemeData get darkTheme {
    const outline = OutlineInputBorder(
      borderRadius: DanaviewRadius.controlAll,
      borderSide: DanaviewBorders.hairline,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: DanaviewColors.background,
      canvasColor: DanaviewColors.background,
      colorScheme: const ColorScheme.dark(
        primary: DanaviewColors.primary,
        onPrimary: DanaviewColors.onPrimary,
        primaryContainer: DanaviewColors.primaryTonal,
        onPrimaryContainer: DanaviewColors.primaryLight,
        secondary: DanaviewColors.primaryLight,
        onSecondary: DanaviewColors.textPrimary,
        tertiary: DanaviewColors.textSecondary,
        surface: DanaviewColors.surface,
        onSurface: DanaviewColors.textPrimary,
        onSurfaceVariant: DanaviewColors.textSecondary,
        surfaceContainerLowest: DanaviewColors.background,
        surfaceContainerLow: DanaviewColors.surface,
        surfaceContainer: DanaviewColors.surfaceElevated,
        surfaceContainerHigh: DanaviewColors.surfaceElevatedHigher,
        surfaceContainerHighest: DanaviewColors.surfaceElevatedHigher,
        error: DanaviewColors.error,
        onError: DanaviewColors.textPrimary,
        outline: DanaviewColors.hairline,
        outlineVariant: DanaviewColors.hairline,
        shadow: Colors.black,
        scrim: DanaviewColors.scrim,
      ),
      fontFamily: DanaviewFonts.family,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      // Owner rule: no hover or press effect on any control, Material ones included. Keyboard
      // focus rings are drawn by the kit's own controls (onShowFocusHighlight), not this colour.
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      textTheme: const TextTheme(
        headlineMedium: DanaviewTextStyles.largeTitle,
        titleLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: DanaviewColors.textPrimary,
          letterSpacing: -0.3,
        ),
        titleMedium: DanaviewTextStyles.headline,
        bodyLarge: DanaviewTextStyles.body,
        bodyMedium: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: DanaviewColors.textSecondary,
        ),
        labelSmall: DanaviewTextStyles.micro,
      ),
      iconTheme: const IconThemeData(color: DanaviewColors.textPrimary, size: 20),
      dividerTheme: const DividerThemeData(
        color: DanaviewColors.hairline,
        thickness: DanaviewBorders.width,
        space: 1,
      ),
      tooltipTheme: const TooltipThemeData(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: EdgeInsets.symmetric(horizontal: 12),
        waitDuration: Duration(milliseconds: 500),
        textStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: DanaviewColors.textPrimary,
        ),
        decoration: BoxDecoration(
          color: DanaviewColors.surfaceElevatedHigher,
          borderRadius: DanaviewRadius.smAll,
          border: DanaviewBorders.all,
          boxShadow: DanaviewShadows.soft,
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: DanaviewColors.primary,
        selectionColor: Color(0x66FF5A62),
        selectionHandleColor: DanaviewColors.primary,
      ),
      scrollbarTheme: const ScrollbarThemeData(
        thickness: WidgetStatePropertyAll<double>(4),
        radius: Radius.circular(DanaviewRadius.sm),
        thumbColor: WidgetStatePropertyAll<Color>(Color(0x2EFFFFFF)),
        crossAxisMargin: 2,
        mainAxisMargin: 4,
        minThumbLength: 36,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: DanaviewColors.surfaceElevated,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: const TextStyle(fontSize: 15, color: DanaviewColors.textMuted),
        prefixIconColor: DanaviewColors.textMuted,
        suffixIconColor: DanaviewColors.textMuted,
        errorStyle: const TextStyle(fontSize: 12, color: DanaviewColors.errorLight),
        border: outline,
        enabledBorder: outline,
        disabledBorder: outline.copyWith(borderSide: DanaviewBorders.subtle),
        // Outlines stay a neutral hairline in every state; errors read from errorStyle.
        focusedBorder: outline,
        errorBorder: outline,
        focusedErrorBorder: outline,
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          for (final platform in TargetPlatform.values)
            platform: const CupertinoPageTransitionsBuilder(),
        },
      ),
      // Material fallbacks some screens still use, in the Cinema B look (§8).
      dialogTheme: const DialogThemeData(
        backgroundColor: DanaviewColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.sheetAll, side: DanaviewBorders.hairline),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: DanaviewColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: DanaviewColors.scrim,
        shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.sheetTop, side: DanaviewBorders.hairline),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: DanaviewColors.surfaceElevatedHigher,
        surfaceTintColor: Colors.transparent,
        shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.mediaAll, side: DanaviewBorders.hairline),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: DanaviewColors.surfaceElevated,
        actionTextColor: DanaviewColors.primaryLight,
        contentTextStyle: TextStyle(fontSize: 15, color: DanaviewColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.toastAll, side: DanaviewBorders.hairline),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: DanaviewColors.primary,
        linearTrackColor: DanaviewColors.trackBackground,
        circularTrackColor: DanaviewColors.trackBackground,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? DanaviewColors.primary : DanaviewColors.trackBackground,
        ),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: DanaviewColors.primary,
        inactiveTrackColor: DanaviewColors.trackBackground,
        thumbColor: Colors.white,
        overlayColor: Colors.transparent,
        trackHeight: 4.0,
      ),
    );
  }
}
