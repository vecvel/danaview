// OWNER: QA-04
//
// `flutter drive --profile` driver of the QA-04 perf suite: writes the `QA04|…` lines every test
// hands to the binding's reportData to build/qa04/<test>.qa04.txt, and for every timeline the
// tests captured with `traceAction(reportKey: 'timeline_…')` the TimelineSummary
// (<key>.timeline_summary.json: average/p90/p99 build and raster times, missed frames) plus the
// raw timeline for DevTools.
//
// From the repository root (the app is the host; the editor package has no runner of its own):
//
//   flutter drive --profile -d <device> \
//     --driver=packages/danaview_editor/integration_test/perf/perf_driver.dart \
//     --target=packages/danaview_editor/integration_test/perf/timeline_perf_test.dart \
//     --dart-define=QA04_ENFORCE=true --dart-define=QA04_TIER=<minimal|low|mid|high>
//
// flutter_driver comes with integration_test (no new dependency in either pubspec).

// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        if (data == null) return;
        final dir = Directory('build/qa04')..createSync(recursive: true);
        final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '');
        final lines = data['qa04'];
        if (lines is List) {
          File('${dir.path}/$stamp.qa04.txt').writeAsStringSync('${lines.join('\n')}\n');
        }
        for (final entry in data.entries) {
          if (!entry.key.startsWith('timeline_') || entry.value is! Map<String, dynamic>) continue;
          final timeline = Timeline.fromJson(entry.value as Map<String, dynamic>);
          final summary = TimelineSummary.summarize(timeline);
          await summary.writeTimelineToFile(entry.key, destinationDirectory: dir.path, pretty: true, includeSummary: true);
        }
      },
    );
