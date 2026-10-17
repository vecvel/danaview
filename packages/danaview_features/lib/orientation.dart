/// Screen orientation ownership for screens outside `danaview_features` (the editor opens over the
/// player and must hand the orientation back correctly). Entry point:
/// `package:danaview_features/orientation.dart`.
library danaview_features_orientation;

export 'src/player/screen_orientation_policy.dart' show OrientationMode, ScreenOrientationPolicy;
