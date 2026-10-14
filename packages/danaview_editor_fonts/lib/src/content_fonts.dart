// OWNER: UX-30
//
// The curated content-font set (ARCH §17.8, D-30): stable ids (stored in projects as
// `TextStyleSpec.fontFamily` / subtitle styles), family names, which styles each family has, and
// where its files and OFL text live in this package. The editor's FontCatalog (danaview_editor,
// UX-30) builds on this list; [bundledContentFontIds] says which families are in the bundle.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bundled_fonts.g.dart';

/// The package name content-font families are registered under.
const String contentFontsPackage = 'danaview_editor_fonts';

/// The look of a family, used to group and describe it in the font picker.
enum ContentFontCategory {
  /// Sans serif.
  sans,

  /// Serif.
  serif,

  /// Condensed display face.
  display,

  /// Handwriting / script.
  handwriting,

  /// Monospaced.
  mono,
}

/// One family of the curated set.
@immutable
final class ContentFontFamily {
  /// Creates a family entry.
  const ContentFontFamily({
    required this.id,
    required this.family,
    required this.category,
    required this.dir,
    this.hasBold = true,
    this.hasItalic = true,
  });

  /// Stable id stored in projects (lowercase, never changes once shipped).
  final String id;

  /// The family name as declared in this package's pubspec ("Playfair Display").
  final String family;

  /// The look of the family.
  final ContentFontCategory category;

  /// Directory of the family's files below `fonts/`.
  final String dir;

  /// Whether the family has a bold weight (otherwise bold is synthesized).
  final bool hasBold;

  /// Whether the family has an italic style (otherwise italic is synthesized).
  final bool hasItalic;

  /// The family name Flutter resolves for this package's font
  /// (`packages/danaview_editor_fonts/<family>`).
  String get packagedFamily => 'packages/$contentFontsPackage/$family';

  /// Asset key of the family's OFL text.
  String get licenseAsset => 'packages/$contentFontsPackage/fonts/$dir/OFL.txt';

  /// Whether the family's files are in this bundle.
  bool get isBundled => bundledContentFontIds.contains(id);

  @override
  bool operator ==(Object other) => other is ContentFontFamily && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ContentFontFamily($id, $family)';
}

/// The id of the default content font (Figtree, matching `TextStyleSpec`'s default).
const String defaultContentFontId = 'figtree';

/// The ten curated families in picker order (ARCH §17.8).
const List<ContentFontFamily> contentFontFamilies = [
  ContentFontFamily(id: 'figtree', family: 'Figtree', category: ContentFontCategory.sans, dir: 'figtree'),
  ContentFontFamily(id: 'inter', family: 'Inter', category: ContentFontCategory.sans, dir: 'inter'),
  ContentFontFamily(id: 'montserrat', family: 'Montserrat', category: ContentFontCategory.sans, dir: 'montserrat'),
  ContentFontFamily(id: 'oswald', family: 'Oswald', category: ContentFontCategory.display, dir: 'oswald', hasItalic: false),
  ContentFontFamily(
      id: 'bebas', family: 'Bebas Neue', category: ContentFontCategory.display, dir: 'bebasneue', hasBold: false, hasItalic: false),
  ContentFontFamily(id: 'playfair', family: 'Playfair Display', category: ContentFontCategory.serif, dir: 'playfairdisplay'),
  ContentFontFamily(id: 'lora', family: 'Lora', category: ContentFontCategory.serif, dir: 'lora'),
  ContentFontFamily(id: 'caveat', family: 'Caveat', category: ContentFontCategory.handwriting, dir: 'caveat', hasItalic: false),
  ContentFontFamily(
      id: 'pacifico', family: 'Pacifico', category: ContentFontCategory.handwriting, dir: 'pacifico', hasBold: false, hasItalic: false),
  ContentFontFamily(id: 'jetbrains', family: 'JetBrains Mono', category: ContentFontCategory.mono, dir: 'jetbrainsmono'),
];

/// The bundled families, in picker order.
List<ContentFontFamily> get bundledContentFontFamilies => [
      for (final f in contentFontFamilies)
        if (f.isBundled) f,
    ];

bool _licensesRegistered = false;

/// Adds the OFL text of every bundled family to Flutter's [LicenseRegistry] (shown in the
/// licences screen, ARCH §17.8). Safe to call more than once.
void registerContentFontLicenses({AssetBundle? bundle}) {
  if (_licensesRegistered) return;
  _licensesRegistered = true;
  final assets = bundle ?? rootBundle;
  LicenseRegistry.addLicense(() async* {
    for (final f in bundledContentFontFamilies) {
      final String text;
      try {
        text = await assets.loadString(f.licenseAsset);
      } catch (_) {
        continue;
      }
      yield LicenseEntryWithLineBreaks(['${f.family} (video editor content font)'], text);
    }
  });
}
