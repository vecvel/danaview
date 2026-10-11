// OWNER: API-01
//
// The public surface of ARCH §12.1-12.5 exists, the package obeys ARCH §4.2 rule 3, and every
// public type has dartdoc that points at the architecture (BUILD_PLAN API-01 acceptance criteria).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

Directory _pkg() {
  var d = Directory.current;
  while (!File('${d.path}/pubspec.yaml').existsSync() || !d.path.endsWith('danaview_editor_engine_api')) {
    final parent = d.parent;
    if (parent.path == d.path) {
      throw StateError('package root not found from ${Directory.current.path}');
    }
    d = parent;
  }
  return d;
}

void main() {
  test('every type named in ARCH §12.1-12.5 is exported', () {
    final types = <Type>[
      // 12.1
      EngineMedia, EditorEngineConfig, EditorEngine, EditCompatibility, Editable, NotEditable, CacheTrimLevel, EngineSignal,
      MemoryWarningSignal, ThermalSignal, ThermalLevel,
      // 12.2
      PreviewConfig, PreviewSession, PreviewClock, SeekAck, PlanAck, SeekKind, PreviewQuality, PreviewEditingMode, PreviewEvent,
      NormalPreviewMode, CropSourceMode, MatteMode, PreviewFirstFrame, PreviewStalled, PreviewRecovered, PreviewDegraded,
      PreviewSurfaceLost, PreviewFailedEvent, LookSpec,
      // 12.3
      ThumbnailSource, ThumbnailRequest, ThumbnailTile, ThumbnailHandle, ThumbPriority, WaveformSource, WaveformPeaks, MediaJobs,
      MediaJob, JobPriority, GeneratedAsset, ProxyStatus, SpeechAudioJobRequest, ExtractedSpeechAudio,
      // 12.4
      ExportService, ExportPreflight, ExportJob, ExportJobState, ExportRunning, ExportResumable, ExportInterrupted,
      ExportCompletedWhileDetached, ExportDetachedHandoff, ExportProgress, ExportPhase, ExportResult, ExportWarning, VoiceRecorder,
      RecordingSession, MicPermission, RecordedAsset, RecordingInterruption, MediaPicker, MediaPickRequest, MediaPickSource,
      MediaPickKind, FileHandoff, FileHandoffResult, FileHandoffOutcome, MediaAccess, BackgroundWorkGuard, BackgroundLease,
      ExternalDropTarget, ExternalDrop,
      // 12.5
      EditorCapabilities, DeviceTier, BackgroundExportKind, EngineErrorCode, EngineFailure, EngineError, EngineCancelled,
      UnsupportedReasons,
      // re-exported core types (D-27)
      PickedMedia, MediaProbe, EncodeSettings, RenderPlan, RenderPlanPatch, PlanTransient, MediaAccessPort, ResolvedMedia,
      ExportContainer, VideoCodec,
      // D-33 placeholders
      PlanSync, PlanSyncStatus, PlanTransport, RenderMath, FontResolver, TextLayoutEngine, TextSpriteRasterizer, VspriteCodec,
      SpritePrepass,
    ];
    expect(types, everyElement(isNotNull));
    expect(types.toSet().length, greaterThan(80));
  });

  test('capabilities carry every field of ARCH §12.5', () {
    const c = EditorCapabilities(supported: true);
    expect([
      c.supported, c.unsupportedReason, c.tier, c.lowMemoryDevice, c.h264Encode, c.hevcEncode, c.hardwareH264, c.hardwareHevc,
      c.movContainer, c.maxExportSize, c.maxFpsByHeight, c.maxConcurrentVideoLayers, c.maxVisualSequences, c.maxTextureSize,
      c.maxPreviewLongSide, c.backgroundKind, c.backgroundGpu, c.voiceRecording, c.proxiesRecommended, c.holdFrame, c.fpsUpconversion,
      c.externalDrop, c.minSpeed, c.maxSpeed, c.maxAudioSpeed, c.maxLutSize, c.planVersions, //
    ], hasLength(27));
    expect(c.minSpeed, 0.1);
    expect(c.maxSpeed, 10);
    expect(c.maxAudioSpeed, 4);
    expect(c.maxLutSize, 65);
    expect(c.planVersions, [1]);
    expect(DeviceTier.values.map((e) => e.name), ['minimal', 'low', 'mid', 'high']);
    expect(BackgroundExportKind.values.map((e) => e.name), ['none', 'paused', 'continued', 'foregroundService']);
    expect(
      EngineErrorCode.values.map((e) => e.name),
      [
        'mediaOffline', 'permissionDenied', 'unsupportedMedia', 'decoderInitFailed', 'decodeFailed', 'encoderUnavailable',
        'encoderSizeLimit', 'encodingFailed', 'diskFull', 'io', 'planInvalid', 'planOutOfSync', 'gpuUnavailable', 'surfaceLost',
        'interrupted', 'cancelled', 'busy', 'notSupportedOnDevice', 'internal', //
      ],
    );
  });

  test('dependency rule 3 (ARCH §4.2): only flutter, collection, meta and danaview_editor_core', () {
    final pkg = _pkg();
    final pubspec = File('${pkg.path}/pubspec.yaml').readAsStringSync();
    final deps = RegExp(r'^dependencies:\n((?:  .*\n|\n)*)', multiLine: true).firstMatch(pubspec)!.group(1)!;
    final names = RegExp(r'^  (\w+):', multiLine: true).allMatches(deps).map((m) => m.group(1)).toSet();
    expect(names, {'flutter', 'collection', 'meta', 'danaview_editor_core'});

    final bad = <String>[];
    final allowed = RegExp(
        r'''^(?:import|export)\s+['"](dart:[a-z_]+|package:(flutter|collection|meta|danaview_editor_core|danaview_editor_engine_api|flutter_test)/[^'"]*|[^:'"]+)['"]''');
    for (final f in Directory('${pkg.path}/lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final line in f.readAsLinesSync().where((l) => l.startsWith('import ') || l.startsWith('export '))) {
        if (!allowed.hasMatch(line)) {
          bad.add('${f.path}: $line');
        }
        if (line.contains('package:flutter/material.dart') || line.contains('package:flutter/cupertino.dart')) {
          bad.add('Material/Cupertino chrome: ${f.path}: $line');
        }
        if (line.contains("'dart:io'") || line.contains('"dart:io"')) {
          bad.add('dart:io in the contract package: ${f.path}');
        }
      }
    }
    expect(bad, isEmpty);
  });

  test('flutter_test is only a dev dependency and lib/ never imports it', () {
    final pkg = _pkg();
    for (final f in Directory('${pkg.path}/lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(f.readAsStringSync(), isNot(contains('package:flutter_test')), reason: f.path);
    }
  });

  test('every public top-level type has dartdoc that links an ARCH section or decision', () {
    final pkg = _pkg();
    final decl = RegExp(r'^(?:(?:abstract|sealed|final|base|interface|mixin|class)\s+)*(?:class|enum|typedef|mixin)\s+([A-Za-z]\w*)');
    final missing = <String>[];
    var count = 0;
    for (final f in Directory('${pkg.path}/lib/src').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final m = decl.firstMatch(lines[i]);
        if (m == null) {
          continue;
        }
        count++;
        final doc = <String>[];
        var k = i - 1;
        while (k >= 0 && (lines[k].startsWith('///') || lines[k].startsWith('@'))) {
          if (lines[k].startsWith('///')) {
            doc.add(lines[k]);
          }
          k--;
        }
        final text = doc.join('\n');
        if (!RegExp(r'ARCH §|D-\d\d|BUILD_PLAN|ai\.md|ux\.md').hasMatch(text)) {
          missing.add('${f.path.split('lib/src/').last}: ${m.group(1)}');
        }
      }
    }
    expect(count, greaterThan(80));
    expect(missing, isEmpty);
  });
}
