// OWNER: QA-05
//
// QA-05 (BUILD_PLAN M6): process death during each job type: autosave, proxy, reverse, freeze,
// export and Auto captions. The host driver (`tool/soak_host.py death`) runs the phases in order
// and kills the app (`xcrun simctl terminate` / `adb shell am force-stop`) when the test asks:
//
//   DV_E2E_PHASE=die-<job>   launch; verify the job the previous phase killed (if any); then start
//                            <job> in a fresh project and ask the host to kill the app while it runs
//   DV_E2E_PHASE=verify      launch; verify the last killed job; report every job's result
//
// Each phase that dies leaves the app installed (the host stops `flutter test` before it can
// uninstall), so the next launch sees exactly what a user would after a crash. The verification
// of a killed job (ARCH §8.3, §12.4, §15 "Job interruption", §16.5; BUILD_PLAN QA-05 "every
// interrupted job recovers or reports interrupted once; project always reopens valid"):
//
//   autosave  the project reopens valid (the Projects recovery banner restores the journal when it
//             is ahead of the main file) and holds one of the edits made while the app was killed
//   proxy     the pending proxy resumes on open and becomes ready (or, if the pending state never
//             reached disk, a new request completes)
//   reverse   the pending reversed rendition resumes on open and becomes ready
//   freeze    the pending still resumes on open and becomes ready
//   export    `activeJobs()` reports exactly one interrupted (or iOS resumable) record and nothing
//             running; the editor shows it once (a resumable job resumes and completes); after the
//             notice is dismissed the record is gone and a reopen shows nothing
//   captions  the service keeps a resumable record; the editor shows "Auto captions were
//             interrupted" once; after Discard a reopen shows no notice and the record is gone
//
// For every job the project is also opened straight from the store and validated (no violations,
// no repairs) after the editor closed it.

// ignore_for_file: implementation_imports, avoid_print

import 'package:danaview_editor/danaview_editor.dart' show EditorScreen;
import 'package:danaview_editor/src/app/strings/captions_strings.dart';
import 'package:danaview_editor/src/editor/contracts/action_binding.dart' show EditorActionSource;
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorTaskKind, SavePhase, SelectMode;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetText;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../editor/support/e2e.dart';
import 'support/soak.dart';

/// The job types, in the order the host runs them.
const List<String> soakDeathJobs = ['autosave', 'proxy', 'reverse', 'freeze', 'export', 'captions'];

const String _pendingKey = 'soak-death-pending';
const String _resultsKey = 'soak-death-results';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const phase = E2eConfig.phase;
  final hosted = E2eHandshake.available;

  for (final job in soakDeathJobs) {
    testWidgets('QA-05 death: verify the previous job, then the app dies during $job', (tester) async {
      await E2eApp.launch(tester);
      await _verifyPending(tester);
      await _startAndDie(tester, job);
    }, skip: phase != 'die-$job' || !hosted, timeout: const Timeout(Duration(minutes: 25)));
  }

  testWidgets('QA-05 death: verify the last job and report every job type', (tester) async {
    await E2eApp.launch(tester);
    await _verifyPending(tester);
    final results = E2eHandshake.loadState(_resultsKey) ?? const {};
    soakWriteJson('death', results);
    for (final job in soakDeathJobs) {
      final r = results[job] as Map<String, Object?>?;
      soakLog('death-result', '$job ${r == null ? 'NOT RUN' : '${r['ok'] == true ? 'PASS' : 'FAIL'}: ${r['detail']}'}');
    }
    const subset = String.fromEnvironment('DV_SOAK_JOBS');
    final expected = subset.isEmpty ? soakDeathJobs : subset.split(',');
    final missing = [for (final j in expected) if (!results.containsKey(j)) j];
    final failed = [for (final e in results.entries) if ((e.value as Map<String, Object?>)['ok'] != true) '${e.key}: ${(e.value as Map)['detail']}'];
    expect(missing, isEmpty, reason: 'every job type was killed and verified');
    expect(failed, isEmpty);
  }, skip: phase != 'verify' || !hosted, timeout: const Timeout(Duration(minutes: 25)));

  testWidgets('QA-05 death needs the host driver', (tester) async {
    soakLog('skip', 'process death runs through `python3 -I integration_test/editor_soak/tool/soak_host.py -p <ios|android> -d <device> death`');
  }, skip: hosted && (phase == 'verify' || phase.startsWith('die-')));
}

// -------------------------------------------------------------------------------------------------
// Start a job and die
// -------------------------------------------------------------------------------------------------

