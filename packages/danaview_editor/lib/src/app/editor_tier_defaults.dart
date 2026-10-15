// OWNER: UX-44
//
// EditorTierDefaults (ARCH D-43(e) points 1 and 4, D-45, §9.5, §17.10): the effective value of a
// tier-dependent editor preference when the user never set it.
//
// * `editor.proxyMedia`: Always on the minimal and low tiers (background proxies from the start),
//   Auto on mid and high.
// * `editor.renderPreview`: Auto on the minimal and low tiers (heavy ranges render while idle and
//   charging), Manual on mid and high.
//
// An explicit preference always wins; an unset or unreadable one falls back to the tier default.
// UX-04's proxy row and UX-44's Render preview section read the same values through
// [editorTierDefaultsProvider], so a minimal/low device starts with background proxies on. Before
// the engine has reported its capabilities the mid-tier defaults apply (the safe, lighter choice).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/render_cache.dart' show RenderPolicy, RenderPreviewSetting, RenderTier;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show DeviceTier, EditorCapabilities;

import 'editor_prefs.dart';
import 'editor_providers.dart';

/// The `editor.` keys owned by UX-44 (stored through `EditorPrefs`' generic accessors).
abstract final class RenderPreviewPrefKeys {
  /// [RenderPreviewSetting] name (`auto` / `manual`); absent means the tier default.
  static const String renderPreview = 'editor.renderPreview';
}

/// Tier-dependent defaults of the editor preferences (file header).
final class EditorTierDefaults {
  /// The defaults of [tier].
  const EditorTierDefaults(this.tier);

  /// The defaults of the device [capabilities] describe.
  factory EditorTierDefaults.of(EditorCapabilities capabilities) => EditorTierDefaults(capabilities.tier);

  /// Used until the engine reported its capabilities (mid tier).
  static const EditorTierDefaults fallback = EditorTierDefaults(DeviceTier.mid);

  /// The device tier.
  final DeviceTier tier;

  /// The render-cache view of a device tier.
  static RenderTier renderTierOf(DeviceTier tier) => switch (tier) {
        DeviceTier.minimal => RenderTier.minimal,
        DeviceTier.low => RenderTier.low,
        DeviceTier.mid => RenderTier.mid,
        DeviceTier.high => RenderTier.high,
      };

  /// [tier] as the render cache sees it.
  RenderTier get renderTier => renderTierOf(tier);

  /// Minimal or low.
  bool get isConstrained => renderTier.isConstrained;

  // ---- Proxy media ------------------------------------------------------------------------------

  /// Default of `editor.proxyMedia`: Always on minimal/low, Auto on mid/high (D-43(e) point 1).
  ProxyMediaMode get proxyMedia => isConstrained ? ProxyMediaMode.always : ProxyMediaMode.auto;

  /// The proxy mode the user chose, or null when the preference is unset (or unreadable).
  static ProxyMediaMode? storedProxyMedia(EditorPrefs prefs) => _byName(ProxyMediaMode.values, prefs.readString(EditorPrefKeys.proxyMedia));

  /// The effective proxy mode: the user's choice, else [proxyMedia].
  ProxyMediaMode effectiveProxyMedia(EditorPrefs prefs) => storedProxyMedia(prefs) ?? proxyMedia;

  // ---- Render preview -------------------------------------------------------------------------

  /// Default of `editor.renderPreview`: Auto on minimal/low, Manual on mid/high (D-45).
  RenderPreviewSetting get renderPreview => RenderPolicy.defaultSetting(renderTier);

  /// The render-preview setting the user chose, or null when unset (or unreadable).
  static RenderPreviewSetting? storedRenderPreview(EditorPrefs prefs) =>
      _byName(RenderPreviewSetting.values, prefs.readString(RenderPreviewPrefKeys.renderPreview));

  /// The effective render-preview setting: the user's choice, else [renderPreview].
  RenderPreviewSetting effectiveRenderPreview(EditorPrefs prefs) => storedRenderPreview(prefs) ?? renderPreview;

  /// Stores the user's render-preview choice; null returns to the tier default.
  static Future<void> setRenderPreview(EditorPrefs prefs, RenderPreviewSetting? setting) =>
      prefs.writeString(RenderPreviewPrefKeys.renderPreview, setting?.name);

  static E? _byName<E extends Enum>(List<E> values, String? name) {
    if (name == null) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is EditorTierDefaults && other.tier == tier;

  @override
  int get hashCode => tier.hashCode;

  @override
  String toString() => 'EditorTierDefaults(${tier.name})';
}

/// The tier defaults of this device ([EditorTierDefaults.fallback] until capabilities are known).
final editorTierDefaultsProvider = Provider<EditorTierDefaults>((ref) {
  final caps = ref.watch(editorCapabilitiesProvider).valueOrNull;
  return caps == null ? EditorTierDefaults.fallback : EditorTierDefaults.of(caps);
}, name: 'editorTierDefaultsProvider');
