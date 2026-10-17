// OWNER: API-01
//
// The kit must not be vacuous: engines that break one rule each are reported.

import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

/// Delegates to a fake session and lets a test replace single behaviours.
class _Mutant implements PreviewSession {
  _Mutant(this.inner);

  final PreviewSession inner;
  Future<PlanAck> Function(RenderPlanPatch)? onPatch;
  Future<SeekAck> Function(TimeUs, SeekKind)? onSeek;
  Future<void> Function()? onPause;
  Stream<PreviewClock> Function()? onClock;

  /// When set, rendered ranges are recorded here and never dropped (a broken engine).
  List<RenderedRange>? stickyRanges;

  @override
  int get textureId => inner.textureId;
  @override
  ValueListenable<Size?> get frameSize => inner.frameSize;
  @override
  Future<PlanAck> setPlan(RenderPlan plan) => inner.setPlan(plan);
  @override
  Future<PlanAck> applyPatch(RenderPlanPatch patch) => onPatch != null ? onPatch!(patch) : inner.applyPatch(patch);
  @override
  void setTransient(ItemId item, PlanTransient transient) => inner.setTransient(item, transient);
  @override
  void clearTransient(ItemId item) => inner.clearTransient(item);
  @override
  Future<void> play({TimeRange? loop}) => inner.play(loop: loop);
  @override
  Future<void> pause() => onPause != null ? onPause!() : inner.pause();
  @override
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact}) => onSeek != null ? onSeek!(t, kind) : inner.seek(t, kind: kind);
  @override
  Future<void> setQuality(PreviewQuality quality) => inner.setQuality(quality);
  @override
  Future<void> setUseProxies(bool on) => inner.setUseProxies(on);
  @override
  Future<void> setRenderedRanges(List<RenderedRange> ranges) async {
    await inner.setRenderedRanges(ranges);
    if (stickyRanges != null) stickyRanges = ranges;
  }
  @override
  Future<void> setEditingMode(PreviewEditingMode mode) => inner.setEditingMode(mode);
  @override
  Future<void> showSourceFrame(EngineMedia media, TimeUs sourceTime) => inner.showSourceFrame(media, sourceTime);
  @override
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint) => inner.sampleColor(item, normalizedSourcePoint);
  @override
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx}) =>
      inner.renderLookStills(item, looks, heightPx: heightPx);
  @override
  Future<void> refresh() => inner.refresh();
  @override
  Future<Uint8List> debugCaptureFrame() => inner.debugCaptureFrame();
  @override
  Stream<PreviewClock> get clock => onClock != null ? onClock!() : inner.clock;
  @override
  Stream<PreviewEvent> get events => inner.events;
  @override
  Future<void> dispose() => inner.dispose();
}

/// An engine whose sessions are [_Mutant]s; everything else is the fake.
class _MutantEngine implements EditorEngine {
  _MutantEngine(this.configure);

  final FakeEditorEngine fake = FakeEditorEngine();
  final void Function(_Mutant) configure;

  @override
  Future<PreviewSession> openPreview(PreviewConfig config) async {
    final m = _Mutant(await fake.openPreview(config));
    configure(m);
    return m;
  }

  @override
  Future<EditorCapabilities> capabilities() => fake.capabilities();
  @override
  Future<EditCompatibility> compatibility(String pathOrUri) => fake.compatibility(pathOrUri);
  @override
  Future<MediaProbe> probe(EngineMedia media) => fake.probe(media);
  @override
  ThumbnailSource get thumbnails => fake.thumbnails;
  @override
  WaveformSource get waveforms => fake.waveforms;
  @override
  MediaJobs get jobs => fake.jobs;
  @override
  ExportService get exporter => fake.exporter;
  @override
  VoiceRecorder? get voiceRecorder => fake.voiceRecorder;
  @override
  MediaPicker get picker => fake.picker;
  @override
  FileHandoff get files => fake.files;
  @override
  MediaAccess get access => fake.access;
  @override
  BackgroundWorkGuard get background => fake.background;
  @override
  ExternalDropTarget get drops => fake.drops;
  @override
  Future<int> freeBytes(String path) => fake.freeBytes(path);
  @override
  Stream<EngineSignal> get signals => fake.signals;
  @override
  Future<void> trimCaches(CacheTrimLevel level) => fake.trimCaches(level);
}

