// OWNER: QA-07
//
// Auto captions on-device E2E (BUILD_PLAN QA-07; ai.md §16.4; ARCH §16, §21.2). Runs against the real
// app wiring of the shared E2E suite (integration_test/editor/support: real MobileEditorEngine,
// real TranscriptionServiceImpl over danaview_whisper, real model store) on a simulator, emulator
// or device. Results: docs/v1.1/editor/qa/QA-07-ai.md.
//
// Default phase (DV_QA07_PHASE unset) — one `flutter test` run, nothing downloaded:
//   q01 consent is shown before any network access (fresh install: no model), "Not now" downloads nothing
//   q02 spoken language: explicit English and "Detect automatically"
//   q03 generated captions: one undo removes all, SRT and VTT export parse back to the same cues,
//       Regenerate (instant re-split, then full transcription), burn-in in an exported video
//       (English, Arabic and Japanese cue text) verified with QA-00 scenario 7's method
//   q04 split clip plus a 2× speed piece: cues map to the timeline
//   q05 60 s English clip: run time within the budget, cue count in range, WER vs the reference text
//   q06 thermal pause and export pause observed, the result is unchanged
//   q07 background mid-job (host driver): iOS pauses and resumes with an identical result; Android
//       keeps running under the foreground-service lease
//   q08 offline after the download: a job runs with every HTTP connection refused
//   q09 deleting the model asks for consent again
// Phases driven by the host (each a separate run, in this order):
//   DV_QA07_PHASE=job-kill        start a job on the long clip (> one 180 s chunk), the host kills the
//                                 app after the first chunk was checkpointed, mid second chunk
//   DV_QA07_PHASE=job-resume      relaunch: the interrupted-job notice resumes from the checkpoint (the
//                                 first transcribing sample starts at the checkpointed chunk end, not 0)
//   DV_QA07_PHASE=download        REAL NETWORK (needs DV_QA07_NETWORK=true): consent, download, the host
//                                 kills the app mid-download
//   DV_QA07_PHASE=download-resume REAL NETWORK: the download resumes from the partial file and the job runs
//
// Defines (besides the E2E suite's DANAVIEW_EDITOR, DANAVIEW_AUTO_CAPTIONS, DV_E2E_FIXTURES, DV_E2E_MODELS,
// DV_E2E_HOST):
//   DV_QA07_CLIP=<file>       the 60 s English clip (default <shared>/e2e_qa07/qa07-60s-en.m4a)
//   DV_QA07_CLIP_TEXT=<file>  its reference transcript (default: the clip path with .txt)
//   DV_QA07_LONG_CLIP=<file>  the long English clip of job-kill/job-resume, longer than one chunk
//                             (default <shared>/e2e_qa07/qa07-long-en.m4a)
//   DV_QA07_TIER=balanced     tier of q05-q07 (falls back to fast, reported, when the model is not staged)
//   DV_QA07_BUDGET_MS=<ms>    q05 budget (device: the ai-eval.md §5 figure; default sized for a simulator)
//   DV_QA07_NETWORK=true      allows the download phases
//   DV_PERF_STRICT=1          the q03 re-split and q05 run-time limits apply as stated (a quiet dev Mac or
//                             a real device); without it (a loaded CI emulator) they are 4× looser
// How to stage and run: docs/v1.1/editor/qa/QA-07-ai.md §2.

// ignore_for_file: implementation_imports, avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:danaview_editor/danaview_editor.dart' show AutoCaptionsRuntime, EditorScreen;
import 'package:danaview_editor/src/app/editor_providers.dart' show autoCaptionsControllerProvider;
import 'package:danaview_editor/src/app/strings/captions_strings.dart';
import 'package:danaview_editor/src/app/strings/subtitle_io_strings.dart';
import 'package:danaview_editor/src/editor/contracts/action_binding.dart';
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_controller.dart';
import 'package:danaview_editor/src/editor/flows/captions/regenerate_sheet.dart' show RegenerateSheet;
import 'package:danaview_editor/src/editor/flows/export/export_state.dart' show ExportUiNotice, ExportUiWarnings;
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SelectMode;
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart' as whisper show ThermalChanged, ThermalLevel;
import 'package:flutter/widgets.dart' show Navigator, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../editor/support/e2e.dart';

// -------------------------------------------------------------------------------------------------
// Configuration
// -------------------------------------------------------------------------------------------------

abstract final class Qa07 {
  static const String phase = String.fromEnvironment('DV_QA07_PHASE');
  static const String _clip = String.fromEnvironment('DV_QA07_CLIP');
  static const String _clipText = String.fromEnvironment('DV_QA07_CLIP_TEXT');
  static const String _longClip = String.fromEnvironment('DV_QA07_LONG_CLIP');
  static const String _tier = String.fromEnvironment('DV_QA07_TIER', defaultValue: 'balanced');
  static const int _budgetMs = int.fromEnvironment('DV_QA07_BUDGET_MS');
  static const bool network = bool.fromEnvironment('DV_QA07_NETWORK');

  /// DV_PERF_STRICT=1 gates the absolute time limits; otherwise they are [looseFactor]× looser.
  static const bool perfStrict = String.fromEnvironment('DV_PERF_STRICT') == '1';
  static const int looseFactor = 4;
  static Duration limit(Duration strict) => perfStrict ? strict : strict * looseFactor;
  static String get perfMode => perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$looseFactor, no DV_PERF_STRICT';

  /// ai.md §16.4 scenario 1.
  static const double maxWer = 0.15;

  static String get clipPath => _clip.isNotEmpty ? _clip : '${E2eConfig.hostSharedDir}/e2e_qa07/qa07-60s-en.m4a';

  static String get longClipPath => _longClip.isNotEmpty ? _longClip : '${E2eConfig.hostSharedDir}/e2e_qa07/qa07-long-en.m4a';

  /// Transcription chunks are about 180 s, cut at the quietest point within ±15 s (ai.md §6.2), so
  /// the first checkpoint ends between 165 s and 195 s of the unit.
  static const TimeUs firstChunkMinEnd = 165 * 1000000;
  static const TimeUs firstChunkMaxEnd = 195 * 1000000;

  /// job-kill kills the app once this much is transcribed: past the first chunk, so a checkpoint exists.
  static const TimeUs killAfter = 215 * 1000000;

  static String get clipTextPath {
    if (_clipText.isNotEmpty) return _clipText;
    final dot = clipPath.lastIndexOf('.');
    return '${dot < 0 ? clipPath : clipPath.substring(0, dot)}.txt';
  }

  static SpeechModelTier get requestedTier => SpeechModelTier.values.firstWhere((t) => t.name == _tier, orElse: () => SpeechModelTier.balanced);

  /// The q05 budget for [audio] with [tier]: the define, or a simulator-sized default (CPU path:
  /// Fast ≤ 1× real time, Balanced ≤ 2× real time, plus 20 s for model load and extraction).
  static Duration budget(SpeechModelTier tier, Duration audio) {
    if (_budgetMs > 0) return const Duration(milliseconds: _budgetMs);
    final factor = switch (tier) { SpeechModelTier.fast => 1.0, SpeechModelTier.balanced => 2.0, SpeechModelTier.accurate => 4.0 };
    return Duration(milliseconds: (audio.inMilliseconds * factor).round() + 20000);
  }

  static void report(String id, String line) => print('DV_QA07_REPORT $id $line');
}

/// Records (and optionally refuses) every dart:io HTTP client the app creates: the downloader is a
/// plain `HttpClient`, so a client created here is a network access by the app.
final class NetRecorder extends HttpOverrides {
  NetRecorder({this.refuse = false});

