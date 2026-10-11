// OWNER: UX-20
//
// Test rig for ThumbnailCache: a scripted ThumbnailSource (every request stays pending until the
// test completes it), a decoder that paints a strip whose frame colours encode the frame number,
// and helpers that paint a hook into an image and read pixels.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color, Rect;
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../timeline/canvas/canvas_fixtures.dart';

/// The colour of source frame [n] of a strip with interval index [salt]: distinct per frame.
Color frameColor(int n) => Color.fromARGB(255, (n * 37) % 256, (n * 91 + 40) % 256, (n * 53 + 80) % 256);

/// A request that waits for the test.
class ScriptedHandle implements ThumbnailHandle {
  ScriptedHandle(this.request, this.priority) {
    _result.future.ignore();
  }

  final ThumbnailRequest request;
  final ThumbPriority priority;
  final Completer<ThumbnailTile> _result = Completer<ThumbnailTile>();
  bool cancelled = false;

  @override
  Future<ThumbnailTile> get result => _result.future;

  bool get isDone => _result.isCompleted;

  /// Completes with a strip whose first byte is the tile index (the test decoder reads it).
  void complete({int? frames}) {
    if (_result.isCompleted) return;
    _result.complete(ThumbnailTile(
      encoded: Uint8List.fromList([request.tileIndex, request.intervalMs ~/ 100 % 256, request.framesPerTile]),
      frames: frames ?? request.framesPerTile,
      frameWidthPx: request.heightPx * 16 ~/ 9,
    ));
  }

  void fail() {
    if (!_result.isCompleted) _result.completeError(const EngineError(EngineErrorCode.decodeFailed));
  }

  @override
  void cancel() {
    if (_result.isCompleted) return;
    cancelled = true;
    _result.completeError(const EngineCancelled());
  }
}

/// Records every request; they stay pending until completed.
class ScriptedThumbnailSource implements ThumbnailSource {
  final List<ScriptedHandle> handles = [];

  List<ThumbnailRequest> get requests => [for (final h in handles) h.request];

  Iterable<ScriptedHandle> get live => handles.where((h) => !h.isDone);

  @override
  ThumbnailHandle request(ThumbnailRequest request, {required ThumbPriority priority}) {
    final h = ScriptedHandle(request, priority);
    handles.add(h);
    return h;
  }

  void completeAll() {
    for (final h in handles.toList()) {
      h.complete();
    }
  }
}

/// Decodes the scripted strip: [framesPerTile] frames of 16 x 9 px, frame `j` of tile `t` in
/// [frameColor]((t * framesPerTile + j)) using the interval byte as the divisor so a test can tell
/// strips of different intervals apart.
Future<ui.Image> decodeScripted(Uint8List bytes) async {
  final tile = bytes[0];
  final interval = bytes[1];
  final frames = bytes[2];
  const w = 16, h = 9;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var j = 0; j < frames; j++) {
    canvas.drawRect(Rect.fromLTWH(j * w.toDouble(), 0, w.toDouble(), h.toDouble()), ui.Paint()..color = frameColor(tile * frames + j + interval * 1000));
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(frames * w, h);
  picture.dispose();
  return image;
}

/// The colour [frameColor] gives frame [n] of a strip with interval [intervalMs].
Color scriptedColor(int n, int intervalMs) => frameColor(n + (intervalMs ~/ 100 % 256) * 1000);

ResolvedMedia mediaOf(String id, {bool proxy = false}) => ResolvedMedia(uri: 'file:///media/$id${proxy ? '-proxy' : ''}.mp4', fingerprint: 'fp-$id', isProxy: proxy);

/// A resolver that knows every id; proxies only for [proxies].
ThumbnailResolverFixture resolverOf({Set<String> proxies = const {}, Set<String> offline = const {}}) => ThumbnailResolverFixture(proxies, offline);

class ThumbnailResolverFixture {
  ThumbnailResolverFixture(this.proxies, this.offline);

  final Set<String> proxies;
  final Set<String> offline;
  final List<(String, bool)> calls = [];

  ResolvedMedia? call(MediaId id, {required bool proxy}) {
    calls.add((id.value, proxy));
    if (offline.contains(id.value)) return null;
    if (proxy) return proxies.contains(id.value) ? mediaOf(id.value, proxy: true) : null;
    return mediaOf(id.value);
  }
}

/// A snapshot with one video lane holding [clips] (and the assets they use).
TimelineSnapshot snapshotOf(List<TimelineItem> clips, {List<MediaAsset>? assets, ProxyState proxy = ProxyState.none, TrackKind kind = TrackKind.video}) {
  final project = projectOf(
    [Track(id: const TrackId('tr_main'), kind: kind, isMain: kind == TrackKind.video, items: clips)],
    assets: assets ?? [asset('m_a'), asset('m_img', kind: MediaKind.image, hasAudio: false), asset('m_snd', kind: MediaKind.audio)],
  );
  return TimelineSnapshotBuilder().build(project);
}

/// The paint context of the first item of [snapshot] with 1 px = [msPerPx] ms.
TimelineClipPaint paintContext(
  TimelineSnapshot snapshot, {
  int itemIndex = 0,
  double pxPerSecond = 60,
  double scrollTimeSec = 0,
  double width = 360,
  double height = 60,
  double dpr = 1,
  double fling = 0,
  bool overscan = false,
}) {
  final lane = snapshot.lanes.first;
  final item = lane.items[itemIndex];
  double xOf(TimeUs t) => (t / microsPerSecond - scrollTimeSec) * pxPerSecond;
  final body = Rect.fromLTRB(xOf(item.start), 0, xOf(item.end), height);
  final visible = overscan ? Rect.zero : Rect.fromLTRB(body.left.clamp(0, width), 0, body.right.clamp(0, width), height);
  return TimelineClipPaint(
    lane: lane,
    item: item,
    body: body,
    visible: visible,
    pxPerSecond: pxPerSecond,
    scrollTimeSec: scrollTimeSec,
    devicePixelRatio: dpr,
    laneHeight: height,
    style: TimelineStyle.standard,
    overscan: overscan,
    flingVelocityX: fling,
  );
}

/// Records [paint] into an image of [width] x [height] and returns its RGBA bytes.
Future<ByteData> render(double width, double height, void Function(ui.Canvas canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height), ui.Paint()..color = const Color(0xFF000000));
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), height.toInt());
  picture.dispose();
  final data = (await image.toByteData())!;
  image.dispose();
  return data;
}

/// The pixel at ([x], [y]) of [data], which is [width] px wide.
Color pixel(ByteData data, int width, int x, int y) {
  final o = (y * width + x) * 4;
  return Color.fromARGB(data.getUint8(o + 3), data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2));
}

/// Lets scheduled microtasks and zero-delay timers run.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
