// OWNER: HOM-05
//
// The optional callbacks of the Files & Media Home (BUILD_PLAN HOM-05, ARCH v1.2 rule 23). The
// features package never imports the editor or an AI package: the app root (INT-103, INT-105)
// supplies the navigation through these callbacks. Every field is nullable, so the app compiles
// and runs before the wiring tickets land; a null callback hides its entry point (ARCH v1.2 §3,
// "hidden, not disabled").

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/widgets.dart';

/// The Home's optional entry points into the editor, projects and AI (all nullable).
///
/// See ARCH v1.2 V2-101, §3 and rule 23.
@immutable
class HomeCallbacks {
  /// Creates the callbacks; every one defaults to null (entry point hidden).
  const HomeCallbacks({
    this.onEditPhoto,
    this.onBatchEditPhotos,
    this.onMakeMontage,
    this.onOpenProjects,
    this.onSearchWithAi,
    this.onOpenAiSettings,
    this.onOpenAiStudio,
  });

  /// No callbacks: the Home shows none of the optional entry points.
  static const HomeCallbacks none = HomeCallbacks();

  /// Opens one photo in Still Photo Mode (the photo viewer's Edit, HOM-11; wired by INT-105).
  final ValueChanged<PhotoMediaItem>? onEditPhoto;

  /// Opens the selected photos in the editor's batch mode, in selection order (HOM-12).
  final ValueChanged<List<PhotoMediaItem>>? onBatchEditPhotos;

  /// Lays the selected photos and videos out on a new timeline, in selection order (HOM-12).
  final ValueChanged<List<MediaItem>>? onMakeMontage;

  /// Opens the editor's project list. Also decides whether the `Projects` tab exists: it is shown
  /// only when this is set and the platform runs the editor (iOS and Android, ARCH v1.2 §3).
  final VoidCallback? onOpenProjects;

  /// Starts an AI search with the current query (AIS-51; wired by INT-103).
  final ValueChanged<String>? onSearchWithAi;

  /// Opens the AI settings (AIS-51's "Set up AI" link; wired by INT-103).
  final VoidCallback? onOpenAiSettings;

  /// Opens AI Studio: the phone tab bar's AI Studio item (DESIGN_SYSTEM §10.5), shown only with
  /// DANAVIEW_AI_STUDIO on and this set.
  final VoidCallback? onOpenAiStudio;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HomeCallbacks &&
          other.onEditPhoto == onEditPhoto &&
          other.onBatchEditPhotos == onBatchEditPhotos &&
          other.onMakeMontage == onMakeMontage &&
          other.onOpenProjects == onOpenProjects &&
          other.onSearchWithAi == onSearchWithAi &&
          other.onOpenAiSettings == onOpenAiSettings &&
          other.onOpenAiStudio == onOpenAiStudio;

  @override
  int get hashCode =>
      Object.hash(
        onEditPhoto,
        onBatchEditPhotos,
        onMakeMontage,
        onOpenProjects,
        onSearchWithAi,
        onOpenAiSettings,
        onOpenAiStudio,
      );
}

/// Makes the Home's [HomeCallbacks] available to every tab, tray and bar below it, so the slot
/// widgets of later tickets (HOM-11, HOM-12, AIS-51) read them without new constructor wiring.
class HomeCallbacksScope extends InheritedWidget {
  /// Provides [callbacks] to [child].
  const HomeCallbacksScope({super.key, required this.callbacks, required super.child});

  /// The callbacks in scope.
  final HomeCallbacks callbacks;

  /// The nearest callbacks, or [HomeCallbacks.none] outside a Home.
  static HomeCallbacks of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeCallbacksScope>()?.callbacks ?? HomeCallbacks.none;

  @override
  bool updateShouldNotify(HomeCallbacksScope oldWidget) => callbacks != oldWidget.callbacks;
}