  /// Refuse every connection (offline).
  final bool refuse;

  /// One entry per client created (top of the stack, for the report).
  final List<String> clients = [];

  HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients.add(StackTrace.current.toString().split('\n').skip(1).take(4).map((l) => l.trim()).join(' <- '));
    if (refuse) throw const SocketException('QA-07: offline (all connections refused)');
    return super.createHttpClient(context);
  }

  /// Installs this recorder as the global override until [uninstall].
  NetRecorder install() {
    _previous = HttpOverrides.current;
    HttpOverrides.global = this;
    return this;
  }

  void uninstall() => HttpOverrides.global = _previous;
}

// -------------------------------------------------------------------------------------------------
// Job observation
// -------------------------------------------------------------------------------------------------

/// Listens to every job the service starts.
final class JobWatch {
  JobWatch(this.service, {ResourceGovernor? governor}) {
    _events = service.events.listen((e) {
      if (e is JobStarted) attach(e.job);
    });
    if (governor != null) {
      _governor = governor.changes.listen((_) {
        final r = governor.pauseReason;
        if (governorPauses.isEmpty || governorPauses.last != r) governorPauses.add(r);
        if (governor.inBackground) sawBackground = true;
      });
    }
  }

  StreamSubscription<void>? _governor;

  /// The governor's pause reason after each of its changes (null = running).
  final List<PauseReason?> governorPauses = [];

  /// Whether the governor saw the app in the background.
  bool sawBackground = false;

  final TranscriptionService service;
  late final StreamSubscription<TranscriptionEvent> _events;
  final Set<String> _ids = {};
  final List<StreamSubscription<TranscriptionProgress>> _subs = [];

  /// Pause reasons seen, in order.
  final List<PauseReason> pauses = [];

  /// Phases seen.
  final Set<TranscriptionPhase> phases = {};

  /// The latest sample.
  TranscriptionProgress? last;

  /// The first sample of the transcribing phase.
  TranscriptionProgress? firstTranscribing;

  /// The first sample of the transcribing phase with audio processed. The phase change itself is
  /// reported before a checkpoint is replayed, so a resumed unit shows its resume point here.
  TranscriptionProgress? firstProcessed;

  void poll() {
    final job = service.activeJob;
    if (job != null) attach(job);
  }

  void attach(TranscriptionJob job) {
    if (!_ids.add(job.id)) return;
    _subs.add(job.progress.listen(_on, onError: (Object _) {}));
  }

  void _on(TranscriptionProgress p) {
    last = p;
    phases.add(p.phase);
    if (p.phase == TranscriptionPhase.transcribing && firstTranscribing == null) firstTranscribing = p;
    if (p.phase == TranscriptionPhase.transcribing && p.processed > 0 && firstProcessed == null) firstProcessed = p;
    final paused = p.paused;
    if (paused != null && (pauses.isEmpty || pauses.last != paused)) pauses.add(paused);
  }

  bool get transcribing => last?.phase == TranscriptionPhase.transcribing && last?.paused == null;

  Future<void> dispose() async {
    await _events.cancel();
    await _governor?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
  }
}

/// One finished captions run.
final class CaptionsRun {
  CaptionsRun(this.track, this.elapsed, this.watch);

  final Track track;
  final Duration elapsed;
  final JobWatch watch;

  List<SubtitleCue> get cues => [for (final i in track.items) i as SubtitleCue];
  CaptionProvenance get provenance => track.subtitle!.provenance!;
  List<String> get words => normalizedWords(cues.map((c) => c.text).join(' '));
}