String _stamp() => '${DateTime.now().millisecondsSinceEpoch % 100000}';

void _pending(String job, E2eEditor ed, [Map<String, Object?> extra = const {}]) =>
    E2eHandshake.saveState(_pendingKey, {'job': job, 'project': ed.id.value, ...extra});

Future<Never> _startAndDie(WidgetTester tester, String job) async {
  final tag = 'death-$job';
  switch (job) {
    case 'autosave':
      final ed = await E2eEditor.createProject(tester, name: 'Soak death autosave ${_stamp()}', media: [SoakMedia.copy(Fx.frameCounter, tag)]);
      await ed.invoke(EditorActionId.addText);
      await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'the text');
      final text = ed.items<TextItem>().single.id;
      ed.apply(SetText(text, 'SOAK AUTOSAVE 0'));
      await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.saved, what: 'the first autosave', timeout: const Duration(seconds: 30));
      _pending(job, ed, {'item': text.value});
      // Keep editing (and autosaving) until the host kills the process mid-stream.
      E2eHandshake.post('kill');
      final end = DateTime.now().add(const Duration(minutes: 3));
      var i = 1;
      var saving = 0;
      while (DateTime.now().isBefore(end)) {
        ed.controller.apply(SetText(text, 'SOAK AUTOSAVE ${i++}'));
        if (ed.state.save.phase == SavePhase.saving) saving++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump();
        if (i % 25 == 0) soakLog('death', 'autosave edits $i, saw saving $saving times');
      }
      fail('the host did not kill the app');
    case 'proxy':
      final ed = await E2eEditor.createProject(tester, name: 'Soak death proxy ${_stamp()}', media: [SoakMedia.copy(Fx.frameCounter, tag)]);
      final asset = ed.project.pool.assets.values.firstWhere((a) => a.kind == MediaKind.video);
      expect(ed.tasks.requestProxy(asset.id), isTrue, reason: 'the proxy job starts');
      await _dieDuringTask(tester, ed, job, EditorTaskKind.proxy, {'media': asset.id.value});
    case 'reverse':
      final ed = await E2eEditor.createProject(tester, name: 'Soak death reverse ${_stamp()}', media: [SoakMedia.copy(Fx.frameCounter, tag)]);
      final clip = ed.mainTrack.items.first as MediaClip;
      await ed.select(clip.id);
      await ed.invoke(EditorActionId.reverse);
      await ed.waitProject((p) => (ed.item(clip.id) as MediaClip).reversed, what: 'the reversed clip');
      await _dieDuringTask(tester, ed, job, EditorTaskKind.reverse, {'item': clip.id.value});
    case 'freeze':
      final ed = await E2eEditor.createProject(tester, name: 'Soak death freeze ${_stamp()}', media: [SoakMedia.copy(Fx.frameCounter, tag)]);
      final clip = ed.mainTrack.items.first as MediaClip;
      await ed.seekFrame(45);
      await ed.select(clip.id);
      await ed.invoke(EditorActionId.freeze);
      await E2eApp.waitKey(tester, 'freeze.sheet');
      await E2eApp.tapKey(tester, 'freeze.confirm');
      await ed.waitProject((p) => p.pool.assets.values.any((a) => a.kind == MediaKind.still && a.derived != null), what: 'the pending still');
      await _dieDuringTask(tester, ed, job, EditorTaskKind.freeze, const {});
    case 'export':
      // 32 s of 1080p so the export is still running when the host acts.
      final ed = await E2eEditor.createProject(
        tester,
        name: 'Soak death export ${_stamp()}',
        media: [for (var i = 0; i < 4; i++) SoakMedia.copy(Fx.toneUnderVideo, '$tag$i')],
      );
      await E2eExport.start(ed, configure: (s) => s.copyWith(shortSide: 1080));
      await E2eApp.pumpUntil(
        tester,
        () {
          final s = E2eExport.state(ed);
          if (s is ExportUiNotice) E2eExport.controller(ed).confirmNotice();
          if (s is ExportUiWarnings) E2eExport.controller(ed).confirmWarnings();
          if (s is ExportUiFailed) throw TestFailure('export failed: ${s.failure}');
          return s is ExportUiRunning && s.fraction > 0.1;
        },
        what: 'the export to pass 10 %',
        timeout: const Duration(minutes: 3),
      );
      final s = E2eExport.state(ed) as ExportUiRunning;
      _pending(job, ed, {'fraction': s.fraction});
      soakLog('death', 'export killed at ${(s.fraction * 100).round()} %');
      await E2eHandshake.requestAndDie(tester, 'kill');
    case 'captions':
      final staged = await E2eApp.stageSpeechModel();
      expect(staged, isTrue, reason: 'stage the tiny model in ${E2eConfig.modelsDir}');
      // Six speech clips (60 s of audio) so transcription is still running when the host acts.
      final ed = await E2eEditor.createProject(
        tester,
        name: 'Soak death captions ${_stamp()}',
        media: [SoakMedia.copy(Fx.frameCounter, tag), for (var i = 0; i < 6; i++) SoakMedia.copy(Fx.speech, '$tag$i')],
      );
      final speech = [for (final c in ed.items<MediaClip>()) if (ed.assetOf(c).kind == MediaKind.audio) c];
      expect(speech, hasLength(6));
      await ed.select(speech.first.id);
      for (final c in speech.skip(1)) {
        await ed.select(c.id, mode: SelectMode.extend);
      }
      await ed.invoke(EditorActionId.autoCaptions, source: EditorActionSource.toolTile);
      await E2eApp.waitKey(tester, 'captions-sheet');
      await E2eApp.waitKey(tester, 'captions-configure', timeout: const Duration(seconds: 30));
      final scope = find.descendant(of: find.byKey(const ValueKey('captions-scope')), matching: find.text(CaptionsStrings.selectionScope(speech.length)));
      if (scope.evaluate().isNotEmpty) await E2eApp.tap(tester, scope, what: 'the selection scope');
      if (E2eApp.hasKey('captions-tier-fast')) await E2eApp.tapKey(tester, 'captions-tier-fast');
      final service = E2eApp.world.captions!.service;
      double fraction = 0;
      var subscribed = false;
      await E2eApp.tapKey(tester, 'captions-create');
      await E2eApp.pumpUntil(
        tester,
        () {
          if (E2eApp.hasKey('captions-failed')) throw TestFailure('Auto captions failed');
          if (E2eApp.hasKey('captions-needs-language') && E2eApp.hasKey('captions-candidate-en')) {
            service.activeJob?.provideLanguage('en');
          }
          final active = service.activeJob;
          if (active != null && !subscribed) {
            subscribed = true;
            active.progress.listen((p) => fraction = p.fraction, onError: (Object _) {});
          }
          if (active == null && subscribed) throw TestFailure('the captions job ended before the kill');
          return fraction >= 0.2;
        },
        what: 'Auto captions to pass 20 %',
        timeout: const Duration(minutes: 5),
        step: const Duration(milliseconds: 100),
      );
      _pending(job, ed, {'fraction': fraction});
      soakLog('death', 'captions killed at ${(fraction * 100).round()} %');
      await E2eHandshake.requestAndDie(tester, 'kill');
  }
  throw StateError('unknown job $job');
}

