// OWNER: UX-38
//
// Settings › Storage "Speech model" row (ARCH §17.10, ux.md §4.8, ai.md §5.6, §11.5). It shows the
// bytes Auto captions keep on the device for the speech models (installed models, the voice-detection
// model and partial downloads; `TranscriptionService.storage()`), re-measured whenever a model's
// status changes or a job starts or ends. Its clear action is "Delete speech models": a destructive
// confirmation, blocked with "In use by auto captions" while a job runs. Captions already in projects
// stay, and the next use of Auto captions asks for consent again (ai.md §5.5). Cached transcripts are
// project-derived text and are not deleted here; they age out on their own.
//
// The models live under `<support>/danaview/speech`, outside the app's cache folders, so the row owns
// no cache paths. The router (INT-04) lists it in `storageContributorsProvider` on iOS/Android when
// Auto captions are available.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_features/storage.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'strings/captions_strings.dart';
import 'strings/settings_strings.dart' show StorageStrings;

/// Copy of the "Speech model" storage row and the captions settings model rows (ai.md §5.6).
abstract final class SpeechStorageStrings {
  /// Row title.
  static const String title = 'Speech model';

  /// What it holds.
  static const String subtitle = 'The speech-recognition model Auto captions use on this device. '
      'Deleting it keeps the captions already in your projects.';

  /// Clear row label and confirmation title (plural: every tier goes).
  static const String deleteAll = 'Delete speech models';

  /// Confirmation title for one model (ai.md §5.6).
  static const String deleteTitle = 'Delete speech model?';

  /// Confirmation message (ai.md §5.6). [bytes] is what a new download of the default model takes.
  static String deleteMessage(int bytes) =>
      "Auto captions won't work until you download it again (${CaptionsStrings.megabytes(bytes)}). Captions already in your projects stay.";

  /// Confirmation button.
  static const String delete = 'Delete';

  /// Blocked while a job runs (ai.md §5.6).
  static const String inUse = 'In use by auto captions';

  /// Toast when nothing was installed.
  static const String nothingToDelete = 'No speech model is downloaded';

  /// Detail before the size: the installed tiers ("Balanced", "Fast and Balanced").
  static String installed(List<SpeechModelTier> tiers) {
    final names = [for (final t in tiers) CaptionsStrings.tierName(t)];
    if (names.isEmpty) return 'Not downloaded';
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
}

/// The "Speech model" Storage row (ARCH §17.10).
final class SpeechStorageContributor extends StorageContributor {
  /// Creates the row over [service].
  SpeechStorageContributor({required this.service});

  /// The Auto captions service.
  final TranscriptionService service;

  final StreamController<void> _changed = StreamController<void>.broadcast();

  @override
  String get id => 'editor.speech';

  @override
  String get section => StorageStrings.section;

  @override
  String get title => SpeechStorageStrings.title;

  @override
  String get subtitle => SpeechStorageStrings.subtitle;

  @override
  IconData get icon => Icons.record_voice_over_rounded;

  @override
  StorageClearAction get clearAction => StorageClearAction(
        label: SpeechStorageStrings.deleteAll,
        confirmTitle: SpeechStorageStrings.deleteTitle,
        confirmMessage: SpeechStorageStrings.deleteMessage(service.defaultModel.bytes),
        confirmLabel: SpeechStorageStrings.delete,
        destructive: true,
        icon: Icons.delete_outline_rounded,
        run: clear,
      );

  /// Measured now, after every [clear], and whenever a model's status changes or a job starts or
  /// ends (the delete action is blocked while a job runs).
  @override
  Stream<StorageContributorUsage> watchUsage() {
    late final StreamController<StorageContributorUsage> out;
    StreamSubscription<void>? changed;
    StreamSubscription<TranscriptionEvent>? events;
    var token = 0;
    Future<void> emit() async {
      final t = ++token;
      final usage = await measure();
      if (t == token && !out.isClosed) out.add(usage);
    }

    out = StreamController<StorageContributorUsage>(
      onListen: () {
        unawaited(emit());
        changed = _changed.stream.listen((_) => unawaited(emit()));
        events = service.events.listen((_) => unawaited(emit()), onError: (Object _) {});
      },
      onCancel: () async {
        await changed?.cancel();
        await events?.cancel();
      },
    );
    return out.stream.distinct();
  }

  /// The current usage: model bytes plus partial downloads, the installed tiers, and why the delete
  /// is blocked (a job runs).
  Future<StorageContributorUsage> measure() async {
    var bytes = 0;
    var complete = true;
    try {
      final usage = await service.storage();
      bytes = usage.modelBytes + usage.partialBytes;
    } on Object catch (e) {
      debugPrint('[SpeechStorage] Could not measure: ${e.runtimeType}');
      complete = false;
    }
    final tiers = await installedTiers();
    return StorageContributorUsage(
      bytes: bytes,
      complete: complete,
      detail: SpeechStorageStrings.installed(tiers),
      clearBlockedReason: service.activeJob == null ? null : SpeechStorageStrings.inUse,
    );
  }

  /// Tiers whose model is installed (ready or damaged), in catalog order.
  Future<List<SpeechModelTier>> installedTiers() async {
    final out = <SpeechModelTier>[];
    for (final offer in service.offers) {
      try {
        final status = await service.modelStatusOf(offer.spec.id);
        if (status is SpeechModelReady || status is SpeechModelCorrupt) out.add(offer.spec.tier);
      } on Object {
        // Unknown status: not listed.
      }
    }
    return out;
  }

  /// Deletes every speech model unless a job runs ([StorageClearOutcome.blocked] then).
  Future<StorageClearOutcome> clear() async {
    if (service.activeJob != null) return const StorageClearOutcome.blocked(SpeechStorageStrings.inUse);
    final before = await measure();
    try {
      await service.deleteModel();
    } on StateError {
      return const StorageClearOutcome.blocked(SpeechStorageStrings.inUse);
    }
    final after = await measure();
    if (!_changed.isClosed) _changed.add(null);
    final freed = before.bytes > after.bytes ? before.bytes - after.bytes : 0;
    return StorageClearOutcome.done(freedBytes: freed, message: before.bytes == 0 ? SpeechStorageStrings.nothingToDelete : null);
  }
}