/// Lower case, punctuation and symbols removed, apostrophes dropped (ai-eval.md §1).
List<String> normalizedWords(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .toList();

/// Word error rate of [hyp] against [ref].
double wer(List<String> ref, List<String> hyp) {
  if (ref.isEmpty) return hyp.isEmpty ? 0 : 1;
  var prev = List<int>.generate(hyp.length + 1, (j) => j);
  for (var i = 1; i <= ref.length; i++) {
    final cur = List<int>.filled(hyp.length + 1, 0)..[0] = i;
    for (var j = 1; j <= hyp.length; j++) {
      final sub = prev[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1);
      cur[j] = math.min(sub, math.min(prev[j] + 1, cur[j - 1] + 1));
    }
    prev = cur;
  }
  return prev[hyp.length] / ref.length;
}

// -------------------------------------------------------------------------------------------------
// Driver
// -------------------------------------------------------------------------------------------------

abstract final class Captions {
  static AutoCaptionsRuntime get runtime => E2eApp.world.captions ?? (throw StateError('build with --dart-define=DANAVIEW_AUTO_CAPTIONS=true'));

  static TranscriptionServiceImpl get service => runtime.service;

  static AutoCaptionsState state(E2eEditor ed) => ed.container.read(autoCaptionsControllerProvider(ed.id));

  static AutoCaptionsController controller(E2eEditor ed) => ed.container.read(autoCaptionsControllerProvider(ed.id).notifier);

  /// `<support>/danaview/speech`.
  static String get speechDir => '${E2eApp.world.runtime.roots.support}/danaview/speech';

  /// Empties the transcript cache, so the next run transcribes again (as "Clear transcripts" would).
  static void clearTranscripts() {
    final dir = Directory('$speechDir/transcripts');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// Installs the tier's model from the models folder when staged; returns the tier that is ready
  /// (falls back to Fast, staged by the E2E suite).
  static Future<SpeechModelTier> stage(SpeechModelTier wanted) async {
    expect(await E2eApp.stageSpeechModel(), isTrue,
        reason: 'stage ggml-tiny-q5_1.bin and ggml-silero-v6.2.0.bin in ${E2eConfig.modelsDir} (tool/e2e_host.sh stage-models)');
    if (wanted == SpeechModelTier.fast) return wanted;
    final spec = SpeechModelCatalog.specOf(wanted);
    if (await runtime.store.installed(spec.id) != null) return wanted;
    final file = File('${E2eConfig.modelsDir}/${spec.fileName}');
    if (!file.existsSync()) {
      Qa07.report('tier', '${wanted.name} model ${spec.fileName} not staged in ${E2eConfig.modelsDir}: using fast (plumbing only)');
      return SpeechModelTier.fast;
    }
    await runtime.store.installFromFile(spec, file.path);
    return wanted;
  }

  /// Selects [clips] and opens Auto captions from the clip context menu ("This clip" / "Selected clips").
  static Future<void> open(E2eEditor ed, List<ItemId> clips) async {
    await ed.select(clips.first);
    for (final c in clips.skip(1)) {
      await ed.select(c, mode: SelectMode.extend);
    }
    // A clip's context menu captions that clip; the tool tile captions the selection.
    await ed.invoke(EditorActionId.autoCaptions, source: clips.length == 1 ? EditorActionSource.contextMenu : EditorActionSource.toolTile);
    await E2eApp.waitKey(ed.tester, 'captions-sheet');
    await E2eApp.waitKey(ed.tester, 'captions-configure', timeout: const Duration(seconds: 30));
    await E2eApp.tap(
      ed.tester,
      find.descendant(of: find.byKey(const ValueKey('captions-scope')), matching: find.text(CaptionsStrings.selectionScope(clips.length))),
      what: 'the selection scope',
    );
  }

  /// Picks [tier] and [language] on the configure step (through the tier control and the language picker).
  static Future<void> configure(E2eEditor ed, {required SpeechModelTier tier, SpokenLanguage? language}) async {
    final t = ed.tester;
    await E2eApp.tapKey(t, 'captions-tier-${tier.name}');
    await E2eApp.pumpUntil(t, () => state(ed).draft.tier == tier, what: 'tier ${tier.name}');
    if (language != null) {
      await E2eApp.tapKey(t, 'captions-language');
      await E2eApp.waitKey(t, 'captions-language-picker');
      switch (language) {
        case AutoLanguage():
          await E2eApp.tapKey(t, 'captions-language-auto');
        case FixedLanguage(:final code):
          await E2eApp.enterText(t, 'captions-language-search', languageForWhisperCode(code)?.englishName ?? code);
          await E2eApp.tapKey(t, 'captions-language-$code');
      }
      await E2eApp.pumpUntil(t, () => state(ed).draft.language.toString() == language.toString() || _sameLanguage(state(ed).draft.language, language),
          what: 'the language choice');
      await E2eApp.waitKey(t, 'captions-configure');
    }
  }

  static bool _sameLanguage(SpokenLanguage a, SpokenLanguage b) => switch ((a, b)) {
        (AutoLanguage(), AutoLanguage()) => true,
        (FixedLanguage(code: final x), FixedLanguage(code: final y)) => x == y,
        _ => false,
      };

  /// Presses "Create captions" and waits until [done] holds (default: a new generated subtitle
  /// track). [trigger]/[action] run once, the first time [trigger] holds on the job's progress
  /// (pauses, background, exports). A low-confidence language question is answered "English".
  static Future<CaptionsRun> create(
    E2eEditor ed, {
    bool Function()? done,
    bool Function(JobWatch watch)? trigger,
    Future<void> Function(JobWatch watch)? action,
    Duration timeout = const Duration(minutes: 8),
    bool pressCreate = true,
  }) async {
    final t = ed.tester;
    final watch = JobWatch(service, governor: runtime.governor);
    final tracksBefore = ed.tracksOf(TrackKind.subtitle).length;
    bool generated() => done != null ? done() : ed.tracksOf(TrackKind.subtitle).length > tracksBefore && ed.tracksOf(TrackKind.subtitle).last.items.isNotEmpty;
    bool asksLanguage() => E2eApp.hasKey('captions-needs-language') && E2eApp.hasKey('captions-candidate-en');
    var pending = action != null;
    final sw = Stopwatch()..start();
    if (pressCreate) await E2eApp.tapKey(t, 'captions-create');
    try {
      while (!generated()) {
        await E2eApp.pumpUntil(
          t,
          () {
            watch.poll();
            if (E2eApp.hasKey('captions-consent')) throw TestFailure('the consent view showed: the staged model was not used');
            if (E2eApp.hasKey('captions-failed')) throw TestFailure('Auto captions failed: ${state(ed)}');
            return generated() || asksLanguage() || (pending && trigger!(watch));
          },
          what: 'generated captions',
          timeout: timeout,
          step: const Duration(milliseconds: 100),
        );
        if (pending && !generated() && trigger!(watch)) {
          pending = false;
          await action!(watch);
          continue;
        }
        if (!generated() && asksLanguage()) {
          await E2eApp.tapKey(t, 'captions-candidate-en');
          await E2eApp.tapKey(t, 'captions-continue');
        }
      }
      sw.stop();
      // The sheet closes itself when the captions are added (a hidden sheet is already gone).
      await E2eApp.pumpUntil(t, () => !E2eApp.hasKey('captions-sheet'), what: 'the captions sheet to close');
    } finally {
      await watch.dispose();
    }
    final track = done != null ? ed.tracksOf(TrackKind.subtitle).firstWhere((x) => x.subtitle?.provenance != null) : ed.tracksOf(TrackKind.subtitle).last;
    final run = CaptionsRun(track, sw.elapsed, watch);
    expect(run.cues, isNotEmpty);
    expect(run.cues.every((c) => c.origin == CueOrigin.generated), isTrue, reason: 'every cue is generated');
    return run;
  }

  /// Closes the captions sheet if it is still up (as the sheet's own close does: a route pop).
  static Future<void> closeSheet(E2eEditor ed) async {
    if (!E2eApp.hasKey('captions-sheet')) return;
    await E2eApp.tapKey(ed.tester, 'captions-cancel');
    await E2eApp.pumpUntil(ed.tester, () => !E2eApp.hasKey('captions-sheet'), what: 'the captions sheet to close');
  }

  /// Exports [track] through the subtitle export panel in [format] and parses the delivered file.
  static Future<List<(int, int, String)>> exportParsed(E2eEditor ed, Track track, SubtitleFormat format) async {
    final t = ed.tester;
    await ed.select(track.items.first.id);
    final handoffs = E2eApp.world.engine.files.records.length;
    await ed.invoke(EditorActionId.exportSubtitles);
    await E2eApp.waitKey(t, 'subtitleIo.export');
    // The track list shows only when the project has more than one subtitle track.
    if (E2eApp.hasKey('subtitleIo.exportTrack.${track.id.value}')) await E2eApp.tapKey(t, 'subtitleIo.exportTrack.${track.id.value}');
    await E2eApp.tap(
      t,
      find.descendant(of: find.byKey(const ValueKey('subtitleIo.format')), matching: find.text(format == SubtitleFormat.srt ? SubtitleIoStrings.srt : SubtitleIoStrings.vtt)),
      what: 'format ${format.name}',
    );
    await E2eApp.tapKey(t, 'subtitleIo.saveToFiles');
    await E2eApp.pumpUntil(t, () => E2eApp.world.engine.files.records.length > handoffs, what: 'the ${format.name} handoff');
    final record = E2eApp.world.engine.files.records.last;
    if (E2eApp.hasKey('subtitleIo.closeButton')) await E2eApp.tapKey(t, 'subtitleIo.closeButton', ifStillThere: true);
    await E2eApp.pumpUntil(t, () => !E2eApp.hasKey('subtitleIo.export'), what: 'the subtitle export panel to close');
    final parsed = SubtitleCodec.parse(File(record.copyPath).readAsBytesSync(), hint: format);
    int ms(int us) => (us / 1000).round();
    return [for (final c in parsed.cues) (ms(c.startUs), ms(c.endUs), c.text)];
  }

  static List<(int, int, String)> cuesMs(List<SubtitleCue> cues) {
    int ms(int us) => (us / 1000).round();
    return [for (final c in cues) (ms(c.start), ms(c.end), c.text)];
  }
}

/// The sandbox copy of the 60 s English clip, and its reference words (empty when not staged).
(String, List<String>) sixtySecondClip() {
  final source = File(Qa07.clipPath);
  if (!source.existsSync()) {
    throw StateError('The 60 s English clip is not staged at ${Qa07.clipPath}. Generate it (docs/v1.1/editor/qa/QA-07-ai.md §2) and pass '
        '--dart-define=DV_QA07_CLIP=<path> (iOS Simulator: the host path) or push it to <shared>/e2e_qa07/ (Android).');
  }
  final target = File('${E2eMedia.dir}/qa07-60s-en.m4a');
  if (!target.existsSync()) {
    target.parent.createSync(recursive: true);
    source.copySync(target.path);
  }
  final text = File(Qa07.clipTextPath);
  return (target.path, text.existsSync() ? normalizedWords(text.readAsStringSync()) : const <String>[]);
}

/// The long English clip of job-kill/job-resume (more than one 180 s chunk) copied into the media
/// folder; returns its path.
String longClip() {
  final source = File(Qa07.longClipPath);
  if (!source.existsSync()) {
    throw StateError('The long English clip is not staged at ${Qa07.longClipPath}. Generate it (docs/v1.1/editor/qa/QA-07-ai.md §2) and pass '
        '--dart-define=DV_QA07_LONG_CLIP=<path> (iOS Simulator: the host path) or push it to <shared>/e2e_qa07/ (Android).');
  }
  final target = File('${E2eMedia.dir}/qa07-long-en.m4a');
  if (!target.existsSync()) {
    target.parent.createSync(recursive: true);
    source.copySync(target.path);
  }
  return target.path;
}

/// [E2eEditor.createProject], printing what is on screen every 5 s while it waits (diagnostics).
Future<E2eEditor> newProject(WidgetTester tester, {required String name, required List<String> media}) async {
  final timer = Timer.periodic(const Duration(seconds: 5), (_) => print('DV_QA07_SCREEN ${E2eApp.describeScreen().replaceAll('\n', ' ')}'));
  try {
    return await E2eEditor.createProject(tester, name: name, media: media);
  } finally {
    timer.cancel();
  }
}

MediaClip clipNamed(E2eEditor ed, String name) => ed.items<MediaClip>().firstWhere((c) => ed.assetOf(c).displayName == name);

String stamp() => '${DateTime.now().millisecondsSinceEpoch % 100000}';

/// Pixels (every 2 px) whose luma differs by more than 40 between [a] and [b] in rows [y0, y1)
/// (QA-00 scenario 7's method).
int changedIn(E2eFrame a, E2eFrame b, double y0, double y1) {
  expect((a.width, a.height), (b.width, b.height));
  var count = 0;
  for (var y = (a.height * y0).floor(); y < a.height * y1; y += 2) {
    for (var x = 0; x < a.width; x += 2) {
      final (ar, ag, ab, _) = a.pixel(x, y);
      final (br, bg, bb, _) = b.pixel(x, y);
      if (((ar * 299 + ag * 587 + ab * 114) - (br * 299 + bg * 587 + bb * 114)).abs() > 40000) count++;
    }
  }
  return count;
}

/// A phase test (one per process).
void qaTest(String name, Future<void> Function(WidgetTester tester) body, {bool skip = false}) => testWidgets(name, body, skip: skip);

/// Closes the sheets a failed step left open and undoes its edits, so the next step starts from
/// the plain project (one project per process: the suite's app wiring opens one editor at a time).
Future<void> recover(E2eEditor ed) async {
  final tester = ed.tester;
  try {
    for (var i = 0; i < 6; i++) {
      final open = [
        for (final k in ['captions-language-picker', 'captions-sheet', 'regenerate-sheet', 'subtitleIo.export', 'export-sheet'])
          if (E2eApp.hasKey(k)) k,
      ];
      if (open.isEmpty) break;
      if (open.first == 'captions-sheet' && E2eApp.hasKey('captions-cancel')) {
        await E2eApp.tapKey(tester, 'captions-cancel', ifStillThere: true);
      } else {
        await Navigator.of(tester.element(find.byKey(ValueKey<String>(open.first)).first)).maybePop();
      }
      await tester.pump(const Duration(milliseconds: 500));
    }
    final job = Captions.service.activeJob;
    if (job != null) {
      job.cancel();
      await E2eApp.pumpUntil(tester, () => Captions.service.activeJob == null, what: 'the job to cancel', timeout: const Duration(seconds: 30));
    }
    for (var i = 0; i < 30 && ed.state.history.canUndo; i++) {
      ed.controller.undo();
      await tester.pump();
    }
  } on Object catch (e) {
    print('DV_QA07_REPORT recovery after a failed step did not finish: $e');
  }
}

/// State shared by the steps.
abstract final class Shared {
  /// q05's tier and its uninterrupted result.
  static SpeechModelTier? sixtyTier;
  static List<String>? sixtyWords;
}

typedef Step = Future<void> Function(WidgetTester tester, E2eEditor ed);

// -------------------------------------------------------------------------------------------------
// Default-phase steps (one project: frame_counter, speech_10s and the 60 s English clip)
// -------------------------------------------------------------------------------------------------

/// Undo until the project has no captions (one undo per generated run).
Future<void> undoCaptions(E2eEditor ed) async {
  await ed.invoke(EditorActionId.undo);
  await ed.waitProject((p) => ed.items<SubtitleCue>().isEmpty, what: 'one undo to remove all captions');
}

Future<void> q01(WidgetTester tester, E2eEditor ed) async {
  // A fresh install: no model, no partial file.
  await Captions.service.deleteModel();
  expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelMissing>());
  final net = NetRecorder().install();
  try {
    await Captions.open(ed, [clipNamed(ed, Fx.speech).id]);
    await Captions.configure(ed, tier: SpeechModelTier.fast);
    await E2eApp.tapKey(tester, 'captions-create');
    await E2eApp.waitKey(tester, 'captions-consent');
    await E2eApp.screenshot(tester, 'qa07_q01_consent');
    final disclosure = Captions.state(ed).disclosure;
    expect(disclosure, isNotNull, reason: 'the consent view names what will be downloaded');
    expect(disclosure!.modelId, SpeechModelCatalog.fast.id);
    expect(net.clients, isEmpty, reason: 'no HTTP client before consent: ${net.clients}');
    expect((await Captions.service.storage()).partialBytes, 0, reason: 'no partial download before consent');
    await E2eApp.tapKey(tester, 'captions-consent-decline');
    await E2eApp.pumpUntil(tester, () => Captions.state(ed).stage == AutoCaptionsStage.configure, what: 'back to configure');
    await tester.pump(const Duration(seconds: 2));
    expect(net.clients, isEmpty, reason: '"Not now" makes no network access: ${net.clients}');
    expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelMissing>());
    Qa07.report('q01', 'consent shown with ${disclosure.totalBytes} B disclosed; 0 HTTP clients before and after "Not now"');
    await Captions.closeSheet(ed);
  } finally {
    net.uninstall();
    await E2eApp.stageSpeechModel();
  }
}

