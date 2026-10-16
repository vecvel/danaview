// OWNER: QA-00
//
// Export helpers of the E2E suite: run an export through the editor's export sheet (action
// `export`, `ExportController` settings, the sheet's Start button), keep the delivered file and side
// files, check conformance with danaview_data `MediaInspector` (container, `avc1`/`hvc1`, size,
// duration ± 1 frame, AAC), pull frames of the exported file with the engine's freeze job (PNG,
// decoded to RGBA) and read its audio through the engine's speech-audio job (16-bit WAV) for
// level checks.

// ignore_for_file: implementation_imports

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2e_app.dart';
import 'e2e_config.dart';
import 'e2e_editor.dart';

/// A finished export.
final class E2eExported {
  /// Creates the record.
  const E2eExported({required this.video, required this.result, required this.settings, this.sideFiles = const {}});

  /// The suite's copy of the delivered video.
  final String video;

  /// The engine's result.
  final ExportResult result;

  /// The settings it ran with.
  final ExportSettings settings;

  /// The suite's copies of the side files.
  final Map<SideFileFormat, String> sideFiles;
}

/// Export driver.
abstract final class E2eExport {
  /// The export controller of [ed]'s project.
  static ExportController controller(E2eEditor ed) => ed.container.read(exportControllerProvider(ed.id).notifier);

  /// The export sheet's state.
  static ExportUiState state(E2eEditor ed) => ed.container.read(exportControllerProvider(ed.id));

  /// Opens the export sheet (the Export action) and waits for its setup.
  static Future<ExportUiSetup> open(E2eEditor ed) async {
    await ed.invoke(EditorActionId.export);
    await E2eApp.waitKey(ed.tester, 'export-sheet');
    await E2eApp.pumpUntil(ed.tester, () => state(ed) is ExportUiSetup, what: 'the export setup', timeout: const Duration(seconds: 30));
    return state(ed) as ExportUiSetup;
  }

  /// Exports [ed]'s project with [configure] applied to the custom preset (720p H.264 MP4 by
  /// default), to Files, and returns the delivered file. Waits on the controller's states (engine
  /// progress and completion), never on time.
  static Future<E2eExported> run(
    E2eEditor ed, {
    ExportSettings Function(ExportSettings s)? configure,
    Duration timeout = const Duration(minutes: 6),
    bool closeAfter = true,
  }) async {
    final handoffs = E2eApp.world.engine.files.records.length;
    final settings = await start(ed, configure: configure);
    return finish(ed, settings, handoffs: handoffs, timeout: timeout, closeAfter: closeAfter);
  }

  /// Opens the sheet, applies [configure] to the custom 720p H.264 MP4 settings, picks
  /// [destination] and presses Start. Returns the settings it started with.
  static Future<ExportSettings> start(
    E2eEditor ed, {
    ExportSettings Function(ExportSettings s)? configure,
    ExportDestination destination = ExportDestination.files,
  }) async {
    await open(ed);
    final c = controller(ed);
    c.selectPreset(ExportPresetId.custom);
    c.updateSettings((s) => (configure ?? (s) => s)(s.copyWith(shortSide: 720, container: ExportContainer.mp4, codec: VideoCodec.h264)));
    c.setDestination(destination);
    await ed.tester.pump();
    final settings = (state(ed) as ExportUiSetup).draft.settings;
    await E2eApp.tapKey(ed.tester, 'export-start');
    return settings;
  }

  /// Waits for the started export to complete and be handed off (answers the first-export notice
  /// and warnings on the way), and returns the delivered file.
  static Future<E2eExported> finish(
    E2eEditor ed,
    ExportSettings settings, {
    required int handoffs,
    Duration timeout = const Duration(minutes: 6),
    bool closeAfter = true,
    void Function(ExportUiState state)? observe,
  }) async {
    final c = controller(ed);
    final sides = <SideFileFormat, String>{};
    await E2eApp.pumpUntil(
      ed.tester,
      () {
        final s = state(ed);
        observe?.call(s);
        switch (s) {
          case ExportUiNotice():
            c.confirmNotice();
          case ExportUiWarnings():
            c.confirmWarnings();
          case ExportUiFailed(:final failure, :final details):
            throw TestFailure('Export failed: $failure $details');
          case ExportUiCompleted(:final sideFiles):
            for (final f in sideFiles) {
              if (!sides.containsKey(f.format) && File(f.path).existsSync()) {
                final copy = '${E2eConfig.outDir}/${DateTime.now().microsecondsSinceEpoch}-${f.name}';
                Directory(E2eConfig.outDir).createSync(recursive: true);
                File(f.path).copySync(copy);
                sides[f.format] = copy;
              }
            }
            return E2eApp.world.engine.files.records.length > handoffs;
          default:
        }
        return false;
      },
      what: 'the export to finish',
      timeout: timeout,
      step: const Duration(milliseconds: 200),
    );
    final done = state(ed) as ExportUiCompleted;
    final video = E2eApp.world.engine.files.records.last.copyPath;
    // ignore: avoid_print
    print('DV_E2E_EXPORT ${done.fileName} ${done.result.bytes} B ${done.result.duration} us encoder ${done.result.videoEncoderName} -> $video');
    if (closeAfter) {
      // Done as the user does it: the button cleans up and closes the sheet (the controller's
      // `done` only cleans up).
      await E2eApp.tapKey(ed.tester, 'export-done');
      await E2eApp.pumpUntil(ed.tester, () => !E2eApp.hasKey('export-sheet'), what: 'the export sheet to close');
    }
    return E2eExported(video: video, result: done.result, settings: settings, sideFiles: sides);
  }

