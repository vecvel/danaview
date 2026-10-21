// OWNER: INT-101
//
// Public barrel of danaview_face_tracking (ARCH v1.2 §4.3, §6.4): trackers, model paths and video
// sampling over the Pigeon surface of VED-16 (lib/src/pigeon/ stays private). Rule 21: models load
// only from the paths the caller gives.

library;

export 'src/face_tracker.dart';
export 'src/models.dart';
export 'src/video_sampler.dart';