Future<void> q02(WidgetTester tester, E2eEditor ed) async {
  final speech = clipNamed(ed, Fx.speech).id;
  Captions.clearTranscripts();
  await Captions.open(ed, [speech]);
  await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
  final explicit = await Captions.create(ed);
  expect(explicit.provenance.language, startsWith('en'));
  expect(explicit.provenance.languageDetected, isFalse);
  expect(explicit.watch.phases, isNot(contains(TranscriptionPhase.detectingLanguage)), reason: 'an explicit language skips detection');
  await undoCaptions(ed);

  Captions.clearTranscripts();
  await Captions.open(ed, [speech]);
  await Captions.configure(ed, tier: SpeechModelTier.fast, language: const AutoLanguage());
  final auto = await Captions.create(ed);
  expect(auto.provenance.language, startsWith('en'), reason: 'speech_10s is English');
  final asked = auto.watch.phases.contains(TranscriptionPhase.needsLanguage);
  if (!asked) expect(auto.provenance.languageDetected, isTrue);
  Qa07.report('q02',
      'explicit: ${explicit.cues.length} cues; detect: ${auto.cues.length} cues, language ${auto.provenance.language} p=${auto.provenance.languageConfidence} ${asked ? '(asked, answered English)' : '(confident)'}');
  await undoCaptions(ed);
}

