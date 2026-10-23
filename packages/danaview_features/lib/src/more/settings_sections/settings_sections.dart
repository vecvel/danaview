// OWNER: INT-101
//
// Settings section slots (BUILD_PLAN INT-101; ARCH v1.2 §4.4). The 1.2.0 Settings sections are
// built by their owners and handed to [DanaviewSettingsScreen] by the app root, so the app compiles
// and Settings looks exactly like 1.1 until each owner lands:
//
// * privacy: Settings › Privacy, the speed-test fallback toggle (ST-04,
//   `settings_sections/privacy_section.dart`);
// * library storage: Danaview folders, Recently deleted, backup notes (HOM-17,
//   `settings_sections/library_storage_section.dart`);
// * search index: status, rebuild and delete of the on-device index (INT-103,
//   `settings_sections/search_index_section.dart`).
//
// A null builder hides its section. The screen shows the sections after the Tools group, in the
// order of [SettingsSections.ordered]. Section widgets bring their own header and rows (Danaview kit
// components only, ARCH v1.2 rule 31).

import 'package:flutter/widgets.dart';

/// Builds one Settings section.
typedef SettingsSectionBuilder = Widget Function(BuildContext context);

/// Which 1.2.0 section a slot holds.
///
/// See BUILD_PLAN INT-101.
enum SettingsSectionSlot {
  /// Settings › Privacy (ST-04).
  privacy,

  /// Library storage (HOM-17).
  libraryStorage,

  /// On-device search index (INT-103).
  searchIndex,
}

/// The optional section builders of the Settings screen. All null (the default) is the 1.1
/// Settings screen.
///
/// See BUILD_PLAN INT-101.
@immutable
final class SettingsSections {
  /// Creates the slots; a null builder hides its section.
  const SettingsSections({this.privacy, this.libraryStorage, this.searchIndex});

  /// Settings › Privacy (ST-04).
  final SettingsSectionBuilder? privacy;

  /// Library storage (HOM-17).
  final SettingsSectionBuilder? libraryStorage;

  /// On-device search index (INT-103).
  final SettingsSectionBuilder? searchIndex;

  /// The builder of [slot], or null.
  SettingsSectionBuilder? operator [](SettingsSectionSlot slot) => switch (slot) {
        SettingsSectionSlot.privacy => privacy,
        SettingsSectionSlot.libraryStorage => libraryStorage,
        SettingsSectionSlot.searchIndex => searchIndex,
      };

  /// Whether no section is set (the 1.1 screen).
  bool get isEmpty => ordered.isEmpty;

  /// The set slots and their builders, in screen order.
  List<(SettingsSectionSlot, SettingsSectionBuilder)> get ordered => [
        for (final slot in SettingsSectionSlot.values)
          if (this[slot] case final builder?) (slot, builder),
      ];

  @override
  bool operator ==(Object other) =>
      other is SettingsSections &&
      other.privacy == privacy &&
      other.libraryStorage == libraryStorage &&
      other.searchIndex == searchIndex;

  @override
  int get hashCode => Object.hash(privacy, libraryStorage, searchIndex);
}
