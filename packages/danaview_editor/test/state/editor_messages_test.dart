// OWNER: UX-08
//
// Every EditorFailure subtype and every EditRejection has plain copy with a next step (ARCH §19,
// ux.md §18 rule 2). The switches below have no wildcard, so adding a subtype breaks the build of
// this test until it gets a sample here (and copy in editor_messages.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_messages.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' as ops;
import 'package:danaview_editor_core/store.dart' show StoreFailure, StoreFailureKind;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EngineErrorCode, EngineFailure, MediaAccessFailure, MediaAccessFailureKind;
import 'package:danaview_transcription/danaview_transcription.dart'
    show ModelDownloadFailure, ModelDownloadFailureKind, NoSpeechFailure, InferenceFailure, TranscriptionFailure;

/// The subtype name of [f] (exhaustive: no wildcard).
String failureKind(EditorFailure f) => switch (f) {
      ProjectNotFound() => 'ProjectNotFound',
      ProjectNeedsNewerApp() => 'ProjectNeedsNewerApp',
      ProjectCorrupt() => 'ProjectCorrupt',
      SaveFailed() => 'SaveFailed',
      MediaUnavailable() => 'MediaUnavailable',
      MediaUnsupported() => 'MediaUnsupported',
      ImportFailed() => 'ImportFailed',
      PreviewFailed() => 'PreviewFailed',
      ExportFailed() => 'ExportFailed',
      PermissionDenied() => 'PermissionDenied',
      ParseFailed() => 'ParseFailed',
      ModelDownloadFailed() => 'ModelDownloadFailed',
      TranscriptionFailed() => 'TranscriptionFailed',
      UnknownFailure() => 'UnknownFailure',
    };

const _failureKinds = 14;

/// The subtype name of [r] (exhaustive: no wildcard).
String rejectionKind(ops.EditRejection r) => switch (r) {
      ops.TrackLocked() => 'TrackLocked',
      ops.ItemNotFound() => 'ItemNotFound',
      ops.WouldOverlap() => 'WouldOverlap',
      ops.OutOfSourceRange() => 'OutOfSourceRange',
      ops.BelowMinDuration() => 'BelowMinDuration',
      ops.NothingAtTime() => 'NothingAtTime',
      ops.UnsupportedForKind() => 'UnsupportedForKind',
      ops.IncompatibleTrack() => 'IncompatibleTrack',
      ops.NotAdjacent() => 'NotAdjacent',
      ops.TransitionTooLong() => 'TransitionTooLong',
      ops.KeyframeExists() => 'KeyframeExists',
      ops.EmptyText() => 'EmptyText',
      ops.NoRoom() => 'NoRoom',
      ops.RippleBlockedByLinkedItem() => 'RippleBlockedByLinkedItem',
      ops.LimitExceeded() => 'LimitExceeded',
      ops.MediaUnavailable() => 'MediaUnavailable',
      ops.CannotDeleteMainTrack() => 'CannotDeleteMainTrack',
      ops.InvalidValue() => 'InvalidValue',
      ops.InternalInconsistency() => 'InternalInconsistency',
    };

const _rejectionKinds = 19;

final List<EditorFailure> allFailures = [
  const ProjectNotFound(),
  const ProjectNeedsNewerApp(),
  const ProjectCorrupt(),
  for (final k in StoreFailureKind.values) SaveFailed(k),
  const MediaUnavailable(),
  const MediaUnsupported('containerUnsupportedIos'),
  const MediaUnsupported('notSupportedOnDevice'),
  for (final r in ['unsupported', 'diskFull', 'notFound', 'accessDenied', 'notPersistable', 'empty', 'lutInvalid', 'cancelled', 'io'])
    ImportFailed(r),
  const PreviewFailed(),
  const PreviewFailed(recoverable: false, engineCode: EngineErrorCode.gpuUnavailable),
  for (final k in ExportFailureKind.values) ExportFailed(k),
  for (final p in EditorPermission.values) PermissionDenied(p),
  for (final f in EditorParseFormat.values) ...[ParseFailed(f), ParseFailed(f, line: 14)],
  for (final k in ModelDownloadFailureKind.values) ModelDownloadFailed(k),
  for (final r in [
    'noSpeech',
    'noAudio',
    'insufficientMemory',
    'unsupportedDevice',
    'mediaOffline',
    'diskFull',
    'inference',
    'audioDecode'
  ])
    TranscriptionFailed(r, retryable: r == 'inference'),
  const TranscriptionFailed('modelCorrupt'),
  const UnknownFailure(),
];