Future<void> q03(WidgetTester tester, E2eEditor ed) async {
  final speech = clipNamed(ed, Fx.speech).id;
  Captions.clearTranscripts();
  await Captions.open(ed, [speech]);
  await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
  final run = await Captions.create(ed);
  final track = run.track;
  final original = Captions.cuesMs(run.cues);
  final historyBase = ed.state.history.undoLabel;

  // One undo removes every generated cue (and the lane); redo brings them back.
  await undoCaptions(ed);
  await ed.invoke(EditorActionId.redo);
  await ed.waitProject((p) => ed.items<SubtitleCue>().length == original.length, what: 'redo');

  // SRT and VTT exports parse back to the same cues.
  for (final format in [SubtitleFormat.srt, SubtitleFormat.vtt]) {
    final parsed = await Captions.exportParsed(ed, ed.tracksOf(TrackKind.subtitle).firstWhere((t) => t.id == track.id), format);
    expect(parsed, original, reason: '${format.name} round trip');
  }

  // Regenerate › Re-split (instant, from the cached transcript, one history entry).
  Track lane() => ed.tracksOf(TrackKind.subtitle).firstWhere((t) => t.id == track.id);
  List<SubtitleCue> laneCues() => [for (final i in lane().items) i as SubtitleCue];
  final before = laneCues();
  final preset = lane().subtitle!.provenance!.segmentation.preset == SegmentationPreset.singleLine ? SegmentationPreset.shortPhrases : SegmentationPreset.singleLine;
  unawaited(RegenerateSheet.show(tester.element(find.byType(EditorScreen).last), projectId: ed.id, track: track.id));
  await E2eApp.waitKey(tester, 'regenerate-sheet');
  await E2eApp.tap(tester, find.descendant(of: find.byKey(const ValueKey('regenerate-layout')), matching: find.text(CaptionsStrings.presetName(preset))),
      what: 'layout ${preset.name}');
  final sw = Stopwatch()..start();
  await E2eApp.tapKey(tester, 'regenerate-apply');
  await E2eApp.pumpUntil(tester, () => lane().subtitle!.provenance!.segmentation.preset == preset, what: 'the re-split', timeout: const Duration(seconds: 10));
  sw.stop();
  await E2eApp.pumpUntil(tester, () => !E2eApp.hasKey('regenerate-sheet'), what: 'the regenerate sheet to close');
  final resplit = laneCues();
  expect(normalizedWords(resplit.map((c) => c.text).join(' ')), normalizedWords(before.map((c) => c.text).join(' ')),
      reason: 're-split keeps the recognised words');
  if (preset == SegmentationPreset.singleLine) expect(resplit.every((c) => !c.text.contains('\n')), isTrue, reason: 'one line per cue');
  expect(sw.elapsed, lessThan(Qa07.limit(const Duration(seconds: 2))),
      reason: 're-split is instant (no transcription): ${sw.elapsedMilliseconds} ms (${Qa07.perfMode})');
  await ed.invoke(EditorActionId.undo);
  await ed.waitProject((p) => Captions.cuesMs(laneCues()).toString() == Captions.cuesMs(before).toString(), what: 'undo of the re-split');

  // Regenerate › Transcribe again (full): replaces the lane's cues, one history entry.
  final generatedAt = lane().subtitle!.provenance!.generatedAt;
  unawaited(RegenerateSheet.show(tester.element(find.byType(EditorScreen).last), projectId: ed.id, track: track.id));
  await E2eApp.waitKey(tester, 'regenerate-sheet');
  await E2eApp.tapKey(tester, 'regenerate-mode-transcribe');
  await E2eApp.tapKey(tester, 'regenerate-apply');
  await E2eApp.waitKey(tester, 'captions-configure', timeout: const Duration(seconds: 30));
  Captions.clearTranscripts();
  final tracks = ed.tracksOf(TrackKind.subtitle).length;
  final full = await Captions.create(ed, done: () => lane().subtitle!.provenance!.generatedAt != generatedAt && laneCues().isNotEmpty);
  expect(ed.tracksOf(TrackKind.subtitle).length, tracks, reason: 'the lane was replaced, not added');
  expect(full.watch.phases, contains(TranscriptionPhase.transcribing), reason: 'transcribed again');
  await ed.invoke(EditorActionId.undo);
  await ed.waitProject((p) => lane().subtitle!.provenance!.generatedAt == generatedAt, what: 'undo of the full regenerate');
  Qa07.report('q03', 'undo/redo ok; SRT+VTT round trip ${original.length} cues; re-split to ${preset.name} in ${sw.elapsedMilliseconds} ms '
      '(${before.length} -> ${resplit.length} cues); full regenerate ${full.elapsed.inMilliseconds} ms');

  // Burn-in (QA-00 scenario 7's method): cue 1 English as generated, cue 2 Arabic, cue 3 Japanese.
  final cues = laneCues();
  const scripts = ['مرحبا بكم في المحرر', 'ようこそ、編集へ'];
  for (final (i, text) in scripts.indexed) {
    if (cues.length > i + 1) ed.apply(SetCueText(cues[i + 1].id, text));
  }
  ed.apply(SetBurnIn(track.id, true));
  final duration = ed.project.duration;
  final a = await E2eExport.run(ed, configure: (x) => x.copyWith(burnInSubtitles: {track.id: true}, sideFiles: const {}));
  final b = await E2eExport.run(ed, configure: (x) => x.copyWith(burnInSubtitles: {track.id: false}, sideFiles: const {}));
  await E2eExport.expectConformant(a.video, width: 1280, height: 720, duration: duration, rate: ed.rate);
  final burned = laneCues().take(3).toList();
  final mids = [for (final c in burned) (c.start + c.end) ~/ 2];
  // A time no cue covers (± 2 frames), for "identical between cues".
  final frame = ed.rate.timeOfFrame(1);
  final all = laneCues();
  TimeUs? between;
  for (var t = frame * 6; t < duration - frame * 6; t += frame) {
    if (all.every((c) => t < c.start - 2 * frame || t > c.end + 2 * frame)) {
      between = t;
      break;
    }
  }
  final times = [...mids, if (between != null) between];
  final fa = await E2eExport.frames(ed, a.video, times);
  final fb = await E2eExport.frames(ed, b.video, times);
  const subY0 = 0.70;
  final changed = <int>[];
  for (var i = 0; i < mids.length; i++) {
    changed.add(changedIn(fa[i], fb[i], subY0, 1));
    // A short Arabic or Japanese line changes fewer pixels than s07's longer Latin cues; anything
    // well above the codec-noise bound of "identical" (< 60) is a burned cue.
    expect(changed.last, greaterThan(150), reason: 'cue ${i + 1} (${['generated English', 'Arabic', 'Japanese'][i]}) burned in the subtitle area');
  }
  if (between != null) {
    final d = changedIn(fa.last, fb.last, subY0, 1);
    expect(d, lessThan(60), reason: 'nothing burned between cues');
    changed.add(d);
  } else {
    Qa07.report('q03', 'no uncovered time between cues inside the video; "identical between cues" not sampled');
  }
  Qa07.report('q03', 'burn-in changed pixels at cue midpoints ${mids.map((m) => m ~/ 1000).toList()} ms / between ${between == null ? '-' : between ~/ 1000} ms: $changed');
  // Back to the plain project: the cue edits, the burn-in flag and the captions.
  for (var i = 0; i < 10 && ed.items<SubtitleCue>().isNotEmpty; i++) {
    ed.controller.undo();
    await tester.pump();
  }
  expect(ed.items<SubtitleCue>(), isEmpty, reason: 'undo back to the project before captions (from "$historyBase")');
}

