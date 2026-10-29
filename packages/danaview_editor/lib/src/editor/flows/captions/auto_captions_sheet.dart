// OWNER: UX-37
//
// The Auto captions sheet (ai.md §11, ux.md §12.2): one `showDanaviewSheet(title: 'Auto captions')`
// that follows `AutoCaptionsController`: checking, unsupported, configure (step 1 of 2: language,
// quality, scope, layout, Advanced), consent (step 2 of 2, `ModelConsentView`), download and job
// progress (`CaptionsProgressPanel`), the low-confidence language question, and failures. When the
// captions were added the sheet closes and a toast says how many. Closing the sheet while work runs
// only hides it: the controller keeps running and shows a row in the Tasks sheet.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_messages.dart';
import '../../../app/editor_providers.dart';
import '../../../app/strings/captions_strings.dart';
import 'auto_captions_controller.dart';
import 'captions_progress_panel.dart';
import 'language_picker.dart';
import 'model_consent_view.dart';

/// The Auto captions flow sheet (ux.md §12.2).
class AutoCaptionsSheet extends ConsumerStatefulWidget {
  /// Creates the sheet content for [projectId]; use [show] to present it.
  const AutoCaptionsSheet({super.key, required this.projectId});

  /// The project.
  final ProjectId projectId;

  /// Opens the flow for [projectId] and shows the sheet. [scope] preselects "This clip";
  /// [regenerateFrom] and [replaceTrack] start from an earlier run (UX-38). While a download or job
  /// runs the sheet shows its progress.
  static Future<void> show(
    BuildContext context, {
    required ProjectId projectId,
    TranscriptionScope? scope,
    CaptionProvenance? regenerateFrom,
    TrackId? replaceTrack,
  }) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final provider = autoCaptionsControllerProvider(projectId);
    final hold = container.listen<AutoCaptionsState>(provider, (_, __) {});
    try {
      final controller = container.read(provider.notifier);
      controller.toaster = (message) {
        if (context.mounted) DanaviewToast.show(context, message, kind: DanaviewToastKind.success, icon: Icons.closed_caption_rounded);
      };
      unawaited(controller.open(scope: scope, regenerateFrom: regenerateFrom, replaceTrack: replaceTrack));
      await showDanaviewSheet<void>(
        context,
        title: CaptionsStrings.title,
        builder: (_) => AutoCaptionsSheet(projectId: projectId),
      );
    } finally {
      hold.close();
    }
  }

  @override
  ConsumerState<AutoCaptionsSheet> createState() => _AutoCaptionsSheetState();
}

class _AutoCaptionsSheetState extends ConsumerState<AutoCaptionsSheet> {
  bool _picking = false;
  bool _advanced = false;
  String? _chosen;

  AutoCaptionsController get _controller => ref.read(autoCaptionsControllerProvider(widget.projectId).notifier);

