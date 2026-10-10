// OWNER: CORE-12
//
// Fixtures of the speed, reverse and freeze-frame tests: a project with a pending still asset
// (as the session creates it before FreezeFrame) and builders on the shared 30 fps support.

import 'package:vwish_editor_core/model.dart';

import '../framework/ops_support.dart';

/// The still the session made for a freeze of `md_video` at source time [sourceTime].
MediaAsset stillAsset(String id, {String media = 'md_video', TimeUs sourceTime = 1000000, AssetStatus? status}) =>
    asset(
      id,
      MediaKind.still,
      derived: StillSpec(MediaId(media), sourceTime, sourceQuickHash: 'q-$media'),
      status: status ?? const PendingStatus('job_1'),
    );

/// The standard project with the pending still `md_still` in its pool.
EditProject withStill(
    {bool rippleEnabled = true,
    List<TimelineItem>? extraOriginal,
    TimeUs sourceTime = 1000000,
    String media = 'md_video'}) {
  final p = standard(rippleEnabled: rippleEnabled, extraOriginal: extraOriginal);
  return p.copyWith(pool: p.pool.upsert(stillAsset('md_still', media: media, sourceTime: sourceTime)));
}

/// One clip of [n] frames at frame 0 on the main lane of a project that has [after] after it.
EditProject single(int n,
        {SpeedSpec speed = SpeedSpec.normal,
        String media = 'md_video',
        TimeUs sourceIn = 0,
        bool rippleEnabled = true,
        List<TimelineItem> after = const []}) =>
    project([
      lane('tr_main', TrackKind.video, [vclip('it_v', 0, n, media: media, sourceIn: sourceIn, speed: speed), ...after],
          main: true),
    ], view: ViewState(rippleEnabled: rippleEnabled));