Future<void> q04(WidgetTester tester, E2eEditor ed) async {
  final speech = clipNamed(ed, Fx.speech);
  final cut = speech.start + 5000000;
  ed.apply(SplitItems({speech.id}, cut));
  await ed.waitProject((p) => ed.items<MediaClip>().where((c) => ed.assetOf(c).displayName == Fx.speech).length == 2, what: 'the split');
  final pieces = ed.items<MediaClip>().where((c) => ed.assetOf(c).displayName == Fx.speech).toList()..sort((x, y) => x.start.compareTo(y.start));
  ed.apply(SetSpeed(pieces[1].id, const ConstantSpeed(2), ripple: false));
  await ed.waitProject((p) => (ed.item(pieces[1].id) as MediaClip).duration < pieces[1].duration, what: 'the 2x piece');
  final left = ed.item(pieces[0].id);
  final right = ed.item(pieces[1].id);

  Captions.clearTranscripts();
  await Captions.open(ed, [left.id, right.id]);
  await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
  final run = await Captions.create(ed);
  final frame = ed.rate.timeOfFrame(1);
  // A cue starts at its first word and ends at its last word plus the segmenter's linger (and its
  // minimum duration), so it may run past the clip by up to about a second, never more.
  const tail = 1000000;
  for (final c in run.cues) {
    expect(c.start >= left.start - frame && c.start < right.end && c.end <= right.end + tail, isTrue,
        reason: 'cue ${c.start}..${c.end} lies on the captioned clips ${left.start}..${right.end} (+ linger)');
  }
  expect(run.cues.any((c) => c.end > right.start), isTrue, reason: 'the 2x piece is captioned');
  final inRight = run.cues.where((c) => c.start >= right.start - frame).toList();
  for (final c in inRight) {
    expect(c.end <= right.end + tail, isTrue, reason: 'a cue of the 2x piece ends with it (speed applied to the mapping)');
  }
  // Without the speed map the 2x piece's words would land up to 2.5 s past its end.
  expect(run.cues.last.start, lessThan(right.end), reason: 'the last cue starts inside the 2x piece');
  Qa07.report('q04', '${run.cues.length} cues; left ${left.start}..${left.end}, 2x ${right.start}..${right.end}; ${inRight.length} cues in the 2x piece');
  // Captions, speed, split.
  for (var i = 0; i < 3; i++) {
    await ed.invoke(EditorActionId.undo);
  }
  await ed.waitProject((p) => ed.items<MediaClip>().where((c) => ed.assetOf(c).displayName == Fx.speech).length == 1 && ed.items<SubtitleCue>().isEmpty,
      what: 'undo back to one speech clip');
}

Future<void> q05(WidgetTester tester, E2eEditor ed) async {
  final tier = await Captions.stage(Qa07.requestedTier);
  final reference = sixtySecondClip().$2;
  final item = clipNamed(ed, 'qa07-60s-en.m4a');
  Captions.clearTranscripts();
  await Captions.open(ed, [item.id]);
  await Captions.configure(ed, tier: tier, language: const FixedLanguage('en'));
  final run = await Captions.create(ed);
  final audio = Duration(microseconds: item.duration);
  final budget = Qa07.budget(tier, audio);
  final words = run.words;
  final rate = wer(reference, words);
  Qa07.report('q05',
      'tier ${tier.name} audio ${audio.inMilliseconds} ms run ${run.elapsed.inMilliseconds} ms budget ${budget.inMilliseconds} ms cues ${run.cues.length} words ${words.length} '
      'WER ${reference.isEmpty ? 'n/a (no reference text)' : (rate * 100).toStringAsFixed(1)}% platform ${Platform.operatingSystem}');
  Shared.sixtyTier = tier;
  Shared.sixtyWords = words;
  expect(run.elapsed, lessThanOrEqualTo(Qa07.limit(budget)), reason: 'run time within the budget (${Qa07.perfMode})');
  // About 150 words: 2 lines × 42 graphemes per cue gives at least ~8 cues; one word per cue at most.
  expect(run.cues.length, inInclusiveRange(6, math.max(60, reference.length)), reason: 'cue count in range');
  if (reference.isNotEmpty) expect(rate, lessThanOrEqualTo(Qa07.maxWer), reason: 'WER vs the reference text');
  await undoCaptions(ed);
}

Future<void> q06(WidgetTester tester, E2eEditor ed) async {
  final tier = Shared.sixtyTier ?? await Captions.stage(Qa07.requestedTier);
  final item = clipNamed(ed, 'qa07-60s-en.m4a');
  final governor = Captions.runtime.governor;
  final reference = Shared.sixtyWords;

  // Thermal: critical pauses generation at the next chunk boundary; back to nominal resumes after the
  // governor's recovery delay (10 s). On a device the real thermal state is observed in the soak (§16.4 #2).
  Captions.clearTranscripts();
  await Captions.open(ed, [item.id]);
  await Captions.configure(ed, tier: tier, language: const FixedLanguage('en'));
  var thermalDone = false;
  final thermal = await Captions.create(
    ed,
    // Before generation starts (a 60 s unit is one chunk on a fast device, so a pause requested
    // mid-chunk only takes effect after it).
    trigger: (w) => w.last != null && w.last!.phase != TranscriptionPhase.transcribing && (w.last!.processed == 0),
    action: (w) async {
      governor.debugDeviceEvent(const whisper.ThermalChanged(whisper.ThermalLevel.critical));
      await E2eApp.pumpUntil(tester, () => w.pauses.contains(PauseReason.thermal), what: 'the thermal pause', timeout: const Duration(seconds: 30));
      // Generation stops at the next chunk boundary (the chunk in flight may finish): the job
      // stays paused and adds nothing until the device cools down.
      final tracks = ed.tracksOf(TrackKind.subtitle).length;
      final at = w.last?.processed;
      final until = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      Qa07.report('q06', 'thermal critical at ${at ?? 0} us processed; after 3 s: phase ${w.last?.phase.name}, paused ${w.last?.paused?.name}, '
          'processed ${w.last?.processed} us, captions added ${ed.tracksOf(TrackKind.subtitle).length != tracks}');
      expect(ed.tracksOf(TrackKind.subtitle).length, tracks, reason: 'no captions are added while thermally paused');
      expect(w.last?.paused, PauseReason.thermal, reason: 'still paused while critical');
      expect(w.last?.processed ?? 0, at ?? 0, reason: 'no audio is processed while thermally paused');
      await E2eApp.screenshot(tester, 'qa07_q06_thermal');
      governor.debugDeviceEvent(const whisper.ThermalChanged(whisper.ThermalLevel.nominal));
      thermalDone = true;
    },
  );
  expect(thermalDone, isTrue, reason: 'the thermal pause happened while the job ran');
  expect(thermal.watch.pauses, contains(PauseReason.thermal));
  if (reference != null) expect(thermal.words, reference, reason: 'thermally paused run gives the uninterrupted result');
  await undoCaptions(ed);

  // Export: a job started while an export runs waits for it (ai.md §6.3), then continues. The
  // export is started first: a 60 s unit is one chunk here, so a job already transcribing would
  // finish its chunk before an export could pause it.
  final handoffs = E2eApp.world.engine.files.records.length;
  final settings = await E2eExport.start(ed);
  await E2eApp.pumpUntil(tester, () {
    final st = E2eExport.state(ed);
    if (st is ExportUiNotice) unawaited(E2eExport.controller(ed).confirmNotice());
    if (st is ExportUiWarnings) unawaited(E2eExport.controller(ed).confirmWarnings());
    return governor.exportActive;
  }, what: 'the export to run', timeout: const Duration(seconds: 60));
  Captions.clearTranscripts();
  await Captions.open(ed, [item.id]);
  await Captions.configure(ed, tier: tier, language: const FixedLanguage('en'));
  var exportedWhileWaiting = false;
  final export = await Captions.create(
    ed,
    trigger: (w) => w.pauses.contains(PauseReason.waitingForExport) || w.pauses.contains(PauseReason.exportRunning),
    action: (w) async {
      expect(w.last?.processed ?? 0, 0, reason: 'nothing transcribed while the export runs');
      await E2eApp.screenshot(tester, 'qa07_q06_waiting_for_export');
      await E2eApp.pumpUntil(tester, () => !governor.exportActive, what: 'the export to finish', timeout: const Duration(minutes: 6));
      exportedWhileWaiting = true;
    },
  );
  await E2eExport.finish(ed, settings, handoffs: handoffs);
  Qa07.report('q06', 'thermal run: job pauses ${thermal.watch.pauses.map((p) => p.name).toList()}; export run: job pauses ${export.watch.pauses.map((p) => p.name).toList()}; '
      'same words as q05: ${reference == null ? 'n/a' : '${thermal.words.join(' ') == reference.join(' ')}/${export.words.join(' ') == reference.join(' ')}'}');
  expect(exportedWhileWaiting, isTrue, reason: 'the job waited while the export ran');
  expect(export.watch.pauses.any((p) => p == PauseReason.exportRunning || p == PauseReason.waitingForExport), isTrue, reason: 'the job reported the export pause');
  if (reference != null) expect(export.words, reference, reason: 'export-paused run gives the uninterrupted result');
  await undoCaptions(ed);
}