  void _close() {
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _cancelJob() async {
    final controller = _controller;
    if (controller.cancelNeedsConfirm) {
      final stop = await showDanaviewConfirm(
        context,
        title: CaptionsStrings.cancelConfirmTitle,
        message: CaptionsStrings.cancelConfirmMessage,
        confirmLabel: CaptionsStrings.stop,
        cancelLabel: CaptionsStrings.keepGoing,
        destructive: true,
        icon: Icons.stop_circle_outlined,
      );
      if (!stop || !mounted) return;
    }
    controller.cancel();
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.projectId;
    final state = ref.watch(autoCaptionsControllerProvider(id));
    ref.listen<AutoCaptionsState>(autoCaptionsControllerProvider(id), (previous, next) {
      if (next.stage == AutoCaptionsStage.done && previous?.stage != AutoCaptionsStage.done) _close();
      if (next.stage != previous?.stage) {
        _picking = false;
        _chosen = null;
      }
    });
    final controller = _controller;
    final Widget body = switch (state.stage) {
      AutoCaptionsStage.checking || AutoCaptionsStage.done => const _Checking(),
      AutoCaptionsStage.unsupported => _Message(
          key: const ValueKey('captions-unsupported'),
          icon: Icons.closed_caption_disabled_rounded,
          copy: CaptionsStrings.unsupported,
          actions: [DanaviewButton.secondary(label: CaptionsStrings.close, onPressed: _close)],
        ),
      AutoCaptionsStage.configure when _picking => LanguagePicker(
          languages: controller.languages,
          selected: state.draft.language,
          recent: controller.recentLanguages,
          deviceLanguage: controller.deviceLanguage,
          onBack: () => setState(() => _picking = false),
          onSelected: (language) {
            controller.update((d) => d.copyWith(language: language));
            setState(() => _picking = false);
          },
        ),
      AutoCaptionsStage.configure => _ConfigureView(
          state: state,
          controller: controller,
          advanced: _advanced,
          onToggleAdvanced: () => setState(() => _advanced = !_advanced),
          onPickLanguage: () => setState(() => _picking = true),
          onCancel: _close,
        ),
      AutoCaptionsStage.consent => ModelConsentView(
          disclosure: state.disclosure!,
          corrupt: state.modelCorrupt,
          missingSpaceBytes: state.missingSpaceBytes,
          onOpenPrivacyPolicy: ref.watch(autoCaptionsHostProvider).onOpenPrivacyPolicy,
          onAccept: (consent) => unawaited(controller.acceptConsent(consent)),
          onDecline: controller.declineConsent,
        ),
      AutoCaptionsStage.downloading => CaptionsProgressPanel.download(
          download: state.download,
          resumed: state.downloadResumed,
          onCancel: () {
            controller.cancelDownload();
            _close();
          },
        ),
      AutoCaptionsStage.running || AutoCaptionsStage.waitingForExport => CaptionsProgressPanel.job(
          progress: state.progress,
          waitingForExport: state.stage == AutoCaptionsStage.waitingForExport,
          onCancel: () => unawaited(_cancelJob()),
          onHide: _close,
        ),
      AutoCaptionsStage.needsLanguage when _picking => LanguagePicker(
          languages: controller.languages,
          selected: _chosen == null ? null : FixedLanguage(_chosen!),
          recent: controller.recentLanguages,
          deviceLanguage: controller.deviceLanguage,
          allowAuto: false,
          onBack: () => setState(() => _picking = false),
          onSelected: (language) {
            if (language is FixedLanguage) controller.provideLanguage(language.code);
          },
        ),
      AutoCaptionsStage.needsLanguage => _NeedsLanguageView(
          candidates: state.progress?.languageCandidates ?? const [],
          chosen: _chosen,
          onChoose: (code) => setState(() => _chosen = code),
          onOther: () => setState(() => _picking = true),
          onContinue: _chosen == null ? null : () => controller.provideLanguage(_chosen!),
          onCancel: () => unawaited(_cancelJob()),
        ),
      AutoCaptionsStage.failed => _FailedView(state: state, controller: controller, onClose: _close),
    };
    return Semantics(
      container: true,
      label: CaptionsStrings.title,
      child: KeyedSubtree(key: const ValueKey('captions-sheet'), child: body),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Simple states
// -------------------------------------------------------------------------------------------------

class _Checking extends StatelessWidget {
  const _Checking();

  @override
  Widget build(BuildContext context) => Padding(
        key: const ValueKey('captions-checking'),
        padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xl),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const DanaviewSpinner(size: 20, semanticLabel: CaptionsStrings.checking),
            const SizedBox(width: DanaviewSpacing.md),
            Flexible(child: Text(CaptionsStrings.checking, style: CaptionsText.secondary)),
          ],
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.icon, required this.copy, required this.actions, this.iconColor = DanaviewColors.textSecondary});

  final IconData icon;
  final Color iconColor;
  final CaptionsFailureCopy copy;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: AlignmentDirectional.centerStart, child: DanaviewIconTile(icon, size: 40, color: iconColor)),
          const SizedBox(height: DanaviewSpacing.sm),
          Semantics(header: true, child: Text(copy.title, key: const ValueKey('captions-message-title'), style: CaptionsText.headline)),
          const SizedBox(height: DanaviewSpacing.xs),
          Text(copy.message, key: const ValueKey('captions-message-body'), style: CaptionsText.body),
          const SizedBox(height: DanaviewSpacing.lg),
          DanaviewButtonBar(children: actions),
        ],
      );
}

