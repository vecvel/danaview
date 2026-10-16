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
//   DV_QA07_PHASE=job-kill        start a 60 s job, the host kills the app mid-transcription
//   DV_QA07_PHASE=job-resume      relaunch: the interrupted-job notice resumes from the checkpoint
//   DV_QA07_PHASE=download        REAL NETWORK (needs DV_QA07_NETWORK=true): consent, download, the host
//                                 kills the app mid-download
//   DV_QA07_PHASE=download-resume REAL NETWORK: the download resumes from the partial file and the job runs
//
// Defines (besides the E2E suite's DANAVIEW_EDITOR, DANAVIEW_AUTO_CAPTIONS, DV_E2E_FIXTURES, DV_E2E_MODELS,
// DV_E2E_HOST):
//   DV_QA07_CLIP=<file>       the 60 s English clip (default <shared>/e2e_qa07/qa07-60s-en.m4a)
//   DV_QA07_CLIP_TEXT=<file>  its reference transcript (default: the clip path with .txt)
//   DV_QA07_TIER=balanced     tier of q05-q07 (falls back to fast, reported, when the model is not staged)
//   DV_QA07_BUDGET_MS=<ms>    q05 budget (device: the ai-eval.md §5 figure; default sized for a simulator)
//   DV_QA07_NETWORK=true      allows the download phases
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
  static const String _tier = String.fromEnvironment('DV_QA07_TIER', defaultValue: 'balanced');
  static const int _budgetMs = int.fromEnvironment('DV_QA07_BUDGET_MS');
  static const bool network = bool.fromEnvironment('DV_QA07_NETWORK');

  /// ai.md §16.4 scenario 1.
  static const double maxWer = 0.15;

  static String get clipPath => _clip.isNotEmpty ? _clip : '${E2eConfig.hostSharedDir}/e2e_qa07/qa07-60s-en.m4a';

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
  JobWatch(this.service) {
    _events = service.events.listen((e) {
      if (e is JobStarted) attach(e.job);
    });
  }

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
    final paused = p.paused;
    if (paused != null && (pauses.isEmpty || pauses.last != paused)) pauses.add(paused);
  }

  bool get transcribing => last?.phase == TranscriptionPhase.transcribing && last?.paused == null;

  Future<void> dispose() async {
    await _events.cancel();
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
    final watch = JobWatch(service);
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
    final sheet = find.byKey(const ValueKey('captions-sheet'));
    if (sheet.evaluate().isEmpty) return;
    await Navigator.of(ed.tester.element(sheet.first)).maybePop();
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

/// State shared by the tests of one run (one process).
abstract final class Shared {
  /// q05's project and its uninterrupted result.
  static ProjectId? sixtyProject;
  static SpeechModelTier? sixtyTier;
  static List<String>? sixtyWords;
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

  // ---------------------------------------------------------------------------------------------
  testWidgets('q01 consent is shown before any network access; "Not now" downloads nothing', (tester) async {
    await E2eApp.launch(tester);
    // A fresh install: no model, no partial file.
    await Captions.service.deleteModel();
    expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelMissing>());
    final net = NetRecorder().install();
    addTearDown(net.uninstall);

    final ed = await E2eEditor.createProject(tester, name: 'QA07 consent ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
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
    await ed.close();
    await E2eApp.stageSpeechModel();
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  testWidgets('q02 spoken language: explicit English, then "Detect automatically"', (tester) async {
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final ed = await E2eEditor.createProject(tester, name: 'QA07 language ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
    final speech = clipNamed(ed, Fx.speech).id;

    Captions.clearTranscripts();
    await Captions.open(ed, [speech]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    final explicit = await Captions.create(ed);
    expect(explicit.provenance.language, startsWith('en'));
    expect(explicit.provenance.languageDetected, isFalse);
    expect(explicit.watch.phases, isNot(contains(TranscriptionPhase.detectingLanguage)), reason: 'an explicit language skips detection');

    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => ed.items<SubtitleCue>().isEmpty, what: 'undo');

    Captions.clearTranscripts();
    await Captions.open(ed, [speech]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const AutoLanguage());
    final auto = await Captions.create(ed);
    expect(auto.provenance.language, startsWith('en'), reason: 'speech_10s is English');
    final asked = auto.watch.phases.contains(TranscriptionPhase.needsLanguage);
    if (!asked) expect(auto.provenance.languageDetected, isTrue);
    Qa07.report('q02',
        'explicit: ${explicit.cues.length} cues; detect: ${auto.cues.length} cues, language ${auto.provenance.language} p=${auto.provenance.languageConfidence} ${asked ? '(asked, answered English)' : '(confident)'}');
    await ed.close();
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  testWidgets('q03 generated captions: undo, SRT/VTT, regenerate, burn-in', (tester) async {
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final ed = await E2eEditor.createProject(tester, name: 'QA07 generated ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
    final speech = clipNamed(ed, Fx.speech).id;
    Captions.clearTranscripts();
    await Captions.open(ed, [speech]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    final run = await Captions.create(ed);
    final track = run.track;
    final original = Captions.cuesMs(run.cues);

    // One undo removes every generated cue (and the lane); redo brings them back.
    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => ed.items<SubtitleCue>().isEmpty, what: 'one undo to remove all captions');
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
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)), reason: 're-split is instant (no transcription)');
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
    await E2eExport.expectConformant(a.video, width: 1280, height: 720, duration: duration, rate: ed.rate, audio: true);
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
      expect(changed.last, greaterThan(300), reason: 'cue ${i + 1} (${['generated English', 'Arabic', 'Japanese'][i]}) burned in the subtitle area');
    }
    if (between != null) {
      final d = changedIn(fa.last, fb.last, subY0, 1);
      expect(d, lessThan(60), reason: 'nothing burned between cues');
      changed.add(d);
    } else {
      Qa07.report('q03', 'no uncovered time between cues in this project; "identical between cues" not sampled');
    }
    Qa07.report('q03', 'burn-in changed pixels at cue midpoints / between: $changed');
    await ed.close();
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  testWidgets('q04 split clip plus a 2x speed piece map to the timeline', (tester) async {
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final ed = await E2eEditor.createProject(tester, name: 'QA07 mapping ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
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
    for (final c in run.cues) {
      expect(c.start >= left.start - frame && c.end <= right.end + frame, isTrue,
          reason: 'cue ${c.start}..${c.end} lies inside the captioned clips ${left.start}..${right.end}');
    }
    expect(run.cues.any((c) => c.end > right.start), isTrue, reason: 'the 2x piece is captioned');
    final inRight = run.cues.where((c) => c.start >= right.start - frame).toList();
    for (final c in inRight) {
      expect(c.end <= right.end + frame, isTrue, reason: 'a cue of the 2x piece ends inside it (speed applied to the mapping)');
    }
    Qa07.report('q04', '${run.cues.length} cues; left ${left.start}..${left.end}, 2x ${right.start}..${right.end}; ${inRight.length} cues in the 2x piece');
    await ed.close();
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  testWidgets('q05 60 s English clip within the budget', (tester) async {
    await E2eApp.launch(tester);
    final tier = await Captions.stage(Qa07.requestedTier);
    final (clip, reference) = sixtySecondClip();
    final ed = await E2eEditor.createProject(tester, name: 'QA07 sixty ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), clip]);
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
    expect(run.elapsed, lessThanOrEqualTo(budget), reason: 'run time within the budget');
    // About 150 words: 2 lines × 42 graphemes per cue gives at least ~8 cues; one word per cue at most.
    expect(run.cues.length, inInclusiveRange(6, math.max(60, reference.length)), reason: 'cue count in range');
    if (reference.isNotEmpty) expect(rate, lessThanOrEqualTo(Qa07.maxWer), reason: 'WER vs the reference text');
    Shared.sixtyProject = ed.id;
    Shared.sixtyTier = tier;
    Shared.sixtyWords = words;
    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => ed.items<SubtitleCue>().isEmpty, what: 'undo');
    await ed.close();
  }, skip: !def);

  // Opens q05's project (or makes a new one with the clip).
  Future<(E2eEditor, MediaClip, SpeechModelTier)> sixty(WidgetTester tester) async {
    await E2eApp.launch(tester);
    final tier = Shared.sixtyTier ?? await Captions.stage(Qa07.requestedTier);
    await Captions.stage(tier);
    final id = Shared.sixtyProject;
    final ed = id != null
        ? await E2eEditor.openFromProjects(tester, id)
        : await E2eEditor.createProject(tester, name: 'QA07 sixty ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), sixtySecondClip().$1]);
    return (ed, clipNamed(ed, 'qa07-60s-en.m4a'), tier);
  }

  // ---------------------------------------------------------------------------------------------
  testWidgets('q06 thermal and export pausing observed; the result is unchanged', (tester) async {
    final (ed, item, tier) = await sixty(tester);
    final governor = Captions.runtime.governor;
    Captions.clearTranscripts();
    await Captions.open(ed, [item.id]);
    await Captions.configure(ed, tier: tier, language: const FixedLanguage('en'));
    var stage = 0;
    final run = await Captions.create(
      ed,
      trigger: (w) => w.transcribing && (w.last?.fraction ?? 0) >= 0.25,
      action: (w) async {
        // Thermal: critical pauses at the next chunk boundary; back to nominal resumes after the
        // governor's recovery delay. On a device the real thermal state is observed in the soak (§16.4 #2).
        governor.debugDeviceEvent(const whisper.ThermalChanged(whisper.ThermalLevel.critical));
        await E2eApp.pumpUntil(tester, () => w.pauses.contains(PauseReason.thermal), what: 'the thermal pause', timeout: const Duration(seconds: 30));
        await E2eApp.screenshot(tester, 'qa07_q06_thermal');
        governor.debugDeviceEvent(const whisper.ThermalChanged(whisper.ThermalLevel.nominal));
        await E2eApp.pumpUntil(tester, () => w.last?.paused == null, what: 'resume after the thermal pause', timeout: const Duration(seconds: 40));
        stage = 1;
        // Export: the job pauses while an export runs, then continues.
        await E2eApp.tapKey(tester, 'captions-hide');
        await E2eApp.pumpUntil(tester, () => !E2eApp.hasKey('captions-sheet'), what: 'the captions sheet to hide');
        final handoffs = E2eApp.world.engine.files.records.length;
        final settings = await E2eExport.start(ed);
        await E2eApp.pumpUntil(tester, () => w.pauses.contains(PauseReason.exportRunning) || w.pauses.contains(PauseReason.waitingForExport),
            what: 'the export pause', timeout: const Duration(seconds: 60));
        await E2eExport.finish(ed, settings, handoffs: handoffs);
        stage = 2;
      },
    );
    expect(stage, 2, reason: 'both pauses were exercised while the job ran');
    expect(run.watch.pauses, containsAllInOrder([PauseReason.thermal]));
    expect(run.watch.pauses.any((p) => p == PauseReason.exportRunning || p == PauseReason.waitingForExport), isTrue);
    final reference = Shared.sixtyWords;
    if (reference != null) expect(run.words, reference, reason: 'paused and resumed run gives the uninterrupted result');
    Qa07.report('q06', 'pauses ${run.watch.pauses.map((p) => p.name).toList()}; ${run.cues.length} cues; same words as q05: ${reference == null ? 'n/a' : run.words.join(' ') == reference.join(' ')}');
    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => ed.items<SubtitleCue>().isEmpty, what: 'undo');
    await ed.close();
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  testWidgets('q07 background mid-job: iOS pauses and resumes, Android keeps running', (tester) async {
    final (ed, item, tier) = await sixty(tester);
    Captions.clearTranscripts();
    await Captions.open(ed, [item.id]);
    await Captions.configure(ed, tier: tier, language: const FixedLanguage('en'));
    TimeUs? processedBefore;
    TimeUs? processedAfter;
    final run = await Captions.create(
      ed,
      trigger: (w) => w.transcribing && (w.last?.fraction ?? 0) >= 0.2,
      action: (w) async {
        processedBefore = w.last?.processed;
        final ack = await E2eHandshake.request(tester, 'background', args: {'seconds': 8}, timeout: const Duration(seconds: 60));
        expect(ack.ok, isTrue, reason: 'host background/foreground: $ack');
        await tester.pump(const Duration(milliseconds: 500));
        processedAfter = w.last?.processed;
      },
    );
    final reference = Shared.sixtyWords;
    if (Platform.isIOS) {
      expect(run.watch.pauses, contains(PauseReason.background), reason: 'iOS pauses the job in the background');
      if (reference != null) expect(run.words, reference, reason: 'identical result after background/resume');
    } else {
      expect(run.watch.pauses, isNot(contains(PauseReason.background)), reason: 'Android keeps running under the FGS lease');
      expect((processedAfter ?? 0) > (processedBefore ?? 0), isTrue, reason: 'progress advanced while in the background ($processedBefore -> $processedAfter)');
    }
    Qa07.report('q07',
        '${Platform.operatingSystem}: pauses ${run.watch.pauses.map((p) => p.name).toList()}; processed $processedBefore -> $processedAfter; same words as q05: ${reference == null ? 'n/a' : run.words.join(' ') == reference.join(' ')}');
    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => ed.items<SubtitleCue>().isEmpty, what: 'undo');
    await ed.close();
  }, skip: !def || !E2eHandshake.available);

  // ---------------------------------------------------------------------------------------------
  testWidgets('q08 offline after the download: a job runs with every connection refused', (tester) async {
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final net = NetRecorder(refuse: true).install();
    addTearDown(net.uninstall);
    final ed = await E2eEditor.createProject(tester, name: 'QA07 offline ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
    Captions.clearTranscripts();
    await Captions.open(ed, [clipNamed(ed, Fx.speech).id]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    final run = await Captions.create(ed);
    expect(net.clients, isEmpty, reason: 'no network access once the model is installed: ${net.clients}');
    Qa07.report('q08', '${run.cues.length} cues offline; 0 HTTP clients');
    await ed.close();
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  testWidgets('q09 deleting the model asks for consent again', (tester) async {
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final ed = await E2eEditor.createProject(tester, name: 'QA07 delete ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
    final speech = clipNamed(ed, Fx.speech).id;
    await Captions.open(ed, [speech]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    await Captions.create(ed);
    expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelReady>());

    // Settings › Storage › "Speech model" › Delete calls the same service method.
    await Captions.service.deleteModel();
    expect(await Captions.service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelMissing>());
    final net = NetRecorder().install();
    addTearDown(net.uninstall);
    await Captions.open(ed, [speech]);
    await Captions.configure(ed, tier: SpeechModelTier.fast);
    await E2eApp.tapKey(tester, 'captions-create');
    await E2eApp.waitKey(tester, 'captions-consent');
    expect(net.clients, isEmpty);
    await E2eApp.tapKey(tester, 'captions-consent-decline');
    await E2eApp.pumpUntil(tester, () => Captions.state(ed).stage == AutoCaptionsStage.configure, what: 'back to configure');
    Qa07.report('q09', 'model deleted -> consent view again, 0 HTTP clients');
    await Captions.closeSheet(ed);
    await ed.close();
    await E2eApp.stageSpeechModel();
  }, skip: !def);

  // ---------------------------------------------------------------------------------------------
  // Job kill and resume (ai.md §16.4 #4; ARCH §16.5 checkpoints)
  testWidgets('job-kill: the app is killed mid-transcription', (tester) async {
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final (clip, _) = sixtySecondClip();
    final ed = await E2eEditor.createProject(tester, name: 'QA07 kill ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), clip]);
    Captions.clearTranscripts();
    await Captions.open(ed, [clipNamed(ed, 'qa07-60s-en.m4a').id]);
    await Captions.configure(ed, tier: SpeechModelTier.fast, language: const FixedLanguage('en'));
    await Captions.create(
      ed,
      trigger: (w) => w.transcribing && (w.last?.fraction ?? 0) >= 0.4,
      action: (w) async {
        E2eHandshake.saveState('qa07-job', {'project': ed.id.value, 'fraction': w.last?.fraction, 'processed': w.last?.processed});
        await E2eHandshake.requestAndDie(tester, 'kill');
      },
    );
    fail('the host did not kill the app');
  }, skip: Qa07.phase != 'job-kill' || !E2eHandshake.available);

  testWidgets('job-resume: the interrupted-job notice resumes from the checkpoint', (tester) async {
    final saved = E2eHandshake.loadState('qa07-job');
    expect(saved, isNotNull, reason: 'run phase job-kill first');
    final id = ProjectId(saved!['project']! as String);
    await E2eApp.launch(tester);
    await Captions.stage(SpeechModelTier.fast);
    final resumable = await Captions.service.resumableFor(id);
    expect(resumable, isNotNull, reason: 'the service kept the job record');
    final ed = await E2eEditor.openFromProjects(tester, id);
    await E2eApp.waitKey(tester, 'captions-interrupted', timeout: const Duration(seconds: 30));
    await E2eApp.screenshot(tester, 'qa07_job_resume_notice');
    final watch = JobWatch(Captions.service);
    addTearDown(watch.dispose);
    await E2eApp.tapKey(tester, 'captions-interrupted-resume');
    final run = await Captions.create(ed, pressCreate: false);
    final first = run.watch.firstTranscribing ?? watch.firstTranscribing;
    Qa07.report('job-resume', 'record ${(resumable!.doneFraction * 100).round()}% done; first transcribing sample processed ${first?.processed} us, '
        'fraction ${first?.fraction}; ${run.cues.length} cues');
    expect((first?.fraction ?? 0) > 0.05 || (first?.processed ?? 0) > 0, isTrue, reason: 'resumed from the checkpoint, not from zero');
    await ed.close();
  }, skip: Qa07.phase != 'job-resume');

  // ---------------------------------------------------------------------------------------------
  // Real download with resume after kill (one per platform on Wi-Fi; never in CI)
  testWidgets('download: consent, then the app is killed mid-download', (tester) async {
    await E2eApp.launch(tester);
    await Captions.service.deleteModel();
    final ed = await E2eEditor.createProject(tester, name: 'QA07 download ${stamp()}', media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)]);
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

  testWidgets('download-resume: the download resumes from the partial file', (tester) async {
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