Future<void> q07(WidgetTester tester, E2eEditor ed) async {
  // Diagnostic: does the governor see a background/foreground cycle at all right now?
  final governor = Captions.runtime.governor;
  var probe = false;
  final probeSub = governor.changes.listen((_) => probe = probe || governor.inBackground);
  await E2eHandshake.request(tester, 'background', args: {'seconds': 3}, timeout: const Duration(seconds: 60));
  await tester.pump(const Duration(milliseconds: 500));
  await probeSub.cancel();
  Qa07.report('q07', 'probe without a job: governor saw the background ${probe ? 'yes' : 'NO'}');
  final tier = Shared.sixtyTier ?? await Captions.stage(Qa07.requestedTier);
  final item = clipNamed(ed, 'qa07-60s-en.m4a');
  Captions.clearTranscripts();
  await Captions.open(ed, [item.id]);
  await Captions.configure(ed, tier: tier, language: const FixedLanguage('en'));
  TimeUs? processedBefore;
  TimeUs? processedAfter;
  final run = await Captions.create(
    ed,
    // Before generation starts: a 60 s unit is one chunk on a fast device and would finish before
    // the host could act; the background pause aborts the chunk in flight anyway (ai.md §6.3).
    trigger: (w) => w.last != null && w.last!.phase != TranscriptionPhase.transcribing && w.last!.processed == 0,
    action: (w) async {
      processedBefore = w.last?.processed;
      final ack = await E2eHandshake.request(tester, 'background', args: {'seconds': 8}, timeout: const Duration(seconds: 60));
      expect(ack.ok, isTrue, reason: 'host background/foreground: $ack');
      await tester.pump(const Duration(milliseconds: 500));
      processedAfter = w.last?.processed;
    },
  );
  final reference = Shared.sixtyWords;
  Qa07.report('q07', '${Platform.operatingSystem}: governor background seen ${run.watch.sawBackground}, platform ${Captions.runtime.governor.platform.name}, '
      'governor ${run.watch.governorPauses.map((p) => p?.name ?? 'running').toList()}; job pauses ${run.watch.pauses.map((p) => p.name).toList()}; '
      'processed $processedBefore -> $processedAfter; same words as q05: ${reference == null ? 'n/a' : run.words.join(' ') == reference.join(' ')}');
  if (Platform.isIOS) {
    expect(run.watch.sawBackground, isTrue, reason: 'the governor received the background lifecycle event');
    expect(run.watch.governorPauses, contains(PauseReason.background), reason: 'iOS pauses generation in the background');
    expect(run.watch.governorPauses.last, isNull, reason: 'generation resumed in the foreground');
    if (reference != null) expect(run.words, reference, reason: 'identical result after background/resume');
  } else {
    expect(run.watch.pauses, isNot(contains(PauseReason.background)), reason: 'Android keeps running under the FGS lease');
    expect((processedAfter ?? 0) > (processedBefore ?? 0), isTrue, reason: 'progress advanced while in the background ($processedBefore -> $processedAfter)');
  }
  await undoCaptions(ed);
}

Future<void> q08(WidgetTester tester, E2eEditor ed) async {
  await Captions.stage(SpeechModelTier.fast);
  final net = NetRecorder(refuse: true).install();
  try {
    Captions.clearTranscripts();
    await Captions.open(ed, [clipNamed(ed, Fx.speech).id]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    final run = await Captions.create(ed);
    expect(net.clients, isEmpty, reason: 'no network access once the model is installed: ${net.clients}');
    Qa07.report('q08', '${run.cues.length} cues with every connection refused; 0 HTTP clients');
  } finally {
    net.uninstall();
  }
  await undoCaptions(ed);
}

Future<void> q09(WidgetTester tester, E2eEditor ed) async {
  await Captions.stage(SpeechModelTier.fast);
  final speech = clipNamed(ed, Fx.speech).id;
  await Captions.open(ed, [speech]);
  await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
  await Captions.create(ed);
  expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelReady>());
  await undoCaptions(ed);

  // Settings › Storage › "Speech model" › Delete calls the same service method.
  await Captions.service.deleteModel();
  expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelMissing>());
  final net = NetRecorder().install();
  try {
    await Captions.open(ed, [speech]);
    await Captions.configure(ed, tier: SpeechModelTier.fast);
    await E2eApp.tapKey(tester, 'captions-create');
    await E2eApp.waitKey(tester, 'captions-consent');
    expect(net.clients, isEmpty);
    await E2eApp.tapKey(tester, 'captions-consent-decline');
    await E2eApp.pumpUntil(tester, () => Captions.state(ed).stage == AutoCaptionsStage.configure, what: 'back to configure');
    Qa07.report('q09', 'model deleted -> consent view again, 0 HTTP clients');
    await Captions.closeSheet(ed);
  } finally {
    net.uninstall();
    await E2eApp.stageSpeechModel();
  }
}

