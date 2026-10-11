// OWNER: AI-06
//
// Compiles ios/Classes/DeviceProfiler.swift for macOS with a tiny harness and runs it: the
// Foundation, Metal and Network logic (profile keys, thermal names, excludeFromBackup read-back
// through URLResourceValues, free-disk walk-up) is verified without a device. macOS hosts only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final canRun = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;

  test('DeviceProfiler.swift passes the macOS host harness', () async {
    final tmp = Directory.systemTemp.createTempSync('danaview_whisper_swift_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final out = '${tmp.path}/profiler_host';
    final build = await Process.run('swiftc', [
      '-O',
      'ios/Classes/DeviceProfiler.swift',
      'test/device/swift_host/main.swift',
      '-o',
      out,
    ]);
    expect(build.exitCode, 0, reason: '${build.stderr}');
    final run = await Process.run(out, const []);
    final lines = '${run.stdout}';
    expect(lines, isNot(contains('FAIL')), reason: lines);
    expect(lines, contains('PASS read-back says excluded'));
    expect(run.exitCode, 0, reason: '${run.stderr}');
  }, skip: canRun ? false : 'needs macOS with swiftc', timeout: const Timeout(Duration(minutes: 3)));
}