/// Saves the project (so the pending job is on disk the way an autosave would leave it), checks
/// that the job of [kind] still runs, and asks the host to kill the app.
Future<Never> _dieDuringTask(WidgetTester tester, E2eEditor ed, String job, EditorTaskKind kind, Map<String, Object?> extra) async {
  await E2eApp.pumpUntil(tester, () => ed.state.tasks.any((t) => t.kind == kind), what: 'the ${kind.name} task', timeout: const Duration(seconds: 15))
      .onError<TestFailure>((_, __) {});
  await ed.controller.saveNow();
  final running = ed.state.tasks.any((t) => t.kind == kind && !t.failed);
  final progress = ed.state.tasks.where((t) => t.kind == kind).firstOrNull?.progress;
  _pending(job, ed, {...extra, 'runningAtKill': running, 'progress': progress});
  soakLog('death', '$job killed (task running: $running, progress $progress)');
  await E2eHandshake.requestAndDie(tester, 'kill');
}

// -------------------------------------------------------------------------------------------------
// Verify after the relaunch
// -------------------------------------------------------------------------------------------------

Future<void> _verifyPending(WidgetTester tester) async {
  final pending = E2eHandshake.loadState(_pendingKey);
  if (pending == null || pending['job'] == null) return;
  final job = pending['job']! as String;
  final id = ProjectId(pending['project']! as String);
  final results = <String, Object?>{...?E2eHandshake.loadState(_resultsKey)};
  String detail;
  var ok = false;
  try {
    detail = await _verify(tester, job, id, pending);
    final problems = await soakStoreCheck(tester, id);
    if (problems.isNotEmpty) throw StateError('store check: $problems');
    ok = true;
  } on Object catch (e) {
    detail = '${e.runtimeType}: ${'$e'.split('\n').take(3).join(' ')}';
    soakLog('death-result', '$job FAIL (before cleanup): $detail');
    await E2eApp.screenshot(tester, 'soak_death_${job}_failed').onError((_, __) {});
    // Back to Projects for the next job: close the editor the failed check left open.
    await soakDismissAll(tester, null);
    if (find.byType(EditorScreen).evaluate().isNotEmpty) {
      await E2eApp.tap(tester, find.bySemanticsLabel('Close editor'), what: 'Close editor');
      await E2eApp.pumpUntil(tester, () => find.byType(EditorScreen).evaluate().isEmpty, what: 'the editor to close');
    }
  }
  results[job] = {'ok': ok, 'detail': detail, 'atKill': pending};
  E2eHandshake.saveState(_resultsKey, results);
  E2eHandshake.saveState(_pendingKey, {'job': null});
  soakLog('death-result', '$job ${ok ? 'PASS' : 'FAIL'}: $detail');
}

