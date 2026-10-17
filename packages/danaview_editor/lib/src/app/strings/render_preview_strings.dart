// OWNER: UX-44
//
// Copy of the render-preview UI (ARCH D-45, §17.5, §17.10): the timeline render marker, the
// "Render preview" action and its outcomes, and the Render preview settings section. Plain,
// specific, with a next step (ARCH §19). Times are spoken as minutes and seconds.

import 'package:danaview_editor_core/model.dart' show TimeUs, microsPerSecond;
import 'package:danaview_editor_core/render_cache.dart' show HeavyReason, RangeState, RenderPreviewSetting;

/// Copy of the render-preview UI.
abstract final class RenderPreviewStrings {
  // ---- Action ---------------------------------------------------------------------------------

  /// Action label (tool tile, menus, shortcuts sheet).
  static const String action = 'Render preview';

  /// Disabled: nothing to render (empty timeline).
  static const String nothingToRender = 'Add a clip to the timeline first.';

  /// Disabled: an export is running.
  static const String exportRunning = 'Rendering waits until the export finishes.';

  /// The device or this build cannot render previews; live preview is used.
  static const String unsupported = 'Preview rendering isn\'t available on this device yet. Playback stays live.';

  /// Disabled: the editor is not ready.
  static const String notReady = 'The preview is still starting.';

  /// Toast: the target is already rendered.
  static const String alreadyRendered = 'This part is already rendered.';

  /// Toast: rendering started for [count] parts.
  static String started(int count) => count == 1 ? 'Rendering 1 part of the timeline…' : 'Rendering $count parts of the timeline…';

  /// Toast: queued until playback stops.
  static const String waitingForPause = 'Rendering starts when playback stops.';

  /// Toast: a render failed.
  static const String failed = 'A preview render failed. Playback stays live there.';

  /// Toast: every requested part is rendered.
  static const String done = 'Preview rendered. Playback there is smooth now.';

  /// What the manual action renders.
  static String targetName(RenderTargetKind kind) => switch (kind) {
        RenderTargetKind.range => 'this part',
        RenderTargetKind.selection => 'the selection',
        RenderTargetKind.loop => 'the loop range',
        RenderTargetKind.timeline => 'the whole timeline',
      };

  // ---- Marker strip -----------------------------------------------------------------------------

  /// Spoken name of the strip.
  static const String stripLabel = 'Render status';

  /// State name of a range.
  static String stateName(RangeState state) => switch (state) {
        RangeState.rendered => 'Rendered',
        RangeState.heavyUnrendered => 'Needs rendering',
        RangeState.notNeeded => 'Plays live',
      };

  /// Why a range is heavy.
  static String reasonName(HeavyReason reason) => switch (reason) {
        HeavyReason.decoders => 'many video layers',
        HeavyReason.chromaKey => 'chroma key',
        HeavyReason.effects => 'heavy effects',
      };

  /// Accessibility label of one range: `Needs rendering, 0:05 to 0:12, chroma key`.
  static String rangeLabel(RangeState state, TimeUs start, TimeUs end, {Set<HeavyReason> reasons = const {}}) {
    final base = '${stateName(state)}, ${clock(start)} to ${clock(end)}';
    if (state != RangeState.heavyUnrendered || reasons.isEmpty) return base;
    final why = [for (final r in HeavyReason.values) if (reasons.contains(r)) reasonName(r)].join(', ');
    return '$base, $why';
  }

  /// Hint of a range that offers rendering.
  static const String renderHint = 'Double tap to render this part';

  /// Title of the range sheet.
  static String rangeTitle(TimeUs start, TimeUs end) => '${clock(start)} – ${clock(end)}';

  /// Body of the range sheet.
  static const String rangeBody = 'This part has more layers or effects than live playback handles smoothly on this device. '
      'Render it once and it plays smoothly until you change it.';

  /// Range sheet: render this part.
  static const String renderThis = 'Render this part';

  /// Range sheet: render every part that needs it.
  static const String renderAll = 'Render all';

  /// Range sheet: rendering in progress.
  static String rendering(double? fraction) =>
      fraction == null ? 'Rendering…' : 'Rendering… ${(fraction.clamp(0, 1) * 100).round()}%';

  // ---- Settings -----------------------------------------------------------------------------------

  /// Section header.
  static const String section = 'Render preview';

  /// Setting title.
  static const String settingTitle = 'Render preview';

  /// The one-line trade-off.
  static const String settingDescription =
      'Pre-render heavy parts of the timeline so they play smoothly. Uses storage and battery; never changes your export.';

  /// Option label.
  static String settingLabel(RenderPreviewSetting setting) => switch (setting) {
        RenderPreviewSetting.auto => 'Auto',
        RenderPreviewSetting.manual => 'Manual',
      };

  /// Hint under the choice; [isDefault] marks this device's default.
  static String settingHint(RenderPreviewSetting setting, {required bool isDefault}) {
    final text = switch (setting) {
      RenderPreviewSetting.auto => 'Heavy parts render in the background while the editor is idle and the device is charging.',
      RenderPreviewSetting.manual => 'Parts render only when you choose Render preview.',
    };
    return isDefault ? '$text Recommended for this device.' : text;
  }

  /// Hint when Auto is chosen on a device that never renders automatically.
  static const String autoNotOnThisDevice =
      'This device plays most projects live, so nothing renders automatically. Use Render preview when a part stutters.';

  /// Clear row title.
  static const String clearTitle = 'Clear rendered previews';

  /// Clear row subtitle with the current size.
  static String clearSubtitle(int? bytes) => bytes == null ? 'Measuring…' : (bytes == 0 ? 'Nothing rendered' : '${size(bytes)} rendered');

  /// Clear button.
  static const String clear = 'Clear';

  /// Clear confirmation title.
  static const String clearConfirmTitle = 'Clear rendered previews?';

  /// Clear confirmation message.
  static const String clearConfirmMessage =
      'Rendered parts play live again until they are rendered again. Your projects are not changed.';

  /// Clear toast.
  static const String cleared = 'Rendered previews cleared';

  /// Clear is unavailable (no cache on this device).
  static const String clearUnavailable = 'Nothing to clear.';

  // ---- Formatting -------------------------------------------------------------------------------

  /// `m:ss` (or `h:mm:ss`) of [t].
  static String clock(TimeUs t) {
    final total = (t < 0 ? 0 : t) ~/ microsPerSecond;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  /// `12 MB`, `1.2 GB`, `640 KB`.
  static String size(int bytes) {
    const kb = 1024, mb = 1024 * 1024, gb = 1024 * 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).round()} MB';
    if (bytes >= kb) return '${(bytes / kb).round()} KB';
    return '$bytes B';
  }
}

/// What the manual "Render preview" action renders (ARCH §17.5).
enum RenderTargetKind {
  /// One range of the render marker.
  range,

  /// The selected items' span.
  selection,

  /// The transport loop range.
  loop,

  /// Every range of the timeline.
  timeline,
}