final List<ops.EditRejection> allRejections = [
  const ops.TrackLocked(TrackId('tr_1')),
  const ops.ItemNotFound('it_1'),
  const ops.WouldOverlap(TrackId('tr_1'), TimeRange(0, 1000)),
  const ops.OutOfSourceRange(),
  const ops.BelowMinDuration(),
  const ops.NothingAtTime(0),
  for (final k in ['text', 'subtitle', 'audio', 'image', 'video', 'lut', 'other']) ops.UnsupportedForKind(k),
  const ops.IncompatibleTrack(),
  const ops.NotAdjacent(),
  const ops.TransitionTooLong(1),
  const ops.TransitionTooLong(12),
  const ops.KeyframeExists(0),
  const ops.EmptyText(),
  const ops.NoRoom(),
  const ops.RippleBlockedByLinkedItem(ItemId('it_1')),
  for (final w in [
    ops.LimitExceeded.items,
    ops.LimitExceeded.duration,
    ops.LimitExceeded.concurrentVideoLayers,
    ops.LimitExceeded.visualSequences,
    'future',
  ])
    ops.LimitExceeded(w, 4),
  const ops.MediaUnavailable(MediaId('md_1')),
  const ops.CannotDeleteMainTrack(),
  const ops.InvalidValue('transform.scale'),
  ops.InternalInconsistency(const []),
];

void expectPlainCopy(EditorMessage m, String what) {
  expect(m.title.trim(), isNotEmpty, reason: what);
  expect(m.title, isNot(endsWith('.')), reason: '$what: titles are one line without a full stop');
  expect(m.title.length, lessThanOrEqualTo(80), reason: what);
  final detail = m.detail;
  expect(detail, isNotNull, reason: '$what: every message has a next step');
  expect(detail!.trim(), isNotEmpty, reason: what);
  expect(detail, endsWith('.'), reason: what);
  for (final text in [m.title, detail]) {
    for (final banned in ['Exception', 'null', 'file://', 'Error(', '_', r'$']) {
      expect(text.contains(banned), isFalse, reason: '$what: "$text" contains "$banned"');
    }
  }
}

