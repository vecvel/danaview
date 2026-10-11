// OWNER: CORE-30
//
// Builders shared by the compiler tests: pool assets, clips, lanes, projects and a resolver that
// resolves every pool asset to `file:///media/<id>` (proxies and LUTs on request).

import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

final DateTime when = DateTime.utc(2026, 10, 10);

/// Frame [k] of [rate].
TimeUs fr(int k, [FrameRate rate = FrameRate.fps30]) => rate.timeOfFrame(k);

/// A pool asset.
MediaAsset asset(
  String id,
  MediaKind kind, {
  TimeUs duration = 10000000,
  int? w = 1920,
  int? h = 1080,
  int rotation = 0,
  bool hasAudio = true,
  ColorTransfer transfer = ColorTransfer.sdr,
  AssetStatus status = AssetStatus.ready,
  DerivedSpec? derived,
  ProxyState proxy = ProxyState.none,
  String? quickHash,
}) =>
    MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: id,
      locator: AppRelativeLocator(AppRoot.documents, id),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: quickHash ?? 'qh_$id'),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image || kind == MediaKind.lut ? 0 : duration,
        hasVideo: kind == MediaKind.video,
        hasAudio: (kind == MediaKind.video || kind == MediaKind.audio) && hasAudio,
        width: kind == MediaKind.audio || kind == MediaKind.lut ? null : w,
        height: kind == MediaKind.audio || kind == MediaKind.lut ? null : h,
        rotation: rotation,
        transfer: transfer,
      ),
      origin: MediaOrigin.files,
      derived: derived,
      status: status,
      proxy: proxy,
      addedAt: when,
    );

/// A visual media clip from frame [k0] to [k1] of [rate].
MediaClip clip(
  String id,
  int k0,
  int k1,
  String media, {
  FrameRate rate = FrameRate.fps30,
  TimeUs sourceIn = 0,
  SpeedSpec speed = SpeedSpec.normal,
  bool reversed = false,
  VisualProps visual = VisualProps.neutral,
  KeyframeSet keyframes = KeyframeSet.empty,
}) =>
    MediaClip(
      id: ItemId(id),
      start: fr(k0, rate),
      duration: fr(k1, rate) - fr(k0, rate),
      media: MediaId(media),
      sourceIn: sourceIn,
      speed: speed,
      reversed: reversed,
      visual: visual,
      keyframes: keyframes,
    );

/// The main video lane.
Track mainLane(List<TimelineItem> items, {String id = 'tr_main', bool hidden = false, bool muted = false, bool solo = false}) =>
    Track(id: TrackId(id), kind: TrackKind.video, isMain: true, items: items, hidden: hidden, muted: muted, solo: solo);

/// A lane of [kind].
Track lane(String id, TrackKind kind, List<TimelineItem> items, {bool hidden = false, bool muted = false, bool solo = false, SubtitleTrackData? subtitle}) =>
    Track(id: TrackId(id), kind: kind, items: items, hidden: hidden, muted: muted, solo: solo, subtitle: subtitle);

/// A project.
EditProject project(
  List<Track> tracks, {
  ProjectSettings settings = const ProjectSettings(),
  List<MediaAsset> assets = const [],
  int revision = 7,
}) =>
    EditProject(
      id: const ProjectId('pr_compile0001'),
      meta: ProjectMeta(name: 'compile', createdAt: when, updatedAt: when),
      timeline: Timeline(settings: settings, tracks: tracks, revision: revision),
      pool: MediaPool({for (final a in assets) a.id: a}),
    );

/// A resolver resolving every pool asset of [p] (except [offline]) to `file:///media/<id>.<ext>`,
/// with proxies for [proxied], bundled looks for [looks] and `.vlut` files for LUT assets.
MapPlanAssetResolver resolverFor(
  EditProject p, {
  Set<String> offline = const {},
  Set<String> proxied = const {},
  Set<String> looks = const {'tealOrange', 'warm', 'mono'},
  Map<String, Uint8List> bookmarks = const {},
}) {
  final originals = <MediaId, ResolvedMedia>{};
  final luts = <MediaId, ResolvedLut>{};
  for (final a in p.pool.assets.values) {
    if (offline.contains(a.id)) continue;
    if (a.kind == MediaKind.lut) {
      luts[a.id] = ResolvedLut(uri: 'file:///support/danaview/editor/luts/${a.id}.vlut', size: 33);
      continue;
    }
    final ext = switch (a.kind) {
      MediaKind.image => 'jpg',
      MediaKind.still => 'png',
      MediaKind.audio || MediaKind.recording => 'm4a',
      _ => 'mp4',
    };
    originals[a.id] = ResolvedMedia(uri: 'file:///media/${a.id}.$ext', fingerprint: a.fingerprint.quickHash, bookmark: bookmarks[a.id]);
  }
  return MapPlanAssetResolver(
    originals: originals,
    proxies: {for (final id in proxied) MediaId(id): ResolvedMedia(uri: 'file:///cache/danaview/editor/proxies/$id-540.mp4', fingerprint: 'px_$id', isProxy: true)},
    looks: {for (final l in looks) l: ResolvedLut(uri: 'file:///app/assets/looks/$l.vlut', size: 33)},
    luts: luts,
  );
}

/// The media layers of [plan] as packing inputs, in draw order.
List<PackInput> mediaInputsOf(RenderPlan plan) => [
      for (final l in plan.layers)
        if (l.kind == PlanLayerKind.media) PackInput(l.id, l.z, l.t0, l.t1),
    ]..sort(comparePackInputs);

/// Canonical JSON text of [plan] with a trailing newline (golden files).
String canonical(RenderPlan plan) => '${PlanJson.canonicalString(PlanJson.encodePlan(plan))}\n';

/// Whether goldens are rewritten instead of compared (`DANAVIEW_UPDATE_GOLDENS=1`).
bool get updateGoldens => Platform.environment['DANAVIEW_UPDATE_GOLDENS'] == '1';

/// The plan's value of [channel] on [layer] at plan time [t]: the `anim` channel when present,
/// else the static value (ARCH §11.2 defaults; `xf.cx`/`xf.cy` default to the canvas centre).
double planValue(PlanLayer layer, String channel, TimeUs t, PlanCanvas canvas) {
  final keys = layer.anim[channel];
  if (keys != null) return evaluateAnimKeys(keys, t);
  final xf = layer.xf;
  return switch (channel) {
    PlanChannels.xfCx => xf.cx ?? canvas.w / 2,
    PlanChannels.xfCy => xf.cy ?? canvas.h / 2,
    PlanChannels.xfS => xf.s,
    PlanChannels.xfR => xf.r,
    PlanChannels.xfOp => xf.op,
    _ => throw ArgumentError(channel),
  };
}
