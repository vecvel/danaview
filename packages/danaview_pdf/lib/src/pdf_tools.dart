// OWNER: HOM-28
//
// PDF page tools (HOM plan §8.5, D-98j; ARCH v1.2 rule 27) over the Pigeon surface: merge (PDFs and
// images as pages), split (ranges, every N pages), reorder, rotate, delete, and the one-pass
// organise of the HOM-28 amendment (any mix of reorder, rotate, delete and "extract selected
// pages"). Each call starts a [PdfToolJob] with its own id: progress from the shared event stream,
// cancel, and the result. Inputs are opened read-only; outputs are new files that must not exist
// yet, and a cancelled or failed job leaves none (the native side deletes them). PDFKit on iOS and
// macOS (HOM-28), PdfBox-Android (HOM-28A). Requests are validated here first, so every platform
// answers malformed input the same way. Nothing here logs a name or a path (rule 30).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'pdf_document.dart';
import 'pigeon/pdf_api.g.dart';
import 'pigeon/pdf_channels.dart';

/// One input of a tool, opened read-only.
@immutable
final class PdfToolInput {
  /// A PDF at [path], unlocked with [password] when it is encrypted.
  const PdfToolInput.pdf(this.path, {this.password}) : isImage = false;

  /// An image (JPEG, PNG, HEIC, …) at [path] that becomes one page (merge only).
  const PdfToolInput.image(this.path)
      : isImage = true,
        password = null;

  /// Absolute local path.
  final String path;

  /// The password of an encrypted PDF.
  final String? password;

  /// The input is an image.
  final bool isImage;

  @override
  bool operator ==(Object other) => other is PdfToolInput && other.path == path && other.password == password && other.isImage == isImage;

  @override
  int get hashCode => Object.hash(path, password, isImage);

  // Never prints the path or the password (rule 30).
  @override
  String toString() => 'PdfToolInput(${isImage ? 'image' : 'pdf'})';
}

/// Pages `[start, end)` (0-based).
@immutable
final class PdfPageRange {
  /// Pages [start] up to, not including, [end].
  const PdfPageRange(this.start, this.end);

  /// First page.
  final int start;

  /// One past the last page.
  final int end;

  /// Number of pages.
  int get length => end - start;

  /// "1–3" or "4" (1-based, for names and labels).
  String get label => length == 1 ? '${start + 1}' : '${start + 1}–$end';

  @override
  bool operator ==(Object other) => other is PdfPageRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'PdfPageRange($start, $end)';
}

/// One page of an organised document: input page [sourcePage] turned by [rotation] more degrees.
@immutable
final class PdfPagePlan {
  /// Page [sourcePage] (0-based) turned by [rotation] degrees clockwise (a multiple of 90).
  const PdfPagePlan(this.sourcePage, {this.rotation = 0});

  /// The input page.
  final int sourcePage;

  /// Extra rotation in degrees clockwise, normalised to 0, 90, 180 or 270.
  final int rotation;

  /// This page turned a further [degrees].
  PdfPagePlan rotated(int degrees) => PdfPagePlan(sourcePage, rotation: normalizeRotation(rotation + degrees));

  @override
  bool operator ==(Object other) => other is PdfPagePlan && other.sourcePage == sourcePage && other.rotation == rotation;

  @override
  int get hashCode => Object.hash(sourcePage, rotation);

  @override
  String toString() => 'PdfPagePlan($sourcePage, $rotation°)';
}

/// [degrees] as 0, 90, 180 or 270.
int normalizeRotation(int degrees) => ((degrees % 360) + 360) % 360;

/// What a tool wrote.
@immutable
final class PdfToolResult {
  /// Files written, with their page counts and sizes, in request order.
  const PdfToolResult({required this.outPaths, required this.pageCounts, required this.sizesBytes});

  /// The new files.
  final List<String> outPaths;

  /// Pages of each file.
  final List<int> pageCounts;

  /// Size of each file in bytes.
  final List<int> sizesBytes;

  // Never prints the paths (rule 30).
  @override
  String toString() => 'PdfToolResult(${outPaths.length} files, $pageCounts pages)';
}

/// Progress of a running tool.
@immutable
final class PdfToolProgress {
  /// [pagesDone] of [pagesTotal], [fraction] 0…1.
  const PdfToolProgress({required this.fraction, required this.pagesDone, required this.pagesTotal});

  /// 0…1.
  final double fraction;

  /// Steps done.
  final int pagesDone;

  /// Steps in all.
  final int pagesTotal;

  @override
  String toString() => 'PdfToolProgress($pagesDone/$pagesTotal)';
}

/// One running tool: its progress, its result and a cancel.
abstract interface class PdfToolJob {
  /// The job id (unique per [PdfPageTools] instance).
  String get id;

