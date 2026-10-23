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

abstract final class DanaviewColors {
  static const Color background = Color(0xFF07080C);
  static const Color surface = Color(0xFF0F1118);
  static const Color surfaceElevated = Color(0xFF181B26);
  static const Color surfaceElevatedHigher = Color(0xFF222636);
  static const Color overlayDark = Color(0xD907080C);
  static const Color cardGlass = Color(0xFF12141F);
  static const Color scrim = Color(0x99000000);

  static const Color hairline = Color(0x14FFFFFF);
  static const Color hairlineSubtle = Color(0x0DFFFFFF);
  static const Color border = Color(0x1AFFFFFF);
  static const Color borderBright = Color(0x1EFFFFFF);

  static const Color hover = Color(0x0FFFFFFF);
  static const Color pressed = Color(0x1AFFFFFF);

  /// White text on it stays above 4.5:1.
  static const Color primary = Color(0xFF5E60EE);
  static const Color primaryLight = Color(0xFF818CF8);
  static const Color primaryDark = Color(0xFF4F46E5);
  static const Color primaryTonal = Color(0x296366F1);
  static const Color primarySoft = Color(0x1F6366F1);
  static const Color focusRing = Color(0x476366F1);

  /// Focused field / open trigger: primary-tinted at the resting fill's luminance, so hints keep
  /// their contrast.
  static const Color fieldActive = Color(0xFF21243E);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color cyan = Color(0xFF06B6D4);
  static const Color purple = Color(0xFF8B5CF6);

  static const Color boostBand = Color(0xFFF59E0B);
  static const Color boostBandHigh = Color(0xFFEF4444);
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color errorLight = Color(0xFFF87171);

  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFA0A6BC);
  static const Color textMuted = Color(0xFF8B91A9);
  static const Color textOnLight = Color(0xFF0B0C10);

  static const Color bufferTrack = Color(0x47FFFFFF);
  static const Color trackBackground = Color(0x29FFFFFF);

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

abstract final class DanaviewTextStyles {
  static const TextStyle largeTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: DanaviewColors.textPrimary,
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
      borderRadius: DanaviewRadius.mdAll,
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
        secondary: DanaviewColors.cyan,
        onSecondary: DanaviewColors.textOnLight,
        tertiary: DanaviewColors.purple,
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
        outline: DanaviewColors.border,
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
        selectionColor: Color(0x596366F1),
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
        fillColor: DanaviewColors.surfaceElevatedHigher,
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