Future<String> _verify(WidgetTester tester, String job, ProjectId id, Map<String, Object?> pending) async {
  final world = E2eApp.world;
  switch (job) {
    case 'autosave':
      final (ed, restored) = await soakOpenProject(tester, id);
      _expectValid(ed);
      final text = ed.items<TextItem>().where((t) => t.id.value == pending['item']).firstOrNull;
      if (text == null || !text.text.startsWith('SOAK AUTOSAVE')) throw StateError('the edited text is gone: ${text?.text}');
      await ed.close();
      return 'reopened valid${restored ? ' after restoring the journal' : ''}; text "${text.text}"';
    case 'proxy':
      final (ed, restored) = await soakOpenProject(tester, id);
      _expectValid(ed);
      final media = MediaId(pending['media']! as String);
      final state = ed.project.pool[media]!.proxy;
      soakLog('death', 'proxy on reopen: state ${state.name}, tasks ${[for (final t in ed.state.tasks) '${t.kind.name}:${t.progress}:${t.failed}']}');
      var how = 'resumed';
      if (state == ProxyState.none || state == ProxyState.failed) {
        how = 'state ${state.name} on reopen, requested again';
        if (!ed.tasks.requestProxy(media)) throw StateError('the proxy cannot be requested again');
      }
      await _resumes(tester, ed, 'proxy', () {
        if (ed.project.pool[media]!.proxy == ProxyState.failed) throw StateError('the proxy failed after the relaunch');
        return ed.project.pool[media]!.proxy == ProxyState.ready;
      });
      await ed.close();
      return 'proxy ready ($how${restored ? ', journal restored' : ''})';
    case 'reverse' || 'freeze':
      final (ed, restored) = await soakOpenProject(tester, id);
      _expectValid(ed);
      bool isTarget(MediaAsset a) => job == 'reverse' ? a.derived is ReversedSpec : a.derived is StillSpec;
      final targets = ed.project.pool.assets.values.where(isTarget).toList();
      if (targets.isEmpty) {
        await ed.close();
        if (pending['runningAtKill'] == true) throw StateError('the pending $job asset is gone after the relaunch');
        return 'the job finished before the kill; project valid';
      }
      final wasPending = targets.any((a) => a.status is PendingStatus);
      await _resumes(tester, ed, job, () {
        final now = ed.project.pool.assets.values.where(isTarget).toList();
        for (final a in now) {
          if (a.status is FailedStatus) throw StateError('the $job asset failed: ${(a.status as FailedStatus).reason}');
        }
        return now.every((a) => a.status is ReadyStatus);
      });
      await ed.close();
      return '${wasPending ? 'pending on reopen, resumed' : 'already ready on reopen'} -> ready${restored ? ' (journal restored)' : ''}';
    case 'export':
      final before = await E2eApp.pumpWhile(tester, world.engine.exporter.activeJobs(), what: 'activeJobs');
      final records = [for (final j in before) if (j is ExportInterrupted || j is ExportResumable) j];
      if (before.whereType<ExportRunning>().isNotEmpty) throw StateError('an export still runs after the kill: $before');
      if (records.length != 1) throw StateError('expected one interrupted/resumable record, got $before');
      final record = records.single;
      final (ed, _) = await soakOpenProject(tester, id);
      _expectValid(ed);
      final c = E2eExport.controller(ed);
      if (E2eExport.state(ed) is! ExportUiInterrupted) {
        final found = await E2eApp.pumpWhile(tester, c.reattach(), what: 'reattach');
        if (found != ExportReattach.interrupted && found != ExportReattach.resumable) throw StateError('reattach found $found');
      }
      var how = 'reported interrupted';
      final s = E2eExport.state(ed) as ExportUiInterrupted;
      if (s.canResume) {
        final handoffs = world.engine.files.records.length;
        await c.resume();
        await E2eApp.pumpUntil(tester, () {
          final st = E2eExport.state(ed);
          if (st is ExportUiFailed) throw StateError('the resumed export failed: ${st.failure}');
          return st is ExportUiCompleted && world.engine.files.records.length > handoffs;
        }, what: 'the resumed export', timeout: const Duration(minutes: 8));
        how = 'resumed from ${(s.doneFraction * 100).round()} % and completed';
      } else {
        await c.acknowledgeRecord();
      }
      await soakDismissAll(tester, ed);
      final after = await E2eApp.pumpWhile(tester, world.engine.exporter.activeJobs(), what: 'activeJobs');
      if (after.any((j) => j.jobId == record.jobId)) throw StateError('the record is reported again: $after');
      await ed.close();
      final (again, _) = await soakOpenProject(tester, id);
      final second = await E2eApp.pumpWhile(tester, E2eExport.controller(again).reattach(), what: 'reattach on reopen');
      if (second != ExportReattach.none) throw StateError('the reopened editor found $second again');
      await again.close();
      SoakMedia.dropHandoffCopies();
      return '${record.runtimeType} once; $how; nothing on reopen';
    case 'captions':
      final service = world.captions?.service;
      if (service == null) throw StateError('Auto captions are not wired (DANAVIEW_AUTO_CAPTIONS)');
      final record = await E2eApp.pumpWhile(tester, service.resumableFor(id), what: 'resumableFor');
      if (record == null) throw StateError('no resumable captions record after the kill');
      final (ed, _) = await soakOpenProject(tester, id);
      _expectValid(ed);
      await E2eApp.waitKey(tester, 'captions-interrupted', timeout: const Duration(seconds: 30));
      await E2eApp.screenshot(tester, 'soak_death_captions_notice');
      await E2eApp.tapKey(tester, 'captions-interrupted-discard');
      await E2eApp.pumpUntil(tester, () => !E2eApp.hasKey('captions-interrupted'), what: 'the notice to go');
      await ed.close();
      final (again, _) = await soakOpenProject(tester, id);
      // Give the notice the time it needs to look the record up, then require it absent.
      await E2eApp.pumpUntil(tester, () => E2eApp.hasKey('captions-interrupted-none') || E2eApp.hasKey('captions-interrupted'),
              what: 'the notice lookup', timeout: const Duration(seconds: 10))
          .onError<TestFailure>((_, __) {});
      if (E2eApp.hasKey('captions-interrupted')) throw StateError('the interrupted notice shows again after Discard');
      final left = await E2eApp.pumpWhile(tester, service.resumableFor(id), what: 'resumableFor');
      if (left != null) throw StateError('the record survives Discard');
      await again.close();
      return 'record at ${(record.doneFraction * 100).round()} %; notice once; gone after Discard';
  }
  throw StateError('unknown job $job');
}

