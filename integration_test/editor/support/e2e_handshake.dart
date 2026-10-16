// OWNER: QA-00
//
// File handshake between the in-app test and the host driver (`integration_test/editor/tool/
// e2e_host.sh`), for the steps an app cannot do to itself: go to the background and come back,
// get killed, have a permission granted, be swiped from recents (ARCH §21.2).
//
// Protocol (all files in `E2eConfig.handshakeDir`, written atomically: `<name>.tmp` then rename):
//
//   app  -> host   req-<seq>-<action>.json   {"seq", "action", "args": {...}, "at"}
//   host -> app    ack-<seq>-<action>.json   {"seq", "ok": true|false, "detail"}
//   host -> app    do-<seq>-<action>.json    {"seq", "do", "attempt"}  a step the host needs the
//                                            app to take while it serves <seq> (finishActivity)
//
// `<seq>` is a per-run counter persisted in `seq` so the phases of one scenario never reuse a
// number. The app waits for the ack by polling the folder while pumping frames: an explicit wait
// on the host's file, never a fixed sleep. Actions the host understands:
//
//   background {seconds}     send the app to the background, wait, bring it back, then ack
//   foreground               bring the app back (after `background` with seconds = 0)
//   kill                     kill the app process (no ack: the test that asked ends there)
//   grantMic                 grant the microphone permission (simctl privacy / pm grant)
//   grantNotifications       Android: grant POST_NOTIFICATIONS (pm grant), so the export's
//                            permission dialog never appears; a no-op on iOS
//   swipeFromRecents         Android: remove the task from recents; the host confirms with
//                            `dumpsys activity recents` (ok=false ack when the task stays)
//   destroyActivity          Android: finish the activity while the process lives on; the host
//                            writes do-<seq> {"do": "finishActivity"}, the app answers with
//                            SystemNavigator.pop() (Activity.finish()), and the host acks once
//                            `dumpsys activity activities` lists no ActivityRecord of the app
//   tapNotificationCancel    Android: the export notification's Cancel (the host sends its
//                            ExportService intent, or taps Cancel in the shade)
//   relaunch                 start the app again (used by the host between phases)
//
// Without a host driver (`DV_E2E_HOST` not set), [E2eHandshake.available] is false and the
// scenarios that need one skip those steps with a printed reason.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2e_config.dart';

/// The host's answer to a request.
final class E2eAck {
  /// Creates an ack.
  const E2eAck({required this.ok, this.detail = ''});

  /// Whether the host did what was asked.
  final bool ok;

  /// The host's note (for the log).
  final String detail;

  @override
  String toString() => 'E2eAck(ok: $ok${detail.isEmpty ? '' : ', $detail'})';
}

/// The app side of the handshake.
abstract final class E2eHandshake {
  /// Whether a host driver serves requests in this run.
  static bool get available => E2eConfig.hostDriver;

  static Directory get _dir => Directory(E2eConfig.handshakeDir);

  static int _nextSeq() {
    final dir = _dir..createSync(recursive: true);
    final f = File('${dir.path}/seq');
    final current = f.existsSync() ? int.tryParse(f.readAsStringSync().trim()) ?? 0 : 0;
    final next = current + 1;
    _writeAtomic(f, '$next');
    return next;
  }

  static void _writeAtomic(File target, String contents) {
    final tmp = File('${target.path}.tmp')..writeAsStringSync(contents, flush: true);
    tmp.renameSync(target.path);
  }

  /// Writes the request for [action] and returns its sequence number (no wait).
  static int post(String action, {Map<String, Object?> args = const {}}) {
    final seq = _nextSeq();
    final req = File('${_dir.path}/req-$seq-$action.json');
    _writeAtomic(req, jsonEncode({'seq': seq, 'action': action, 'args': args, 'at': DateTime.now().toUtc().toIso8601String()}));
    // ignore: avoid_print
    print('DV_E2E_HANDSHAKE request $seq $action ${jsonEncode(args)}');
    return seq;
  }

  /// Asks the host for [action] and waits for its ack (pumping frames while waiting).
  static Future<E2eAck> request(
    WidgetTester tester,
    String action, {
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (!available) throw StateError('No host driver: run through integration_test/editor/tool/e2e_host.sh');
    final seq = post(action, args: args);
    final ack = File('${_dir.path}/ack-$seq-$action.json');
    final deadline = DateTime.now().add(timeout);
    while (!ack.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TestFailure('The host did not acknowledge "$action" (#$seq) within ${timeout.inSeconds} s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    final body = jsonDecode(ack.readAsStringSync()) as Map<String, Object?>;
    final result = E2eAck(ok: body['ok'] == true, detail: '${body['detail'] ?? ''}');
    // ignore: avoid_print
    print('DV_E2E_HANDSHAKE ack $seq $action $result');
    return result;
  }

  /// Asks the host for [action] that ends this process (kill, swipe from recents, destroy the
  /// activity): posts the request and keeps the app alive and pumping until the host acts. Takes
  /// the steps the host asks of the app (`do-<seq>-<action>.json`, e.g. finishActivity). Never
  /// returns normally; the host driver treats the lost connection of this phase as the expected
  /// outcome. An ok=false ack (the host could not do it) fails the test with the host's detail.
  static Future<Never> requestAndDie(WidgetTester tester, String action, {Map<String, Object?> args = const {}}) async {
    if (!available) throw StateError('No host driver: run through integration_test/editor/tool/e2e_host.sh');
    final seq = post(action, args: args);
    final doFile = File('${_dir.path}/do-$seq-$action.json');
    final ack = File('${_dir.path}/ack-$seq-$action.json');
    final handled = <String>{};
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (doFile.existsSync()) {
        final body = _readJson(doFile);
        final attempt = '${body?['attempt'] ?? 0}';
        if (body != null && handled.add(attempt)) await _perform('${body['do']}', seq);
      }
      if (ack.existsSync()) {
        final body = _readJson(ack);
        if (body != null && body['ok'] != true) {
          throw TestFailure('The host could not "$action" the app (#$seq): ${body['detail'] ?? ''}');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    throw TestFailure('The host did not "$action" the app within 3 minutes');
  }

  static Map<String, Object?>? _readJson(File f) {
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    } on Object {
      return null; // being replaced; read again on the next poll
    }
  }

  /// A step the host asked of the app (test-only; this file only runs under DV_E2E_HOST).
  static Future<void> _perform(String step, int seq) async {
    // ignore: avoid_print
    print('DV_E2E_HANDSHAKE do $seq $step');
    switch (step) {
      case 'finishActivity':
        // Android: PlatformPlugin.popSystemNavigator → FlutterActivity.finish() (the activity is
        // destroyed, the process and its foreground service live on).
        await SystemNavigator.pop();
      default:
        // ignore: avoid_print
        print('DV_E2E_HANDSHAKE unknown step "$step" (ignored)');
    }
  }

  /// Persists [value] under [key] for a later phase of the same scenario.
  static void saveState(String key, Map<String, Object?> value) {
    final dir = Directory(E2eConfig.outDir)..createSync(recursive: true);
    _writeAtomic(File('${dir.path}/state-$key.json'), jsonEncode(value));
  }

  /// The state an earlier phase saved under [key], or null.
  static Map<String, Object?>? loadState(String key) {
    final f = File('${E2eConfig.outDir}/state-$key.json');
    if (!f.existsSync()) return null;
    return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  }
}