class _FailedView extends StatelessWidget {
  const _FailedView({required this.state, required this.controller, required this.onClose});

  final AutoCaptionsState state;
  final AutoCaptionsController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final failure = state.failure;
    final rejection = state.applyRejection;
    final CaptionsFailureCopy copy;
    if (failure != null) {
      copy = CaptionsStrings.failure(failure) ?? CaptionsStrings.notApplied;
    } else if (rejection != null) {
      final m = EditorMessages.forRejection(rejection);
      copy = CaptionsFailureCopy(m.title, m.detail ?? CaptionsStrings.notApplied.message);
    } else {
      copy = CaptionsStrings.notApplied;
    }
    final actions = <Widget>[
      DanaviewButton.secondary(key: const ValueKey('captions-back'), label: CaptionsStrings.back, onPressed: controller.back),
    ];
    switch (failure) {
      case InsufficientMemoryFailure(:final suggestedTier?):
        actions.add(DanaviewButton.primary(
          key: const ValueKey('captions-use-tier'),
          label: CaptionsStrings.useTier(suggestedTier),
          onPressed: controller.useSuggestedTier,
        ));
      case UnsupportedDeviceFailure() || NoSpeechFailure() || NoAudioFailure():
        actions
          ..clear()
          ..add(DanaviewButton.secondary(key: const ValueKey('captions-back'), label: CaptionsStrings.back, onPressed: controller.back))
          ..add(DanaviewButton.primary(key: const ValueKey('captions-close'), label: CaptionsStrings.close, onPressed: onClose));
      case ModelCorruptFailure() || ModelMissingFailure() || ModelDownloadFailure():
        actions.add(DanaviewButton.primary(
          key: const ValueKey('captions-retry'),
          label: failure is ModelDownloadFailure ? CaptionsStrings.tryAgain : CaptionsStrings.reviewDownload,
          onPressed: () => unawaited(controller.retry()),
        ));
      default:
        if (failure == null ||
            failure.retryable ||
            failure is UnsupportedAudioFailure ||
            failure is DiskFullFailure ||
            failure is MediaOfflineFailure) {
          actions.add(DanaviewButton.primary(
            key: const ValueKey('captions-retry'),
            label: CaptionsStrings.tryAgain,
            onPressed: () => unawaited(controller.retry()),
          ));
        }
    }
    return _Message(
      key: const ValueKey('captions-failed'),
      icon: failure is NoSpeechFailure ? Icons.voice_over_off_rounded : Icons.error_outline_rounded,
      iconColor: failure is NoSpeechFailure ? DanaviewColors.textSecondary : DanaviewColors.errorLight,
      copy: copy,
      actions: actions,
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Needs language (D-19: confidence < 0.6 → choose from the top 3)
// -------------------------------------------------------------------------------------------------

class _NeedsLanguageView extends StatelessWidget {
  const _NeedsLanguageView({
    required this.candidates,
    required this.chosen,
    required this.onChoose,
    required this.onOther,
    required this.onContinue,
    required this.onCancel,
  });

  final List<LanguageProbability> candidates;
  final String? chosen;
  final ValueChanged<String> onChoose;
  final VoidCallback onOther;
  final VoidCallback? onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('captions-needs-language'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: Text(CaptionsStrings.whichLanguage, style: CaptionsText.headline)),
          const SizedBox(height: DanaviewSpacing.xs),
          Text(CaptionsStrings.notSure, style: CaptionsText.secondary),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewChipGroup(
            children: [
              for (final c in candidates.take(3))
                DanaviewChoiceChip(
                  key: ValueKey('captions-candidate-${c.code}'),
                  label: CaptionsStrings.candidate(c),
                  selected: chosen == c.code,
                  onTap: () => onChoose(c.code),
                ),
            ],
          ),
          const SizedBox(height: DanaviewSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: DanaviewButton.ghost(
              key: const ValueKey('captions-other-language'),
              label: CaptionsStrings.otherLanguage,
              icon: Icons.translate_rounded,
              onPressed: onOther,
            ),
          ),
          const SizedBox(height: DanaviewSpacing.lg),
          DanaviewButtonBar(
            children: [
              DanaviewButton.secondary(key: const ValueKey('captions-cancel'), label: CaptionsStrings.cancel, onPressed: onCancel),
              DanaviewButton.primary(key: const ValueKey('captions-continue'), label: CaptionsStrings.continueLabel, onPressed: onContinue),
            ],
          ),
        ],
      );
}