/// Waits until [ready] holds with no user action (the editor alone must resume the pending job,
/// ARCH §15 "jobs are re-queued"). When it does not within 90 s, it probes whether the job resumes
/// once the Tasks controller exists (what any Tasks-sheet, Clip info or reverse/freeze action
/// creates) and fails with that diagnosis.
Future<void> _resumes(WidgetTester tester, E2eEditor ed, String job, bool Function() ready) async {
  try {
    await E2eApp.pumpUntil(tester, ready, what: 'the pending $job to resume on open', timeout: const Duration(seconds: 90));
    return;
  } on TestFailure {
    soakLog('death', '$job: not resumed 90 s after open (tasks ${ed.state.tasks.length}); probing with the Tasks controller');
  }
  ed.tasks; // creates tasksControllerProvider(id), whose reconcile starts pending jobs
  var resumedAfterProbe = false;
  try {
    await E2eApp.pumpUntil(tester, ready, what: 'the pending $job after the probe', timeout: const Duration(minutes: 3));
    resumedAfterProbe = true;
  } on TestFailure {
    // Not even then.
  }
  throw StateError('the pending $job job is not resumed when the editor opens; '
      '${resumedAfterProbe ? 'it resumes and completes only after tasksControllerProvider is first read (nothing reads it on open)' : 'it does not resume even after tasksControllerProvider is read'}');
}

void _expectValid(E2eEditor ed) {
  final problems = ed.problems();
  if (problems.isNotEmpty) throw StateError('the reopened project is not valid: $problems');
}
