// OWNER: UX-38
//
// Settings › Video editor › Auto captions (ARCH §17.10, ai.md §5.6, §11.5, ux.md §4.8), shown by
// `EditorSettingsScreen` only with DANAVIEW_AUTO_CAPTIONS (D-31):
//
// * One row per speech-model tier the device may use: its size and status ("57 MB · Ready",
//   "Downloading… 23 of 57 MB", "Damaged", "Not downloaded"). Installed (or damaged) tiers offer
//   **Delete** behind a destructive confirmation; while an Auto captions job runs the action is
//   disabled and the row says "In use by auto captions". Models are downloaded from the Auto captions
//   sheet, where the consent view is (ai.md §5.5).
// * **Default layout**: the segmentation preset new Auto captions start with
//   (`editor.captions.defaultPreset`, read by the Auto captions controller).
// * The on-device privacy note.
//
// Everything refreshes on the service's events (model status changes, jobs starting and ending).

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show SegmentationPreset;
import 'package:danaview_features/chrome.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../app/editor_prefs.dart';
import '../app/editor_providers.dart';
import '../app/speech_storage_contributor.dart' show SpeechStorageStrings;
import '../app/strings/captions_strings.dart';
import '../editor/flows/captions/auto_captions_controller.dart' show AutoCaptionsController;

/// Copy of the captions settings section (ai.md §11.5).
abstract final class CaptionsSettingsStrings {
  /// Section header.
  static const String section = 'Auto captions';

  /// Models group label.
  static const String models = 'Speech models';

  /// Status: installed.
  static String ready(SpeechModelSpec spec) => '${CaptionsStrings.megabytes(spec.bytes)} · Ready';

  /// Status: not installed.
  static String missing(SpeechModelSpec spec) => '${CaptionsStrings.megabytes(spec.bytes)} · Not downloaded';

  /// Status: damaged.
  static const String corrupt = 'Damaged. Delete it, then download it again from Auto captions.';

  /// Status: downloading.
  static String downloading(ModelDownloadProgress p) =>
      'Downloading… ${CaptionsStrings.ofMegabytes(p.received, p.total)}';

  /// Status: still being read.
  static const String checking = 'Checking…';

  /// Recommended for this device.
  static const String recommended = 'Recommended';

  /// Where models come from.
  static const String downloadHint = 'Speech models download from Auto captions, after you agree.';

  /// The device can't run Auto captions.
  static const String unsupported = "Auto captions aren't available on this device.";

  /// Delete button.
  static const String delete = 'Delete';

  /// Deleted toast.
  static String deleted(SpeechModelTier tier) => '${CaptionsStrings.tierName(tier)} speech model deleted';

  /// Default layout title.
  static const String layoutTitle = 'Default layout';

  /// Default layout description.
  static const String layoutDescription = 'How new auto captions are split into lines. You can change it each time.';
}

/// Speech model status, size, delete and default preset (ai.md §11.5).
class CaptionsSettingsSection extends ConsumerStatefulWidget {
  /// Creates the section.
  const CaptionsSettingsSection({super.key});

  @override
  ConsumerState<CaptionsSettingsSection> createState() => _CaptionsSettingsSectionState();
}

class _CaptionsSettingsSectionState extends ConsumerState<CaptionsSettingsSection> {
  TranscriptionService? _service;
  bool _supported = true;
  List<SpeechModelOffer> _offers = const [];
  final Map<String, SpeechModelStatus> _statuses = {};
  bool _jobRunning = false;
  final Set<String> _deleting = {};
  StreamSubscription<TranscriptionEvent>? _events;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    try {
      _service = ref.read(transcriptionServiceProvider);
    } on Object {
      _service = null;
      _supported = false;
    }
    final service = _service;
    if (service == null) return;
    _offers = AutoCaptionsController.visibleOffers(service.offers);
    _jobRunning = service.activeJob != null;
    _events = service.events.listen(_onEvent, onError: (Object _) {});
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  void _onEvent(TranscriptionEvent e) {
    if (!mounted) return;
    switch (e) {
      case ModelStatusChanged(:final modelId, :final status):
        setState(() => _statuses[modelId] = status);
      case JobStarted():
        setState(() => _jobRunning = true);
      case JobEnded():
        setState(() => _jobRunning = _service?.activeJob != null);
    }
  }

