// OWNER: UX-37
//
// The speech-model download consent (ai.md §5.5, §11.3; ux.md §12.2 step 2; ARCH §16.3, §20.2).
// It shows exactly the `ConsentDisclosure` the download will be checked against (file, size incl.
// the voice-detection model, host huggingface.co with its CDN hf.co, SHA-256) and is the ONLY place
// a `UserConsent` is constructed (ARCH §4.2 rule 8, architecture test): tapping Download builds it
// from that disclosure and hands it to [ModelConsentView.onAccept]. Nothing is remembered; every
// download asks again.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_transcription/danaview_transcription.dart' show ConsentDisclosure, UserConsent;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/strings/captions_strings.dart';
import 'captions_progress_panel.dart' show CaptionsText;

/// Step 2 of 2: "Download the speech model?".
class ModelConsentView extends StatelessWidget {
  /// Creates the view for [disclosure].
  const ModelConsentView({
    super.key,
    required this.disclosure,
    required this.onAccept,
    required this.onDecline,
    this.corrupt = false,
    this.missingSpaceBytes,
    this.onOpenPrivacyPolicy,
    this.clock = DateTime.now,
  });

  /// What will be downloaded (from `ConsentDisclosure.of(spec)`).
  final ConsentDisclosure disclosure;

  /// Receives the user's consent to this one download.
  final ValueChanged<UserConsent> onAccept;

  /// "Not now".
  final VoidCallback onDecline;

  /// The installed model is damaged ("Download again").
  final bool corrupt;

  /// Free space needed when the device lacks it (Download is disabled), else null.
  final int? missingSpaceBytes;

  /// Opens the Privacy Policy; null hides the link.
  final VoidCallback? onOpenPrivacyPolicy;

  /// The time stamped on the consent.
  final DateTime Function() clock;

  void _accept() => onAccept(UserConsent.accepted(disclosure, acceptedAt: clock().toUtc()));

  @override
  Widget build(BuildContext context) {
    final d = disclosure;
    final space = missingSpaceBytes;
    return Column(
      key: const ValueKey('captions-consent'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DanaviewStepIndicator(step: 2, count: 2, semanticLabel: CaptionsStrings.stepConsent),
        const SizedBox(height: DanaviewSpacing.md),
        const Align(
          alignment: AlignmentDirectional.centerStart,
          child: DanaviewTileIcon(Icons.cloud_download_rounded, size: 40),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        Semantics(
          header: true,
          child: Text(corrupt ? CaptionsStrings.consentTitleCorrupt : CaptionsStrings.consentTitle, style: CaptionsText.headline),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        Text(CaptionsStrings.consentBody(d), style: CaptionsText.body),
        const SizedBox(height: DanaviewSpacing.md),
        _Details(disclosure: d),
        if (space != null) ...[
          const SizedBox(height: DanaviewSpacing.md),
          Row(
            key: const ValueKey('captions-consent-space'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: DanaviewColors.warning),
              const SizedBox(width: DanaviewSpacing.sm),
              Expanded(child: Text(CaptionsStrings.notEnoughSpace(space), style: CaptionsText.body)),
            ],
          ),
        ],
        if (onOpenPrivacyPolicy != null) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: DanaviewButton.ghost(
              key: const ValueKey('captions-consent-privacy'),
              label: CaptionsStrings.privacyPolicy,
              icon: Icons.privacy_tip_outlined,
              size: DanaviewButtonSize.sm,
              onPressed: onOpenPrivacyPolicy,
            ),
          ),
        ],
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(key: const ValueKey('captions-consent-decline'), label: CaptionsStrings.notNow, onPressed: onDecline),
            DanaviewButton.primary(
              key: const ValueKey('captions-consent-accept'),
              label: corrupt ? CaptionsStrings.downloadAgain(d) : CaptionsStrings.download(d),
              icon: Icons.download_rounded,
              onPressed: space == null ? _accept : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.disclosure});

  final ConsentDisclosure disclosure;

  @override
  Widget build(BuildContext context) {
    final d = disclosure;
    return Container(
      key: const ValueKey('captions-consent-details'),
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      decoration: const BoxDecoration(
        color: DanaviewColors.surfaceElevatedHigher,
        borderRadius: DanaviewRadius.mdAll,
        border: DanaviewBorders.all,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(CaptionsStrings.details, style: CaptionsText.section),
          const SizedBox(height: DanaviewSpacing.xs),
          _Row(label: CaptionsStrings.fileLabel, value: CaptionsStrings.fileValue(d)),
          _Row(label: CaptionsStrings.sizeLabel, value: CaptionsStrings.sizeValue(d), spoken: '${d.totalBytes} bytes'),
          _Row(label: CaptionsStrings.hostLabel, value: CaptionsStrings.hostValue(d)),
          _Row(label: CaptionsStrings.checksumLabel, value: d.sha256, mono: true),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.spoken, this.mono = false});

  final String label;
  final String value;
  final String? spoken;
  final bool mono;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
        child: Semantics(
          label: '$label: ${spoken ?? value}',
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: CaptionsText.caption),
              Text(value, style: mono ? CaptionsText.body.copyWith(fontSize: 12, letterSpacing: 0.2) : CaptionsText.body),
            ],
          ),
        ),
      );
}
