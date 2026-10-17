// OWNER: UX-30
//
// FontCatalog (ARCH §17.8, D-30): stable content-font ids -> family names, the families the font
// picker offers, search, and the FontResolver API-04's TextLayoutEngine takes (preview overlay,
// handles and export sprites resolve ids through it, so they agree).
//
// * Ids are the ones of package:danaview_editor_fonts (`figtree`, `inter`, `playfair`, …). An
//   unknown id, an empty id, or a family that is not in the bundle resolves to the bundled
//   Figtree, as API-04 requires ("unknown -> Figtree").
// * Resolved names are package-qualified (`packages/danaview_editor_fonts/Inter`), so content
//   Figtree never depends on the UI kit's chrome font.
// * The picker lists [FontCatalog.available] (bundled families only). Search matches the display
//   name, the id and the category, ignoring case, spaces, hyphens and underscores.
//
// Wiring (FIX-FONTS): `previewTextEngineProvider` (UX-19) and `exportEnvironmentProvider`'s sprite
// engine (UX-39) build `TextLayoutEngine(fontResolver: <fontCatalogProvider>.resolve)`, so the
// preview overlay, the handles and export sprites resolve ids through this one catalog.
// [fontCatalogProvider] also supplies the catalog to the text panel (tests override it).
// Bold: Flutter applies the `wght` axis of a variable font for `FontWeight.w700` (checked on
// Flutter 3.44: identical ink to `FontVariation('wght', 700)`), so no explicit variation is needed.
// Licences: the app's Settings > About > Open-source licences screen (FIX-LICENSES) calls
// `registerContentFontLicenses()` from the router, so the OFL text of every bundled family is
// listed there; the package barrel exports it for the app.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show FontResolver;
import 'package:danaview_editor_fonts/danaview_editor_fonts.dart';

export 'package:danaview_editor_fonts/danaview_editor_fonts.dart'
    show ContentFontCategory, ContentFontFamily, contentFontFamilies, defaultContentFontId, registerContentFontLicenses;

/// The content-font catalog of the editor (the text panel and font picker read it; tests and
/// INT-02 may override it).
final Provider<FontCatalog> fontCatalogProvider = Provider<FontCatalog>((ref) => FontCatalog.instance);

/// Content-font ids -> families (ARCH §17.8).
final class FontCatalog {
  /// A catalog over [families]; [bundled] is the set of ids whose files are bundled.
  FontCatalog({List<ContentFontFamily>? families, Set<String>? bundled})
      : families = List.unmodifiable(families ?? contentFontFamilies),
        _bundled = bundled ?? bundledContentFontIds {
    assert(this.families.any((f) => f.id == defaultContentFontId), 'the catalog needs the default family');
  }

  /// The catalog of the app (the curated set and the bundle).
  static final FontCatalog instance = FontCatalog();

  /// Every curated family, in picker order.
  final List<ContentFontFamily> families;

  final Set<String> _bundled;

  /// The families the picker offers (bundled ones), in picker order.
  List<ContentFontFamily> get available => [
        for (final f in families)
          if (isAvailable(f.id)) f,
      ];

  /// Whether [id] names a bundled family.
  bool isAvailable(String id) => _bundled.contains(id) && families.any((f) => f.id == id);

  /// The family of [id], or null when [id] is not curated.
  ContentFontFamily? byId(String id) {
    for (final f in families) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// The default family (Figtree).
  ContentFontFamily get fallback => byId(defaultContentFontId)!;

  /// The family [id] renders with: itself when bundled, else Figtree.
  ContentFontFamily familyFor(String id) {
    final f = byId(id);
    return f != null && isAvailable(f.id) ? f : fallback;
  }

  /// The Flutter font family of [id] (package-qualified); unknown -> Figtree. A [FontResolver].
  String resolve(String fontId) => familyFor(fontId).packagedFamily;

  /// [resolve] as a [FontResolver] for API-04's TextLayoutEngine.
  FontResolver get resolver => resolve;

  /// Display name of [id] ("Playfair Display"); an unknown id shows as Figtree's name.
  String displayName(String id) => familyFor(id).family;

  /// The available families matching [query] (all of them for a blank query).
  List<ContentFontFamily> search(String query) {
    final q = normalize(query);
    if (q.isEmpty) return available;
    return [
      for (final f in available)
        if (normalize(f.family).contains(q) || normalize(f.id).contains(q) || normalize(f.category.name).contains(q)) f,
    ];
  }

  /// Lowercase, no spaces/hyphens/underscores (so "playfair d", "Playfair-Display" match).
  static String normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), '');
}