  /// Progress until the job ends (a broadcast stream; it closes with the job).
  Stream<PdfToolProgress> get progress;

  /// The written files; fails with a [PdfException] (`cancelled` after [cancel]).
  Future<PdfToolResult> get result;

  /// Asks the job to stop; it then fails with `cancelled` and leaves no file. No-op once done.
  Future<void> cancel();
}

/// The page tools. Implementations: [PlatformPdfPageTools]; tests fake it.
abstract interface class PdfPageTools {
  /// The tools this device offers (an empty set where there is no plugin).
  Future<Set<PdfTool>> supported();

  /// Merges [inputs] (2 or more PDFs and images, in order) into the new file [outPath].
  PdfToolJob merge(List<PdfToolInput> inputs, {required String outPath});

  /// Writes `ranges[i]` of [input] to `outPaths[i]`.
  PdfToolJob split(PdfToolInput input, List<PdfPageRange> ranges, {required List<String> outPaths});

  /// Writes [input] with its pages in [order] (`order[i]` is the page shown at position i).
  PdfToolJob reorder(PdfToolInput input, List<int> order, {required String outPath});

  /// Writes [input] with [pages] turned by [degrees] (a multiple of 90) clockwise.
  PdfToolJob rotate(PdfToolInput input, List<int> pages, {int degrees = 90, required String outPath});

  /// Writes [input] without [pages] (at least one page must remain).
  PdfToolJob deletePages(PdfToolInput input, List<int> pages, {required String outPath});

  /// Writes [input]'s pages in [plan] order, each turned by its rotation; pages not in the plan
  /// are left out (reorder, rotate, delete and extract in one pass).
  PdfToolJob organise(PdfToolInput input, List<PdfPagePlan> plan, {required String outPath});
}

/// Whether [tools] includes the one-pass organise (reorder, rotate and delete all landed).
bool canOrganise(Set<PdfTool> tools) => tools.containsAll(const {PdfTool.reorder, PdfTool.rotate, PdfTool.deletePages});

// -----------------------------------------------------------------------------------------------
// Validation and plans (shared by every platform and the fakes).

PdfException _invalid(String message) => PdfException(PdfErrorCode.invalidArgument, message);

/// Checks a merge request: 2+ inputs and an output path.
void validateMerge(List<PdfToolInput> inputs, String outPath) {
  if (inputs.length < 2) throw _invalid('merge needs at least two inputs');
  if (outPath.isEmpty) throw _invalid('empty output path');
  if (inputs.any((i) => i.path == outPath)) throw _invalid('output is an input');
}

/// Checks a split request against [pageCount] when known (-1: the native side checks it).
void validateSplit(PdfToolInput input, List<PdfPageRange> ranges, List<String> outPaths, {int pageCount = -1}) {
  if (input.isImage) throw _invalid('split needs a PDF');
  if (ranges.isEmpty || ranges.length != outPaths.length) throw _invalid('one output per range');
  if (outPaths.toSet().length != outPaths.length || outPaths.any((p) => p.isEmpty || p == input.path)) throw _invalid('bad outputs');
  for (final r in ranges) {
    if (r.start < 0 || r.end <= r.start || (pageCount >= 0 && r.end > pageCount)) throw _invalid('range out of bounds');
  }
}

/// Checks an organise [plan]: at least one page, none twice, quarter turns, in [pageCount] when
/// known (-1: the native side checks the bounds).
void validatePlan(List<PdfPagePlan> plan, {int pageCount = -1}) {
  if (plan.isEmpty) throw _invalid('at least one page must remain');
  final seen = <int>{};
  for (final p in plan) {
    if (p.sourcePage < 0 || (pageCount >= 0 && p.sourcePage >= pageCount)) throw _invalid('page out of bounds');
    if (!seen.add(p.sourcePage)) throw _invalid('page listed twice');
    if (p.rotation % 90 != 0) throw _invalid('rotation must be a multiple of 90');
  }
}

/// The identity plan of [pageCount] pages.
List<PdfPagePlan> identityPlan(int pageCount) => [for (var i = 0; i < pageCount; i++) PdfPagePlan(i)];

/// True when [plan] keeps every one of [pageCount] pages in order, unturned (nothing to save).
bool isIdentityPlan(List<PdfPagePlan> plan, int pageCount) {
  if (plan.length != pageCount) return false;
  for (var i = 0; i < plan.length; i++) {
    if (plan[i].sourcePage != i || plan[i].rotation != 0) return false;
  }
  return true;
}