/// Probe of the render-preview cases: files are the fake's stub files; a [_Mutant] with
/// [_Mutant.stickyRanges] reports those instead of the fake session's ranges.
RenderPreviewContractProbe _probe(_MutantEngine engine) => RenderPreviewContractProbe(
      rendersDirectory: '/fake/cache/danaview/editor/renders',
      fileExists: engine.fake.jobs.files.contains,
      activeRanges: (s) {
        final m = s as _Mutant;
        return m.stickyRanges ?? (m.inner as FakePreviewSession).renderedRanges;
      },
    );

void main() {
  Future<List<String>> run(void Function(_Mutant) configure) => checkEngineContract(_MutantEngine(configure));

  Future<List<String>> runRender(void Function(_Mutant) configure, {void Function(FakeEditorEngine)? setup}) {
    final engine = _MutantEngine(configure);
    setup?.call(engine.fake);
    return checkEngineContract(engine, renderPreview: _probe(engine));
  }

  test('the unmodified wrapper passes the render-preview cases', () async {
    expect(await runRender((_) {}), isEmpty);
  });

  test('rendered ranges that a touching patch does not drop are reported', () async {
    final v = await runRender((m) => m.stickyRanges = const []);
    expect(v, contains('a patch touching a rendered range must drop it'));
  });

  test('a render whose cancel keeps the output is reported', () async {
    final engine = _MutantEngine((_) {});
    final probe = _probe(engine);
    final v = await checkEngineContract(
      engine,
      renderPreview: RenderPreviewContractProbe(
        rendersDirectory: probe.rendersDirectory,
        fileExists: (_) => true,
        activeRanges: probe.activeRanges,
      ),
    );
    expect(v, contains('a cancelled render preview must delete its output'));
  });

  test('a render of a valid range plan that fails is reported', () async {
    final v = await runRender((_) {}, setup: (f) => f.failNext['jobs.renderPreview'] = const EngineCancelled());
    expect(v, contains('renderPreview of a valid range plan failed: ${const EngineCancelled()}'));
  });

  test('the unmodified wrapper passes', () async {
    expect(await run((_) {}), isEmpty);
  });

  test('a patch that ignores stale `from` revisions is reported', () async {
    final v = await run((m) => m.onPatch = (p) async => PlanAck(rev: p.to, structural: false, applyMs: 0));
    expect(v, contains('applyPatch with a stale `from` must throw EngineFailure(planOutOfSync)'));
  });

  test('an exact seek that displays the wrong frame is reported', () async {
    final v = await run((m) => m.onSeek = (t, k) async {
          final a = await m.inner.seek(t, kind: k);
          return SeekAck(
              requested: a.requested, displayedFrameTime: a.displayedFrameTime, displayedFrame: a.displayedFrame + 1, seq: a.seq);
        });
    expect(v.where((s) => s.startsWith('exact seek displayed')), isNotEmpty);
  });

  test('a seek whose seq does not increase is reported', () async {
    final v = await run((m) => m.onSeek = (t, k) async {
          final a = await m.inner.seek(t, kind: k);
          return SeekAck(requested: a.requested, displayedFrameTime: a.displayedFrameTime, displayedFrame: a.displayedFrame, seq: 1);
        });
    expect(v, contains('seq must increase with every seek'));
  });

  test('a pause that never reaches the clock is reported', () async {
    final v = await run((m) => m.onPause = () async {});
    expect(v.any((s) => s.contains('pause')), isTrue);
  });

  test('a clock that goes silent after seeks is reported', () async {
    final v = await run((m) => m.onClock = () => const Stream<PreviewClock>.empty());
    expect(v.any((s) => s.contains('clock sample')), isTrue);
  });
}