void main() {
  group('failures', () {
    test('the samples cover every EditorFailure subtype', () {
      expect(allFailures.map(failureKind).toSet(), hasLength(_failureKinds));
    });

    test('every failure has plain copy with a next step', () {
      for (final f in allFailures) {
        expectPlainCopy(EditorMessages.forFailure(f), '$f');
        expect(editorFailureMessage(f), EditorMessages.forFailure(f));
        expect(f.code, isNot(contains('/')), reason: 'codes carry no paths');
      }
    });

    test('ux.md §18 sample copy', () {
      expect(
        EditorMessages.forFailure(const SaveFailed(StoreFailureKind.diskFull)),
        const EditorMessage(
          "Couldn't save changes: your device is full",
          detail: 'Your changes are kept until you free up space.',
          action: EditorMessageAction.freeUpSpace,
        ),
      );
      expect(EditorMessages.forFailure(const ExportFailed(ExportFailureKind.encoderUnavailable)).action, EditorMessageAction.exportH264);
      expect(EditorMessages.forFailure(const ExportFailed(ExportFailureKind.encoderSizeLimit)).action, EditorMessageAction.lowerResolution);
      expect(EditorMessages.forFailure(const PermissionDenied(EditorPermission.microphone)).action, EditorMessageAction.openSettings);
      expect(EditorMessages.forFailure(const ProjectNotFound()).title, "This project isn't available");
      expect(EditorMessages.forFailure(const PreviewFailed()).action, EditorMessageAction.restartPreview);
      expect(EditorMessages.forFailure(const ParseFailed(EditorParseFormat.cube, line: 14)).title, "This LUT couldn't be read (line 14)");
    });

    test('engine failures map by context (ARCH §19)', () {
      EditorFailure? map(EngineErrorCode c, [EngineFailureContext ctx = EngineFailureContext.preview]) =>
          EditorFailures.fromEngine(EngineFailure.of(c), context: ctx);
      for (final c in EngineErrorCode.values) {
        for (final ctx in EngineFailureContext.values) {
          final f = map(c, ctx);
          if (c == EngineErrorCode.cancelled) {
            expect(f, isNull, reason: 'cancelled is not a failure');
          } else {
            expect(f, isNotNull, reason: '$c in $ctx');
            expectPlainCopy(EditorMessages.forFailure(f!), '$c in $ctx');
          }
        }
      }
      expect(map(EngineErrorCode.mediaOffline), isA<MediaUnavailable>());
      expect(map(EngineErrorCode.permissionDenied, EngineFailureContext.recording), const PermissionDenied(EditorPermission.microphone));
      expect(map(EngineErrorCode.permissionDenied, EngineFailureContext.export), const ExportFailed(ExportFailureKind.destinationDenied));
      expect(map(EngineErrorCode.unsupportedMedia), const MediaUnsupported('unsupportedMedia'));
      expect(map(EngineErrorCode.notSupportedOnDevice), const MediaUnsupported('notSupportedOnDevice'));
      for (final c in [EngineErrorCode.decoderInitFailed, EngineErrorCode.decodeFailed, EngineErrorCode.gpuUnavailable]) {
        expect(map(c), PreviewFailed(engineCode: c));
        expect(map(c, EngineFailureContext.export), const ExportFailed(ExportFailureKind.unknown));
      }
      expect(
          map(EngineErrorCode.encoderUnavailable, EngineFailureContext.export), const ExportFailed(ExportFailureKind.encoderUnavailable));
      expect(map(EngineErrorCode.encoderSizeLimit, EngineFailureContext.export), const ExportFailed(ExportFailureKind.encoderSizeLimit));
      expect(map(EngineErrorCode.diskFull, EngineFailureContext.export), const ExportFailed(ExportFailureKind.diskFull));
      expect(map(EngineErrorCode.interrupted, EngineFailureContext.export), const ExportFailed(ExportFailureKind.interrupted));
      expect(map(EngineErrorCode.planInvalid), isA<UnknownFailure>());
      expect(map(EngineErrorCode.internal), isA<UnknownFailure>());
    });

    test('store failures map to project failures while opening and SaveFailed otherwise', () {
      expect(EditorFailures.fromStore(const StoreFailure(StoreFailureKind.notFound), opening: true), const ProjectNotFound());
      expect(EditorFailures.fromStore(const StoreFailure(StoreFailureKind.newerSchema), opening: true), const ProjectNeedsNewerApp());
      expect(EditorFailures.fromStore(const StoreFailure(StoreFailureKind.corrupt), opening: true), const ProjectCorrupt());
      for (final k in StoreFailureKind.values) {
        expect(EditorFailures.fromStore(StoreFailure(k)), SaveFailed(k));
        expectPlainCopy(EditorMessages.forFailure(EditorFailures.fromStore(StoreFailure(k), opening: true)), 'open $k');
      }
    });

    test('anything else becomes a typed failure, never an exception', () {
      expect(EditorFailures.fromError(const MediaAccessFailure(MediaAccessFailureKind.accessLost)), const MediaUnavailable());
      expect(
        EditorFailures.fromError(const ModelDownloadFailure(ModelDownloadFailureKind.offline)),
        const ModelDownloadFailed(ModelDownloadFailureKind.offline),
      );
      const TranscriptionFailure noSpeech = NoSpeechFailure();
      expect(EditorFailures.fromError(noSpeech), const TranscriptionFailed('noSpeech'));
      expect((EditorFailures.fromError(const InferenceFailure()) as TranscriptionFailed).retryable, isTrue);
      expect(EditorFailures.fromError(StateError('boom')), const UnknownFailure('StateError'));
      expect(EditorFailures.fromError(const SaveFailed(StoreFailureKind.io)), const SaveFailed(StoreFailureKind.io));
    });
  });

  group('rejections', () {
    test('the samples cover every EditRejection subtype', () {
      expect(allRejections.map(rejectionKind).toSet(), hasLength(_rejectionKinds));
    });

    test('every rejection has plain copy with a next step', () {
      for (final r in allRejections) {
        expectPlainCopy(EditorMessages.forRejection(r), '$r');
        expect(editRejectionMessage(r), EditorMessages.forRejection(r));
      }
    });

    test('ux.md §18 sample copy', () {
      expect(EditorMessages.forRejection(const ops.TrackLocked(TrackId('tr_1'))).title, 'This track is locked');
      expect(EditorMessages.forRejection(const ops.TrackLocked(TrackId('tr_1'))).action, EditorMessageAction.unlock);
      expect(EditorMessages.forRejection(const ops.BelowMinDuration()).title, "Clips can't be shorter than one frame");
      expect(EditorMessages.forRejection(const ops.TransitionTooLong(1)).detail, contains('1 frame,'));
      expect(EditorMessages.forRejection(const ops.LimitExceeded(ops.LimitExceeded.concurrentVideoLayers, 4)).title, contains('4 videos'));
      expect(EditorMessages.forRejection(const ops.MediaUnavailable(MediaId('md_1'))).action, EditorMessageAction.relink);
    });
  });

  group('notices and fixed messages', () {
    test('notices that need a toast have copy; others are silent', () {
      for (final code in [
        ops.EditNoticeCodes.trimmedToFit,
        ops.EditNoticeCodes.transitionsRemoved,
        ops.EditNoticeCodes.transitionsShortened,
        ops.EditNoticeCodes.placedOnOtherLane,
        ops.EditNoticeCodes.itemsSkipped,
      ]) {
        final m = EditorMessages.forNotice(ops.EditNotice(code, count: 2));
        expect(m, isNotNull, reason: code);
        expect(m!.title, isNot(endsWith('.')));
      }
      expect(EditorMessages.forNotice(ops.EditNotice(ops.EditNoticeCodes.itemsSkipped, count: 1))!.title, '1 item was skipped');
      expect(EditorMessages.forNotice(ops.EditNotice(ops.EditNoticeCodes.mediaImported)), isNull);
    });

    test('fixed messages', () {
      for (final m in [EditorMessages.openedReadOnly, EditorMessages.migrated, EditorMessages.repaired]) {
        expectPlainCopy(m, m.title);
      }
      expect(EditorMessages.saved.title, 'Saved');
      expect(EditorMessages.undid('Split clip').title, 'Undid Split clip');
      expect(EditorMessages.redid('Split clip').title, 'Redid Split clip');
    });
  });
}