// -------------------------------------------------------------------------------------------------
// Configure (step 1 of 2)
// -------------------------------------------------------------------------------------------------

class _ConfigureView extends StatelessWidget {
  const _ConfigureView({
    required this.state,
    required this.controller,
    required this.advanced,
    required this.onToggleAdvanced,
    required this.onPickLanguage,
    required this.onCancel,
  });

  final AutoCaptionsState state;
  final AutoCaptionsController controller;
  final bool advanced;
  final VoidCallback onToggleAdvanced;
  final VoidCallback onPickLanguage;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final draft = state.draft;
    final language = switch (draft.language) {
      FixedLanguage(:final code) => languageForWhisperCode(code),
      AutoLanguage() => null,
    };
    final preset = draft.segmentation.preset;
    return Column(
      key: const ValueKey('captions-configure'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DanaviewStepIndicator(step: 1, count: 2, semanticLabel: CaptionsStrings.stepConfigure),
        _Label(CaptionsStrings.spokenLanguage),
        DanaviewListTile(
          key: const ValueKey('captions-language'),
          title: language?.englishName ?? CaptionsStrings.detectAutomatically,
          subtitle:
              language == null ? CaptionsStrings.detectHint : (language.nativeName == language.englishName ? null : language.nativeName),
          subtitleMaxLines: 2,
          leading: const Icon(Icons.translate_rounded, size: 20, color: DanaviewColors.textSecondary),
          showChevron: true,
          onTap: onPickLanguage,
        ),
        _Label(CaptionsStrings.quality),
        DanaviewChipGroup(
          key: const ValueKey('captions-tiers'),
          children: [
            for (final o in state.offers)
              MergeSemantics(
                key: ValueKey('captions-tier-${o.spec.tier.name}-semantics'),
                child: Semantics(
                  hint: o.available ? null : (o.unavailableReason ?? CaptionsStrings.unsupported.title),
                  child: DanaviewChoiceChip(
                    key: ValueKey('captions-tier-${o.spec.tier.name}'),
                    label: CaptionsStrings.tierLabel(o.spec, ready: state.readyModels.contains(o.spec.id)),
                    selected: draft.tier == o.spec.tier,
                    enabled: o.available,
                    onTap: o.available ? () => controller.update((d) => d.copyWith(tier: o.spec.tier)) : null,
                  ),
                ),
              ),
          ],
        ),
        if (state.selection.isNotEmpty) ...[
          _Label(CaptionsStrings.captionsFrom),
          DanaviewSegmentedControl<CaptionsScopeKind>(
            key: const ValueKey('captions-scope'),
            value: draft.scope,
            options: [
              DanaviewOption(value: CaptionsScopeKind.selection, label: CaptionsStrings.selectionScope(state.selection.length)),
              const DanaviewOption(value: CaptionsScopeKind.wholeVideo, label: CaptionsStrings.wholeVideo),
            ],
            onChanged: (v) => controller.update((d) => d.copyWith(scope: v)),
          ),
        ],
        _Label(CaptionsStrings.layout),
        DanaviewSegmentedControl<SegmentationPreset>(
          key: const ValueKey('captions-layout'),
          value: preset,
          options: [
            for (final p in SegmentationPreset.values) DanaviewOption(value: p, label: CaptionsStrings.presetName(p)),
          ],
          onChanged: (p) => controller.update((d) => d.copyWith(segmentation: d.segmentation.copyWith(preset: p))),
        ),
        if (state.generatedTrack != null) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          DanaviewSwitchRow(
            key: const ValueKey('captions-replace'),
            title: CaptionsStrings.replacePrevious,
            subtitle: CaptionsStrings.replacePreviousHint,
            value: draft.replaceGenerated,
            onChanged: (v) => controller.update((d) => d.copyWith(replaceGenerated: v)),
          ),
        ],
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewListTile(
          key: const ValueKey('captions-advanced'),
          title: CaptionsStrings.advanced,
          dense: true,
          toggled: advanced,
          trailing: Icon(advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: DanaviewColors.textSecondary),
          onTap: onToggleAdvanced,
        ),
        if (advanced) _Advanced(state: state, controller: controller),
        const SizedBox(height: DanaviewSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lock_outline_rounded, size: 16, color: DanaviewColors.textSecondary),
            const SizedBox(width: DanaviewSpacing.sm),
            Expanded(child: Text(CaptionsStrings.onDeviceNote, key: const ValueKey('captions-note'), style: CaptionsText.caption)),
          ],
        ),
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(key: const ValueKey('captions-cancel'), label: CaptionsStrings.cancel, onPressed: onCancel),
            DanaviewButton.primary(
              key: const ValueKey('captions-create'),
              label: state.starting ? CaptionsStrings.starting : CaptionsStrings.createCaptions,
              icon: Icons.auto_awesome_rounded,
              onPressed: state.starting || state.selectedOffer?.available != true ? null : () => unawaited(controller.start()),
            ),
          ],
        ),
      ],
    );
  }
}

