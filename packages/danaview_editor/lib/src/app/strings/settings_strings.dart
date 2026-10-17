// OWNER: UX-04
//
// Copy of the Editor settings screen and the editor's Settings › Storage contributors
// (ARCH §17.10, ux.md §4.8). Plain, specific, with a next step (ARCH §19).

import '../editor_prefs.dart';
import '../editor_storage_contributor.dart' show EditorCacheUse;

/// Copy of the Editor settings screen (ARCH §17.10).
abstract final class SettingsStrings {
  /// Screen title (also the Settings row title in `danaview_features`).
  static const String title = 'Video editor';

  /// Back button.
  static const String back = 'Back';

  /// Section: preview.
  static const String previewSection = 'Preview';

  /// Section: timeline.
  static const String timelineSection = 'Timeline';

  /// Section: new projects.
  static const String newProjectsSection = 'New projects';

  /// Proxy media setting title.
  static const String proxyTitle = 'Proxy media';

  /// Proxy media setting description.
  static const String proxyDescription =
      'Edit large or fast videos with lighter copies so playback stays smooth. Exports always use the originals.';

  /// Default preview quality title.
  static const String previewQualityTitle = 'Default preview quality';

  /// Default preview quality description.
  static const String previewQualityDescription = 'How sharp the preview is when a project opens. Exports are always full quality.';

  /// Centre playhead title.
  static const String centerPlayheadTitle = 'Center playhead on touch';

  /// Centre playhead subtitle.
  static const String centerPlayheadSubtitle = 'Scroll the timeline under a fixed playhead.';

  /// Snapping haptics title.
  static const String snappingHapticsTitle = 'Snapping haptics';

  /// Snapping haptics subtitle.
  static const String snappingHapticsSubtitle = 'A light tap when a clip snaps into place.';

  /// Default aspect title.
  static const String aspectTitle = 'Default format';

  /// Default aspect description.
  static const String aspectDescription = 'Preselected when you create a project. Each project can change it later.';

  /// Label of a [ProxyMediaMode].
  static String proxyLabel(ProxyMediaMode mode) => switch (mode) {
        ProxyMediaMode.auto => 'Auto',
        ProxyMediaMode.always => 'Always',
        ProxyMediaMode.off => 'Off',
      };

  /// Explanation of the selected [ProxyMediaMode].
  static String proxyHint(ProxyMediaMode mode) => switch (mode) {
        ProxyMediaMode.auto => 'Recommended: proxies are made only for media that needs them.',
        ProxyMediaMode.always => 'Every video gets a proxy. Uses more storage.',
        ProxyMediaMode.off => 'Large videos may play back slowly while editing.',
      };

  /// Appended to the hint of the proxy mode that is this device's tier default (Always on
  /// minimal/low devices).
  static const String proxyTierDefaultMark = 'Recommended for this device.';

  /// Hint of Auto where the tier default is another mode (Auto is then not the recommendation).
  static const String proxyAutoNotDefault = 'Proxies are made only for media that needs them.';

  /// Label of a [PreviewQualityPreference].
  static String previewQualityLabel(PreviewQualityPreference quality) => switch (quality) {
        PreviewQualityPreference.auto => 'Auto',
        PreviewQualityPreference.full => 'Full',
        PreviewQualityPreference.half => 'Half',
      };

  /// Label of a [NewProjectAspect].
  static String aspectLabel(NewProjectAspect aspect) => switch (aspect) {
        NewProjectAspect.matchFirstClip => 'Match first clip',
        NewProjectAspect.landscape16x9 => '16:9',
        NewProjectAspect.portrait9x16 => '9:16',
        NewProjectAspect.square => '1:1',
        NewProjectAspect.portrait4x5 => '4:5',
      };
}

/// Copy of the editor's Settings › Storage contributors (ARCH §17.10).
abstract final class StorageStrings {
  /// Section header on the Storage screen.
  static const String section = 'Video editor';

  /// Projects contributor title.
  static const String projectsTitle = 'Video editor projects';

  /// Projects contributor explanation.
  static const String projectsSubtitle = 'Projects keep their recordings, stills and copies of picked media. '
      'Delete projects in Projects to free that space; your original videos, photos and music are never touched.';

  /// Spoken after the projects row.
  static const String openProjects = 'Opens Projects';

  /// `1 project`, `3 projects`.
  static String projectCount(int count) => count == 1 ? '1 project' : '$count projects';

  /// Cache contributor title.
  static const String cacheTitle = 'Editor cache';

  /// Cache contributor explanation.
  static const String cacheSubtitle = 'The editor cache holds thumbnails, waveforms and preview files that are made again when needed.';

  /// Cache clear row and confirmation title.
  static const String clearCache = 'Clear editor cache';

  /// Cache clear confirmation message.
  static const String clearCacheMessage = 'Thumbnails, waveforms, preview proxies and look previews are deleted '
      'and made again when needed. Your projects and media stay.';

  /// Cache clear confirmation button.
  static const String clearCacheConfirm = 'Clear';

  /// Cache cleared with nothing to free.
  static const String cacheAlreadyEmpty = 'The editor cache is already empty';

  /// Why the cache can't be cleared right now.
  static String cacheBlocked(EditorCacheUse use) => switch (use) {
        EditorCacheUse.none => '',
        EditorCacheUse.projectOpen => 'Close the video editor to clear its cache.',
        EditorCacheUse.exportRunning => 'An export is running. Clear the cache when it finishes.',
        EditorCacheUse.captionsRunning => 'Auto captions are running. Clear the cache when they finish.',
        EditorCacheUse.jobRunning => 'The editor is still preparing media. Try again in a moment.',
      };
}
