// OWNER: UX-01
//
// EditorPrefs (ARCH §17.10): `editor.` keys, defaults, persistence through SharedPreferences,
// change notifications and key hygiene.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_editor/danaview_editor.dart';

void main() {
  test('defaults', () {
    final p = EditorPrefs.memory();
    expect(p.proxyMedia, ProxyMediaMode.auto);
    expect(p.previewQuality, PreviewQualityPreference.auto);
    expect(p.centerPlayheadOnTouch, isTrue);
    expect(p.snappingHaptics, isTrue);
    expect(p.newProjectAspect, NewProjectAspect.matchFirstClip);
    expect(p.projectsSort, ProjectSortPreference.recent);
    expect(p.splitRatio('compactPortrait'), isNull);
    expect(p.exportBackgroundNoticeShown, isFalse);
    expect(p.exportNotificationPermissionAsked, isFalse);
    expect(p.captionsDefaultPreset, isNull);
  });

  test('typed setters write editor. keys and notify once per change', () async {
    final p = EditorPrefs.memory();
    var notified = 0;
    p.addListener(() => notified++);
    await p.setProxyMedia(ProxyMediaMode.always);
    await p.setPreviewQuality(PreviewQualityPreference.half);
    await p.setCenterPlayheadOnTouch(false);
    await p.setSnappingHaptics(false);
    await p.setNewProjectAspect(NewProjectAspect.portrait9x16);
    await p.setProjectsSort(ProjectSortPreference.name);
    await p.setSplitRatio('medium', 0.4);
    await p.markExportBackgroundNoticeShown();
    await p.markExportNotificationPermissionAsked();
    await p.setCaptionsDefaultPreset('balanced');
    expect(notified, 10);
    await p.setProxyMedia(ProxyMediaMode.always);
    expect(notified, 10, reason: 'writing the same value does not notify');
    expect(p.editorKeys, {
      EditorPrefKeys.proxyMedia,
      EditorPrefKeys.previewQuality,
      EditorPrefKeys.centerPlayheadOnTouch,
      EditorPrefKeys.snappingHaptics,
      EditorPrefKeys.newProjectAspect,
      EditorPrefKeys.projectsSort,
      'editor.layout.splitRatio.medium',
      EditorPrefKeys.exportBackgroundNoticeShown,
      EditorPrefKeys.exportNotificationPermissionAsked,
      EditorPrefKeys.captionsDefaultPreset,
    });
    expect(p.editorKeys.every((k) => k.startsWith('editor.')), isTrue);
    expect(p.splitRatio('medium'), 0.4);
    expect(p.newProjectAspect, NewProjectAspect.portrait9x16);
  });

  test('unknown or corrupt stored values fall back to defaults', () {
    final p = EditorPrefs.memory({
      EditorPrefKeys.proxyMedia: 'sometimes',
      EditorPrefKeys.centerPlayheadOnTouch: 'yes',
      'editor.layout.splitRatio.expanded': 1.7,
    });
    expect(p.proxyMedia, ProxyMediaMode.auto);
    expect(p.centerPlayheadOnTouch, isTrue);
    expect(p.splitRatio('expanded'), isNull);
  });

  test('rejects keys without the editor. prefix and invalid split ratios', () {
    final p = EditorPrefs.memory();
    expect(() => p.readString('player.volume'), throwsArgumentError);
    expect(() => p.writeBool('editor.', true), throwsArgumentError);
    expect(() => p.setSplitRatio('medium', 1.0), throwsArgumentError);
    expect(() => p.setSplitRatio('medium', double.nan), throwsArgumentError);
  });

  test('generic access and clearEditorKeys keep other app preferences', () async {
    final backend = MemoryEditorPrefsBackend({'player.volume': 0.8, 'editor.export.last.pr_1': '{"fps":30}'});
    final p = EditorPrefs(backend);
    await p.writeInt('editor.captions.lastTier', 2);
    expect(p.readInt('editor.captions.lastTier'), 2);
    expect(p.readString('editor.export.last.pr_1'), '{"fps":30}');
    expect(p.readDouble('editor.captions.lastTier'), 2.0);
    await p.clearEditorKeys();
    expect(backend.values, {'player.volume': 0.8});
  });

  test('persists through SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({'editor.proxyMedia': 'off', 'other.key': 'kept'});
    final p = await EditorPrefs.load();
    expect(p.proxyMedia, ProxyMediaMode.off);
    await p.setSnappingHaptics(false);
    await p.setSplitRatio('compactLandscape', 0.55);
    final again = await EditorPrefs.load();
    expect(again.snappingHaptics, isFalse);
    expect(again.splitRatio('compactLandscape'), 0.55);
    expect((await SharedPreferences.getInstance()).getString('other.key'), 'kept');
  });
}