// -------------------------------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const def = Qa07.phase == '';

  setUp(() {
    expect(E2eConfig.autoCaptionsFlag, isTrue, reason: 'build with --dart-define=DANAVIEW_AUTO_CAPTIONS=true');
  });

  // The default phase runs as ONE test over ONE project: the E2E wiring is built once per process
  // and a second project created through the New project sheet in a later test of the same process
  // does not open (see QA-07-ai.md, defects). Each step reports DV_QA07_STEP <id> PASS|FAIL, a failed
  // step is recovered (sheets closed, edits undone) and the next one runs; the test fails at the end
  // with every failed step listed.
  testWidgets('QA-07 auto captions scenarios q01-q09', (tester) async {
    const only = String.fromEnvironment('DV_QA07_ONLY');
    bool selected(String id) => only.isEmpty || only.split(',').map((s) => s.trim()).contains(id);
    final steps = <String, Step>{
      'q01': q01,
      'q02': q02,
      'q03': q03,
      'q04': q04,
      'q05': q05,
      'q06': q06,
      'q07': q07,
      'q08': q08,
      'q09': q09,
    };
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final ed = await newProject(tester,
        name: 'QA07 ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech), sixtySecondClip().$1]);
    final failures = <String>[];
    for (final MapEntry(key: id, value: step) in steps.entries) {
      if (!selected(id)) continue;
      if (id == 'q07' && !E2eHandshake.available) {
        print('DV_QA07_STEP q07 SKIP: needs the host driver (DV_E2E_HOST=true, tool/e2e_host.sh)');
        continue;
      }
      print('DV_QA07_STEP $id start');
      final sw = Stopwatch()..start();
      try {
        await step(tester, ed);
        print('DV_QA07_STEP $id PASS (${sw.elapsed.inSeconds} s)');
      } on Object catch (e, st) {
        failures.add('$id: $e');
        print('DV_QA07_STEP $id FAIL (${sw.elapsed.inSeconds} s): $e\n$st');
        await recover(ed);
      }
    }
    await ed.close();
    if (failures.isNotEmpty) fail('QA-07 steps failed:\n${failures.join('\n')}');
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  // Job kill and resume (ai.md §16.4 #4; ARCH §16.5 checkpoints)
  qaTest('job-kill: the app is killed mid-transcription', (tester) async {
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final ed = await newProject(tester, name: 'QA07 kill ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), longClip()]);
    final item = clipNamed(ed, 'qa07-long-en.m4a');
    expect(item.duration, greaterThan(Qa07.killAfter + 30 * 1000000), reason: 'the long clip spans more than one chunk');
    Captions.clearTranscripts();
    await Captions.open(ed, [item.id]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    await Captions.create(
      ed,
      // Past the first chunk (its checkpoint is written when the chunk ends), inside the second.
      trigger: (w) => w.transcribing && (w.last?.processed ?? 0) >= Qa07.killAfter,
      action: (w) async {
        E2eHandshake.saveState('qa07-job', {'project': ed.id.value, 'fraction': w.last?.fraction, 'processed': w.last?.processed});
        Qa07.report('job-kill', 'killing at ${w.last?.processed} us of ${item.duration} us (fraction ${w.last?.fraction})');
        await E2eHandshake.requestAndDie(tester, 'kill');
      },
      timeout: const Duration(minutes: 10),
    );
    fail('the host did not kill the app');
  }, skip: Qa07.phase != 'job-kill' || !E2eHandshake.available);

  qaTest('job-resume: the interrupted-job notice resumes from the checkpoint', (tester) async {
    final saved = E2eHandshake.loadState('qa07-job');
    expect(saved, isNotNull, reason: 'run phase job-kill first');
    final id = ProjectId(saved!['project']! as String);
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final resumable = await Captions.service.resumableFor(id);
    expect(resumable, isNotNull, reason: 'the service kept the job record');
    Qa07.report('job-resume', 'service record after the kill: ${(resumable!.doneFraction * 100).round()}% done (killed at ${saved['processed']} us)');
    final ed = await E2eEditor.openFromProjects(tester, id);
    // ai.md §8.6 / §11.5: the editor shows the interrupted-job notice when it opens the project.
    await E2eApp.waitKey(tester, 'captions-interrupted', timeout: const Duration(seconds: 30));
    await E2eApp.screenshot(tester, 'qa07_job_resume_notice');
    final watch = JobWatch(Captions.service);
    addTearDown(watch.dispose);
    await E2eApp.tapKey(tester, 'captions-interrupted-resume');
    final run = await Captions.create(ed, pressCreate: false);
    final first = run.watch.firstProcessed ?? watch.firstProcessed;
    final killedAt = (saved['processed'] as num?)?.toInt() ?? 0;
    final resumedAt = first?.processed ?? 0;
    Qa07.report('job-resume', 'record ${(resumable.doneFraction * 100).round()}% done; killed at $killedAt us; first transcribing sample with audio '
        'processed $resumedAt us, fraction ${first?.fraction}; ${run.cues.length} cues, last cue ends ${run.cues.isEmpty ? '-' : run.cues.last.end} us');
    // ai.md §8.6 / ARCH §16.5: the unit in progress continues from its last checkpointed chunk end
    // (165-195 s), so the first progress with audio processed is already past it, not near 0; the
    // work lost to the kill is at most one chunk.
    expect(resumedAt, greaterThanOrEqualTo(Qa07.firstChunkMinEnd), reason: 'resumed from the first checkpoint, not from zero');
    expect(resumedAt, lessThan(killedAt), reason: 'the checkpoint ends before the kill point');
    expect(run.cues, isNotEmpty);
    expect(run.cues.first.start, lessThan(Qa07.firstChunkMinEnd), reason: 'the checkpointed chunk\'s captions are inserted too');
    expect(run.cues.last.end, greaterThan(Qa07.killAfter), reason: 'the rest of the clip was transcribed');
    await ed.close();
  }, skip: Qa07.phase != 'job-resume');

  // ---------------------------------------------------------------------------------------------
  // Real download with resume after kill (one per platform on Wi-Fi; never in CI)
  qaTest('download: consent, then the app is killed mid-download', (tester) async {
    await E2eApp.launch(tester);
    await Captions.service.deleteModel();
    final ed = await newProject(tester, name: 'QA07 download ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
    await Captions.open(ed, [clipNamed(ed, Fx.speech).id]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    final net = NetRecorder().install();
    await E2eApp.tapKey(tester, 'captions-create');
    await E2eApp.waitKey(tester, 'captions-consent');
    expect(net.clients, isEmpty, reason: 'no network before consent');
    await E2eApp.tapKey(tester, 'captions-consent-accept');
    await E2eApp.pumpUntil(tester, () {
      final d = Captions.state(ed).download;
      return d != null && d.total > 0 && d.received >= d.total * 0.3;
    }, what: '30% of the download', timeout: const Duration(minutes: 5));
    final d = Captions.state(ed).download!;
    E2eHandshake.saveState('qa07-download', {'project': ed.id.value, 'received': d.received, 'total': d.total});
    Qa07.report('download', 'killed at ${d.received}/${d.total} B');
    await E2eHandshake.requestAndDie(tester, 'kill');
  }, skip: Qa07.phase != 'download' || !Qa07.network || !E2eHandshake.available);

  qaTest('download-resume: the download resumes from the partial file', (tester) async {
    final saved = E2eHandshake.loadState('qa07-download');
    expect(saved, isNotNull, reason: 'run phase download first');
    final id = ProjectId(saved!['project']! as String);
    await E2eApp.launch(tester);
    expect((await Captions.service.storage()).partialBytes, greaterThan(0), reason: 'the partial file survived the kill');
    final ed = await E2eEditor.openFromProjects(tester, id);
    await Captions.open(ed, [clipNamed(ed, Fx.speech).id]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    await E2eApp.tapKey(tester, 'captions-create');
    await E2eApp.waitKey(tester, 'captions-consent');
    await E2eApp.tapKey(tester, 'captions-consent-accept');
    await E2eApp.pumpUntil(tester, () => Captions.state(ed).download != null || Captions.state(ed).stage == AutoCaptionsStage.running,
        what: 'the download to restart', timeout: const Duration(minutes: 2));
    final first = Captions.state(ed).download;
    final resumed = Captions.state(ed).downloadResumed;
    final run = await Captions.create(ed, pressCreate: false, timeout: const Duration(minutes: 10));
    expect(resumed, isTrue, reason: 'the download continued from ${first?.received} B, not from 0');
    expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelReady>(), reason: 'verified (sha256) and installed');
    Qa07.report('download-resume', 'resumed at ${first?.received} B (killed at ${saved['received']}); ${run.cues.length} cues');
    await ed.close();
  }, skip: Qa07.phase != 'download-resume' || !Qa07.network);

  testWidgets('QA-07 phase needs its preconditions', (tester) async {
    print('DV_QA07_REPORT skipped phase "${Qa07.phase}": needs the host driver (DV_E2E_HOST=true) and, for download phases, '
        'DV_QA07_NETWORK=true. See docs/v1.1/editor/qa/QA-07-ai.md §2.');
  }, skip: def ||
      (Qa07.phase == 'job-kill' && E2eHandshake.available) ||
      Qa07.phase == 'job-resume' ||
      (Qa07.phase == 'download' && Qa07.network && E2eHandshake.available) ||
      (Qa07.phase == 'download-resume' && Qa07.network));
}
