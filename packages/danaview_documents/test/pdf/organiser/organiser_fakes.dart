// OWNER: HOM-28
//
// Fakes for the page organiser and merge tests: a PdfPageTools engine that records every request
// and answers at once or when the test says (with progress and cancel), and a PdfResultSink that
// records new files and replaces.

import 'dart:async';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';

/// One recorded tool request.
final class ToolCall {
  /// A call of [tool].
  ToolCall(this.tool, {this.inputs = const [], this.plan = const [], this.ranges = const [], this.outPaths = const []});

  /// merge, split, organise, …
  final String tool;

  /// The inputs (one for single-input tools).
  final List<PdfToolInput> inputs;

  /// The organise plan.
  final List<PdfPagePlan> plan;

  /// The split ranges.
  final List<PdfPageRange> ranges;

  /// The outputs.
  final List<String> outPaths;
}

/// A fake engine.
final class FakePdfPageTools implements PdfPageTools {
  /// Tools that answer at once unless [hold] is set.
  FakePdfPageTools({this.tools = const {PdfTool.merge, PdfTool.split, PdfTool.reorder, PdfTool.rotate, PdfTool.deletePages}});

  /// What [supported] answers.
  final Set<PdfTool> tools;

  /// Requests in order.
  final List<ToolCall> calls = [];

  /// When true, jobs wait for [finish] (or a cancel).
  bool hold = false;

  /// Thrown by the next job when set.
  PdfException? failWith;

  final List<(PdfToolJobHandle, Completer<PdfToolResult>, List<String>)> _held = [];

  /// The held jobs.
  List<PdfToolJobHandle> get held => [for (final h in _held) h.$1];

  /// Completes the held jobs.
  void finish() {
    for (final (_, c, outs) in _held) {
      if (!c.isCompleted) c.complete(_result(outs));
    }
    _held.clear();
  }

  static PdfToolResult _result(List<String> outs) =>
      PdfToolResult(outPaths: outs, pageCounts: [for (final _ in outs) 3], sizesBytes: [for (final _ in outs) 1234]);

  PdfToolJob _job(ToolCall call) {
    calls.add(call);
    final id = 'job${calls.length}';
    final fail = failWith;
    failWith = null;
    if (fail != null) return PdfToolJobHandle.failed(id, fail);
    final c = Completer<PdfToolResult>();
    late PdfToolJobHandle handle;
    handle = PdfToolJobHandle(
      id: id,
      run: c.future,
      onCancel: () async {
        if (!c.isCompleted) c.completeError(const PdfException(PdfErrorCode.cancelled, 'cancelled'));
      },
    );
    if (hold) {
      _held.add((handle, c, call.outPaths));
    } else {
      c.complete(_result(call.outPaths));
    }
    return handle;
  }

  @override
  Future<Set<PdfTool>> supported() async => tools;

  @override
  PdfToolJob merge(List<PdfToolInput> inputs, {required String outPath}) => _job(ToolCall('merge', inputs: inputs, outPaths: [outPath]));

  @override
  PdfToolJob split(PdfToolInput input, List<PdfPageRange> ranges, {required List<String> outPaths}) =>
      _job(ToolCall('split', inputs: [input], ranges: ranges, outPaths: outPaths));

  @override
  PdfToolJob reorder(PdfToolInput input, List<int> order, {required String outPath}) =>
      _job(ToolCall('reorder', inputs: [input], plan: reorderPlan(order), outPaths: [outPath]));

  @override
  PdfToolJob rotate(PdfToolInput input, List<int> pages, {int degrees = 90, required String outPath}) =>
      _job(ToolCall('rotate', inputs: [input], outPaths: [outPath]));

  @override
  PdfToolJob deletePages(PdfToolInput input, List<int> pages, {required String outPath}) =>
      _job(ToolCall('deletePages', inputs: [input], outPaths: [outPath]));

  @override
  PdfToolJob organise(PdfToolInput input, List<PdfPagePlan> plan, {required String outPath}) =>
      _job(ToolCall('organise', inputs: [input], plan: plan, outPaths: [outPath]));
}

/// A recording sink.
final class FakePdfResultSink implements PdfResultSink {
  /// (paths, names, beside) per saveNew.
  final List<(List<String>, List<String>, EntryId?)> saved = [];

  /// (entry, path, pageCount) per replace.
  final List<(EntryId, String, int?)> replaced = [];

  @override
  Future<String> stagingDirectory() async => '/staging';

  @override
  Future<List<PdfSavedFile>> saveNew(List<String> paths, List<String> names, {EntryId? besideEntry}) async {
    saved.add((paths, names, besideEntry));
    return [for (final n in names) PdfSavedFile(displayName: n, entryId: EntryId.parse('fe_new${saved.length}'))];
  }

  @override
  Future<PdfSavedFile> replace(EntryId entry, String path, {int? pageCount}) async {
    replaced.add((entry, path, pageCount));
    return PdfSavedFile(displayName: 'Report.pdf', entryId: entry, replaced: true);
  }
}