class _Advanced extends StatelessWidget {
  const _Advanced({required this.state, required this.controller});

  final AutoCaptionsState state;
  final AutoCaptionsController controller;

  @override
  Widget build(BuildContext context) {
    final draft = state.draft;
    final seg = draft.segmentation;
    final wholeVideo = draft.scope == CaptionsScopeKind.wholeVideo || state.selection.isEmpty;
    return Column(
      key: const ValueKey('captions-advanced-section'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wholeVideo && state.audioTracks.isNotEmpty) ...[
          _Label(CaptionsStrings.audioTracks),
          for (final t in state.audioTracks)
            DanaviewSwitchRow(
              key: ValueKey('captions-track-${t.id.value}'),
              title: t.name.isEmpty ? CaptionsStrings.wholeVideo : t.name,
              subtitle: t.music ? CaptionsStrings.musicTrack : null,
              dense: true,
              value: controller.trackIncluded(t),
              onChanged: (v) => controller.setTrackIncluded(t, v),
            ),
        ],
        _Label(CaptionsStrings.maxCharsPerLine),
        DanaviewNumberField(
          key: const ValueKey('captions-max-chars'),
          value: (seg.maxCharsPerLine == 0 ? 42 : seg.maxCharsPerLine).toDouble(),
          min: 12,
          max: 60,
          fractionDigits: 0,
          semanticLabel: CaptionsStrings.maxCharsPerLine,
          onChanged: (v) => controller.update((d) => d.copyWith(segmentation: d.segmentation.copyWith(maxCharsPerLine: v.round()))),
        ),
        _Label(CaptionsStrings.readingSpeed),
        DanaviewNumberField(
          key: const ValueKey('captions-reading-speed'),
          value: seg.maxCharsPerSecond == 0 ? 17 : seg.maxCharsPerSecond,
          min: 8,
          max: 30,
          fractionDigits: 0,
          unit: CaptionsStrings.charsPerSecond,
          semanticLabel: CaptionsStrings.readingSpeed,
          onChanged: (v) =>
              controller.update((d) => d.copyWith(segmentation: d.segmentation.copyWith(maxCharsPerSecond: v.roundToDouble()))),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewSwitchRow(
          key: const ValueKey('captions-sound-descriptions'),
          title: CaptionsStrings.includeSoundDescriptions,
          subtitle: CaptionsStrings.soundDescriptionsHint,
          value: draft.includeSoundDescriptions,
          onChanged: (v) => controller.update((d) => d.copyWith(includeSoundDescriptions: v)),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.md, bottom: DanaviewSpacing.xs),
        child: Text(text, style: CaptionsText.section),
      );
}