  Future<void> _load() async {
    final service = _service;
    if (service == null) return;
    final token = ++_token;
    var supported = true;
    try {
      supported = await service.support() is TranscriptionSupported;
    } on Object {
      supported = false;
    }
    final statuses = <String, SpeechModelStatus>{};
    for (final o in _offers) {
      try {
        statuses[o.spec.id] = await service.modelStatusOf(o.spec.id);
      } on Object {
        statuses[o.spec.id] = const SpeechModelMissing();
      }
    }
    if (!mounted || token != _token) return;
    setState(() {
      _supported = supported && _offers.any((o) => o.available);
      _statuses
        ..clear()
        ..addAll(statuses);
      _jobRunning = service.activeJob != null;
    });
  }

  Future<void> _delete(SpeechModelSpec spec) async {
    final service = _service;
    if (service == null || _deleting.contains(spec.id)) return;
    final ok = await showDanaviewConfirm(
      context,
      title: SpeechStorageStrings.deleteTitle,
      message: SpeechStorageStrings.deleteMessage(spec.bytes),
      confirmLabel: SpeechStorageStrings.delete,
      destructive: true,
      icon: Icons.delete_outline_rounded,
    );
    if (!ok || !mounted) return;
    if (service.activeJob != null) {
      setState(() => _jobRunning = true);
      DanaviewToast.show(context, SpeechStorageStrings.inUse, kind: DanaviewToastKind.error);
      return;
    }
    setState(() => _deleting.add(spec.id));
    var deleted = false;
    try {
      await service.deleteModelById(spec.id);
      deleted = true;
    } on StateError {
      if (mounted) DanaviewToast.show(context, SpeechStorageStrings.inUse, kind: DanaviewToastKind.error);
    } on Object catch (e) {
      debugPrint('[CaptionsSettings] Delete failed: ${e.runtimeType}');
    }
    if (!mounted) return;
    setState(() => _deleting.remove(spec.id));
    if (deleted) {
      DanaviewToast.show(context, CaptionsSettingsStrings.deleted(spec.tier), kind: DanaviewToastKind.success, icon: Icons.check_rounded);
    }
    await _load();
  }