  /// Checks [path] against the §14.4 basics: container, video codec, size, duration within one
  /// frame of [duration] at [rate], and an AAC track when [audio].
  static Future<MediaFileInfo> expectConformant(
    String path, {
    required int width,
    required int height,
    required TimeUs duration,
    required FrameRate rate,
    VideoCodec codec = VideoCodec.h264,
    ExportContainer container = ExportContainer.mp4,
    bool audio = true,
  }) async {
    final info = await const MediaInspector().inspect(path);
    expect(info.container, container == ExportContainer.mp4 ? MediaContainer.mp4 : MediaContainer.mov, reason: 'container of $path');
    expect(info.videoTracks, hasLength(1));
    final v = info.videoTracks.single;
    expect(v.codecId, codec == VideoCodec.h264 ? anyOf('avc1', 'avc3') : anyOf('hvc1', 'hev1'), reason: 'video codec');
    expect((v.width, v.height), (width, height), reason: 'frame size');
    final frameUs = rate.timeOfFrame(1);
    final got = (v.duration ?? info.duration)!.inMicroseconds;
    expect((got - duration).abs(), lessThanOrEqualTo(frameUs), reason: 'duration $got us vs $duration us (± 1 frame)');
    if (audio) {
      expect(info.audioTracks, isNotEmpty, reason: 'audio track');
      expect(info.audioTracks.first.codecId, 'mp4a', reason: 'AAC');
    }
    return info;
  }

  /// Frames of [video] at [times] (µs, source time of the file), through the engine's freeze job.
  static Future<List<E2eFrame>> frames(E2eEditor ed, String video, List<TimeUs> times) async {
    final out = <E2eFrame>[];
    final dir = Directory('${E2eApp.world.runtime.roots.editorCache}/work/e2e-frames')..createSync(recursive: true);
    final media = EngineMedia(uri: Uri.file(video).toString(), fingerprint: 'e2e-${File(video).lengthSync()}-${video.hashCode}');
    for (final t in times) {
      final png = '${dir.path}/${DateTime.now().microsecondsSinceEpoch}-$t.png';
      final job = E2eApp.world.engine.jobs.freezeFrame(media, t, outputPath: png);
      final asset = await E2eApp.pumpWhile(ed.tester, job.result, what: 'freeze frame at $t us');
      out.add(await E2eApp.pumpWhile(ed.tester, decodePng(asset.path), what: 'PNG decode'));
      File(asset.path).deleteSync();
    }
    return out;
  }

  /// Decodes a PNG to RGBA.
  static Future<E2eFrame> decodePng(String path) async {
    final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final f = E2eFrame(data!.buffer.asUint8List(), image.width, image.height);
    image.dispose();
    codec.dispose();
    return f;
  }

  /// The audio of [video] over [range] as mono samples in −1..1 (engine speech-audio job: 16 kHz).
  static Future<(List<double>, int)> pcm(E2eEditor ed, String video, TimeRange range) async {
    final dir = Directory('${E2eApp.world.runtime.roots.editorCache}/work/e2e-pcm')..createSync(recursive: true);
    final media = EngineMedia(uri: Uri.file(video).toString(), fingerprint: 'e2e-${File(video).lengthSync()}-${video.hashCode}');
    final job = E2eApp.world.engine.jobs.extractSpeechAudio(
      SpeechAudioJobRequest(media: media, range: range, outputPath: '${dir.path}/${DateTime.now().microsecondsSinceEpoch}.wav'),
    );
    final r = await E2eApp.pumpWhile(ed.tester, job.result, what: 'speech audio of the export');
    final wav = readWav(File(r.path).readAsBytesSync());
    File(r.path).deleteSync();
    return wav;
  }

  /// Mono samples and sample rate of a 16-bit PCM WAV (channels averaged).
  static (List<double>, int) readWav(Uint8List bytes) {
    final b = ByteData.sublistView(bytes);
    var o = 12;
    var channels = 1, rate = 16000, bits = 16;
    while (o + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(o, o + 4));
      final size = b.getUint32(o + 4, Endian.little);
      if (id == 'fmt ') {
        channels = b.getUint16(o + 10, Endian.little);
        rate = b.getUint32(o + 12, Endian.little);
        bits = b.getUint16(o + 22, Endian.little);
      } else if (id == 'data') {
        if (bits != 16) throw StateError('expected 16-bit PCM, got $bits');
        final n = math.min(size, bytes.length - o - 8) ~/ (2 * channels);
        final out = List<double>.filled(n, 0);
        for (var i = 0; i < n; i++) {
          var s = 0;
          for (var c = 0; c < channels; c++) {
            s += b.getInt16(o + 8 + (i * channels + c) * 2, Endian.little);
          }
          out[i] = s / channels / 32768;
        }
        return (out, rate);
      }
      o += 8 + size + (size.isOdd ? 1 : 0);
    }
    throw StateError('no data chunk');
  }

  /// RMS level in dBFS of [samples].
  static double dbfs(List<double> samples) {
    if (samples.isEmpty) return -120;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    final rms = math.sqrt(sum / samples.length);
    return rms <= 0 ? -120 : 20 * math.log(rms) / math.ln10;
  }
}