/// `[0, n)`, `[n, 2n)`, … covering [pageCount] pages (the last range may be shorter).
List<PdfPageRange> rangesEvery(int n, int pageCount) {
  if (n <= 0 || pageCount <= 0) return const [];
  return [for (var s = 0; s < pageCount; s += n) PdfPageRange(s, s + n > pageCount ? pageCount : s + n)];
}

/// Parses "1-3, 5, 7–9" (1-based, inclusive; en dash, hyphen or "to") into 0-based ranges in the
/// order written; null when [text] is empty, malformed or outside 1…[pageCount].
List<PdfPageRange>? parsePageRanges(String text, int pageCount) {
  final parts = text.split(RegExp(r'[,;]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final out = <PdfPageRange>[];
  final single = RegExp(r'^(\d+)$');
  final span = RegExp(r'^(\d+)\s*(?:-|–|—|to)\s*(\d+)$', caseSensitive: false);
  for (final part in parts) {
    int first;
    int last;
    if (single.firstMatch(part) case final m?) {
      first = last = int.parse(m[1]!);
    } else if (span.firstMatch(part) case final m?) {
      first = int.parse(m[1]!);
      last = int.parse(m[2]!);
    } else {
      return null;
    }
    if (first < 1 || last < first || last > pageCount) return null;
    out.add(PdfPageRange(first - 1, last));
  }
  return out;
}

/// The page list of [ranges] as typed back ("1–3, 5").
String formatPageRanges(List<PdfPageRange> ranges) => ranges.map((r) => r.label).join(', ');

/// The organise plan of a reorder ([order] a permutation of 0…n-1).
List<PdfPagePlan> reorderPlan(List<int> order) {
  final sorted = [...order]..sort();
  for (var i = 0; i < sorted.length; i++) {
    if (sorted[i] != i) throw _invalid('order is not a permutation of the pages');
  }
  return [for (final p in order) PdfPagePlan(p)];
}

/// The organise plan of rotating [pages] of [pageCount] by [degrees].
List<PdfPagePlan> rotatePlan(List<int> pages, int degrees, int pageCount) {
  if (degrees % 90 != 0) throw _invalid('rotation must be a multiple of 90');
  final set = pages.toSet();
  if (set.isEmpty || set.any((p) => p < 0 || p >= pageCount)) throw _invalid('page out of bounds');
  return [for (var i = 0; i < pageCount; i++) PdfPagePlan(i, rotation: set.contains(i) ? normalizeRotation(degrees) : 0)];
}

/// The organise plan of deleting [pages] of [pageCount].
List<PdfPagePlan> deletePlan(List<int> pages, int pageCount) {
  final set = pages.toSet();
  if (set.isEmpty || set.any((p) => p < 0 || p >= pageCount)) throw _invalid('page out of bounds');
  if (set.length >= pageCount) throw _invalid('at least one page must remain');
  return [
    for (var i = 0; i < pageCount; i++)
      if (!set.contains(i)) PdfPagePlan(i),
  ];
}

// -----------------------------------------------------------------------------------------------
// Jobs.

/// A [PdfToolJob] driven by a future and a cancel callback (the platform and the fakes).
final class PdfToolJobHandle implements PdfToolJob {
  /// A job [id] whose [run] completes with the result; [onCancel] asks the engine to stop.
  PdfToolJobHandle({required this.id, required Future<PdfToolResult> run, required Future<void> Function() onCancel, Stream<PdfToolProgress>? progress})
      : _onCancel = onCancel {
    final sub = progress?.listen(_progress.add);
    result = run.whenComplete(() async {
      _done = true;
      await sub?.cancel();
      await _progress.close();
    });
    // The result is observed by whoever awaits it; this keeps an unobserved failure from being
    // reported as unhandled.
    unawaited(result.then<void>((_) {}, onError: (Object _) {}));
  }

  /// A job that fails at once with [error] (a request rejected before it started).
  factory PdfToolJobHandle.failed(String id, PdfException error) =>
      PdfToolJobHandle(id: id, run: Future<PdfToolResult>.error(error), onCancel: () async {});

  @override
  final String id;

  final Future<void> Function() _onCancel;
  final StreamController<PdfToolProgress> _progress = StreamController<PdfToolProgress>.broadcast();
  bool _done = false;

  @override
  late final Future<PdfToolResult> result;

  @override
  Stream<PdfToolProgress> get progress => _progress.stream;

  /// Reports [p] (fakes drive progress with it).
  void report(PdfToolProgress p) {
    if (!_progress.isClosed) _progress.add(p);
  }

  @override
  Future<void> cancel() async {
    if (_done) return;
    try {
      await _onCancel();
    } on Object {
      // A job that just finished has nothing to cancel.
    }
  }
}

/// [PdfPageTools] over the plugin.
final class PlatformPdfPageTools implements PdfPageTools {
  /// Tools over the default engine, or the given APIs and event source (tests).
  PlatformPdfPageTools({PdfToolsHostApi? toolsApi, PdfOrganiseHostApi? organiseApi, PdfDocuments? documents, PdfEventHub? events})
      : _tools = toolsApi ?? PdfToolsHostApi(),
        _organise = organiseApi ?? PdfOrganiseHostApi(),
        _documents = documents ?? PlatformPdfDocuments(),
        _events = events ?? PdfEventHub.forInstance();

  final PdfToolsHostApi _tools;
  final PdfOrganiseHostApi _organise;
  final PdfDocuments _documents;
  final PdfEventHub _events;
  int _next = 0;

  String _newId() => 'pt${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${++_next}';

  static PdfToolInputMsg _input(PdfToolInput i) => PdfToolInputMsg(path: i.path, password: i.password, isImage: i.isImage);

  static PdfToolResult _result(PdfToolResultMsg r) => PdfToolResult(outPaths: r.outPaths, pageCounts: r.pageCounts, sizesBytes: r.sizesBytes);

  PdfToolJob _start(String id, Future<PdfToolResultMsg> Function() call) {
    final progress = _events.events
        .where((e) => e.kind == PdfEventKindMsg.toolProgress && e.toolProgress?.jobId == id)
        .map((e) => PdfToolProgress(fraction: e.toolProgress!.fraction, pagesDone: e.toolProgress!.pagesDone, pagesTotal: e.toolProgress!.pagesTotal));
    return PdfToolJobHandle(
      id: id,
      run: guardPdf(call).then(_result),
      onCancel: () => guardPdf(() => _tools.cancel(id)),
      progress: progress,
    );
  }

  PdfToolJob _guarded(void Function() validate, PdfToolJob Function(String id) start) {
    final id = _newId();
    try {
      validate();
    } on PdfException catch (e) {
      return PdfToolJobHandle.failed(id, e);
    }
    return start(id);
  }

  @override
  Future<Set<PdfTool>> supported() async => (await _documents.capabilities()).tools;

  @override
  PdfToolJob merge(List<PdfToolInput> inputs, {required String outPath}) => _guarded(
        () => validateMerge(inputs, outPath),
        (id) => _start(id, () => _tools.merge(PdfMergeRequestMsg(jobId: id, inputs: [for (final i in inputs) _input(i)], outPath: outPath))),
      );

  @override
  PdfToolJob split(PdfToolInput input, List<PdfPageRange> ranges, {required List<String> outPaths}) => _guarded(
        () => validateSplit(input, ranges, outPaths),
        (id) => _start(
          id,
          () => _tools.split(PdfSplitRequestMsg(
            jobId: id,
            input: _input(input),
            ranges: [for (final r in ranges) PdfPageRangeMsg(start: r.start, end: r.end)],
            outPaths: outPaths,
          )),
        ),
      );

  @override
  PdfToolJob reorder(PdfToolInput input, List<int> order, {required String outPath}) => _guarded(
        () => reorderPlan(order),
        (id) => _start(id, () => _tools.reorder(PdfReorderRequestMsg(jobId: id, input: _input(input), order: order, outPath: outPath))),
      );

  @override
  PdfToolJob rotate(PdfToolInput input, List<int> pages, {int degrees = 90, required String outPath}) => _guarded(
        () {
          if (degrees % 90 != 0) throw _invalid('rotation must be a multiple of 90');
          if (pages.isEmpty) throw _invalid('no pages');
        },
        (id) => _start(
          id,
          () => _tools.rotate(PdfRotateRequestMsg(jobId: id, input: _input(input), pages: pages, degrees: degrees, outPath: outPath)),
        ),
      );

  @override
  PdfToolJob deletePages(PdfToolInput input, List<int> pages, {required String outPath}) => _guarded(
        () {
          if (pages.isEmpty) throw _invalid('no pages');
        },
        (id) => _start(id, () => _tools.deletePages(PdfDeletePagesRequestMsg(jobId: id, input: _input(input), pages: pages, outPath: outPath))),
      );

  @override
  PdfToolJob organise(PdfToolInput input, List<PdfPagePlan> plan, {required String outPath}) => _guarded(
        () {
          if (input.isImage) throw _invalid('organise needs a PDF');
          validatePlan(plan);
        },
        (id) => _start(
          id,
          () => _organise.organise(PdfOrganiseRequestMsg(
            jobId: id,
            input: _input(input),
            pages: [for (final p in plan) PdfPagePlanMsg(sourcePage: p.sourcePage, rotation: p.rotation)],
            outPath: outPath,
          )),
        ),
      );
}