  String _status(SpeechModelOffer offer) {
    if (!offer.available) return offer.unavailableReason ?? CaptionsSettingsStrings.unsupported;
    final status = _statuses[offer.spec.id];
    final installed = status is SpeechModelReady || status is SpeechModelCorrupt;
    if (_jobRunning && installed) return SpeechStorageStrings.inUse;
    return switch (status) {
      null => CaptionsSettingsStrings.checking,
      SpeechModelReady() => CaptionsSettingsStrings.ready(offer.spec),
      SpeechModelCorrupt() => CaptionsSettingsStrings.corrupt,
      SpeechModelDownloading(:final progress) => CaptionsSettingsStrings.downloading(progress),
      SpeechModelMissing() => CaptionsSettingsStrings.missing(offer.spec),
    };
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(editorPrefsProvider);
    return Column(
      key: const ValueKey('captions-settings'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DanaviewLibrarySectionHeader(CaptionsSettingsStrings.section, topSpacing: 0),
        if (!_supported)
          DanaviewSurface(
            key: const ValueKey('captions-settings-unsupported'),
            color: DanaviewColors.surface,
            padding: const EdgeInsets.all(DanaviewSpacing.md),
            child: Text(CaptionsSettingsStrings.unsupported, style: DanaviewTextStyles.bodySecondary),
          )
        else ...[
          DanaviewLibraryGroup(
            children: [
              for (final offer in _offers)
                _ModelRow(
                  key: ValueKey('captions-settings-model-${offer.spec.tier.name}'),
                  offer: offer,
                  status: _status(offer),
                  installed: _statuses[offer.spec.id] is SpeechModelReady || _statuses[offer.spec.id] is SpeechModelCorrupt,
                  deleteEnabled: !_jobRunning && !_deleting.contains(offer.spec.id),
                  onDelete: () => unawaited(_delete(offer.spec)),
                ),
            ],
          ),
          const SizedBox(height: DanaviewSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
            child: Text(CaptionsSettingsStrings.downloadHint, style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3)),
          ),
          const SizedBox(height: DanaviewSpacing.md),
          ListenableBuilder(
            listenable: prefs,
            builder: (context, _) => _LayoutSetting(prefs: prefs),
          ),
        ],
        const SizedBox(height: DanaviewSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.lock_outline_rounded, size: 16, color: DanaviewColors.textSecondary),
              ),
              const SizedBox(width: DanaviewSpacing.sm),
              Expanded(
                child: Text(
                  CaptionsStrings.onDeviceNote,
                  key: const ValueKey('captions-settings-privacy'),
                  style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    super.key,
    required this.offer,
    required this.status,
    required this.installed,
    required this.deleteEnabled,
    required this.onDelete,
  });

  final SpeechModelOffer offer;
  final String status;
  final bool installed;
  final bool deleteEnabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final name = CaptionsStrings.tierName(offer.spec.tier);
    return Semantics(
      container: true,
      label: '$name. $status',
      excludeSemantics: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: DanaviewSpacing.sm),
        child: Row(
          children: [
            DanaviewTileIcon(
              installed ? Icons.record_voice_over_rounded : Icons.cloud_outlined,
              size: 36,
              color: offer.available ? (installed ? DanaviewColors.success : DanaviewColors.textSecondary) : DanaviewColors.textMuted,
            ),
            const SizedBox(width: DanaviewSpacing.md),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer.recommended ? '$name · ${CaptionsSettingsStrings.recommended}' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.body.copyWith(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status,
                      key: ValueKey('captions-settings-status-${offer.spec.tier.name}'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                    ),
                  ],
                ),
              ),
            ),
            if (installed) ...[
              const SizedBox(width: DanaviewSpacing.sm),
              DanaviewButton.destructive(
                key: ValueKey('captions-settings-delete-${offer.spec.tier.name}'),
                label: CaptionsSettingsStrings.delete,
                size: DanaviewButtonSize.sm,
                semanticLabel: '${CaptionsSettingsStrings.delete} $name speech model',
                onPressed: deleteEnabled ? onDelete : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LayoutSetting extends StatelessWidget {
  const _LayoutSetting({required this.prefs});

  final EditorPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final stored = prefs.captionsDefaultPreset;
    final value = SegmentationPreset.values.where((p) => p.name == stored).firstOrNull ?? SegmentationPreset.standard;
    return DanaviewSurface(
      key: const ValueKey('captions-settings-layout'),
      color: DanaviewColors.surface,
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.xs, DanaviewSpacing.xs, DanaviewSpacing.xs, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const DanaviewTileIcon(Icons.subtitles_rounded, color: DanaviewColors.primaryLight, size: 40),
                const SizedBox(width: DanaviewSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      Semantics(
                        header: true,
                        child: Text(
                          CaptionsSettingsStrings.layoutTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.headline.copyWith(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(CaptionsSettingsStrings.layoutDescription, style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewSegmentedControl<SegmentationPreset>(
            value: value,
            options: [
              for (final p in SegmentationPreset.values) DanaviewOption(value: p, label: CaptionsStrings.presetName(p)),
            ],
            onChanged: (p) => unawaited(prefs.setCaptionsDefaultPreset(p.name)),
          ),
        ],
      ),
    );
  }
}
