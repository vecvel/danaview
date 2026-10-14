// OWNER: UX-23
//
// Copy of the Transform, Crop and Mask panels, the crop, mask and eyedropper preview modes and the
// transform actions (ux.md §7.5, §10.2, §10.10): plain and specific, with a next step where one
// exists (ARCH §19). History labels name what changed. No ids or paths appear in the text.

/// Copy of the Transform, Crop and Mask panels and their preview modes.
abstract final class TransformStrings {
  // ---- Transform panel -------------------------------------------------------------------------

  /// Row label of the position (shown as "Position X" / "Position Y").
  static const String position = 'Position';

  /// Row label of the flips.
  static const String flip = 'Flip';

  /// Flip button: mirror left to right.
  static const String flipHorizontal = 'Flip horizontally';

  /// Flip button: mirror top to bottom.
  static const String flipVertical = 'Flip vertically';

  /// Row label of the fit mode.
  static const String fit = 'Fit';

  /// Fit segment: letterbox inside the canvas.
  static const String fitFit = 'Fit';

  /// Fit segment: cover the canvas.
  static const String fitFill = 'Fill';

  /// Fit segment: stretch to the canvas.
  static const String fitStretch = 'Stretch';

  /// Button that opens crop mode.
  static const String cropButton = 'Crop';

  /// Button that resets position, scale, rotation, flips and opacity.
  static const String resetTransform = 'Reset transform';

  /// Semantics hint of "Reset transform".
  static const String resetTransformHint = 'Centres the item at its original size and removes its transform keyframes';

  /// Shown when the item's track is locked.
  static const String trackLocked = 'This track is locked';

  // ---- Crop --------------------------------------------------------------------------------------

  /// Heading of the aspect chips.
  static const String aspect = 'Aspect';

  /// Aspect chip: no constraint.
  static const String aspectFree = 'Free';

  /// Aspect chip: the source's own aspect.
  static const String aspectOriginal = 'Original';

  /// Rotate button of the crop panel.
  static const String rotate90 = 'Rotate 90°';

  /// Reset button of the crop panel.
  static const String resetCrop = 'Reset';

  /// Done button of the crop panel.
  static const String done = 'Done';

  /// The size the crop keeps, in source pixels ("1280 × 720 px").
  static String cropSize(int width, int height) => '$width × $height px';

  /// Shown when the source size is unknown (still probing, or missing media).
  static const String cropUnavailable = 'The picture size of this clip is not known yet, so it cannot be cropped.';

  /// Semantics label of the crop frame on the preview.
  static const String cropFrame = 'Crop frame';

  /// Semantics hint of the crop frame.
  static const String cropFrameHint = 'Drag the frame to move it, or its corners and edges to resize it';

  /// Semantics label of a crop handle ("Top left corner").
  static String cropHandle(String name) => name;

  /// Names of the eight crop handles, clockwise from the top-left.
  static const List<String> cropHandleNames = [
    'Top left corner',
    'Top edge',
    'Top right corner',
    'Right edge',
    'Bottom right corner',
    'Bottom edge',
    'Bottom left corner',
    'Left edge',
  ];

  /// Semantics actions of the crop frame.
  static const String cropShrink = 'Shrink crop';

  /// Semantics actions of the crop frame.
  static const String cropGrow = 'Grow crop';

  // ---- Mask --------------------------------------------------------------------------------------

  /// Label of the shape control.
  static const String maskShape = 'Shape';

  /// Shape segment: no mask.
  static const String maskNone = 'None';

  /// Shape segment: rounded rectangle.
  static const String maskRectangle = 'Rectangle';

  /// Shape segment: circle (an ellipse on a non-square picture).
  static const String maskCircle = 'Circle';

  /// Shown with no mask.
  static const String maskNoneHint = 'Pick a shape to show only part of the picture.';

  /// Row label: horizontal mask size.
  static const String maskWidth = 'Width';

  /// Row label: vertical mask size.
  static const String maskHeight = 'Height';

  /// Row label: uniform circle size.
  static const String maskSize = 'Size';

  /// Toggle: keep the circle's proportions.
  static const String maskLockAspect = 'Lock aspect';

  /// Row label of the mask rotation.
  static const String maskRotation = 'Rotation';

  /// Row label of the corner radius.
  static const String maskCornerRadius = 'Corner radius';

  /// Row label of the feather.
  static const String maskFeather = 'Feather';

  /// Row label of the mask opacity.
  static const String maskOpacity = 'Opacity';

  /// Row label of invert.
  static const String maskInvert = 'Invert';

  /// Subtitle of invert.
  static const String maskInvertHint = 'Keep the outside of the shape instead';

  /// Semantics label of the mask on the preview.
  static const String maskFrame = 'Mask';

  /// Semantics hint of the mask on the preview.
  static const String maskFrameHint = 'Drag the shape to move it; use its handles to resize, rotate or feather it';

  /// Shown on the preview when the clip is not at the playhead.
  static const String maskNotAtPlayhead = 'Move the playhead over this clip to see the mask handles';

  // ---- Eyedropper --------------------------------------------------------------------------------

  /// Banner shown while picking.
  static const String eyedropperHint = 'Drag over the picture to pick a colour';

  /// Cancel button of the banner.
  static const String eyedropperCancel = 'Cancel';

  /// Semantics label of the picking area.
  static const String eyedropperArea = 'Colour picker on the preview';

  /// Semantics value of the sampled colour ("#00B140").
  static String eyedropperValue(int rgb) => '#${(rgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  // ---- History labels ----------------------------------------------------------------------------

  /// A crop handle or frame drag.
  static const String historyCrop = 'Crop';

  /// An aspect chip ("Crop to 16:9").
  static String historyCropAspect(String aspect) => 'Crop to $aspect';

  /// The crop reset.
  static const String historyResetCrop = 'Reset crop';

  /// The 90° rotation.
  static const String historyRotate90 = 'Rotate 90°';

  /// A flip ("Flip horizontally").
  static String historyFlip({required bool horizontal}) => horizontal ? flipHorizontal : flipVertical;

  /// The keyframe-all toggle of a panel.
  static const String historyKeyframeAll = 'Keyframe all';

  /// The keyframe-all toggle removing keys.
  static const String historyRemoveKeys = 'Remove keyframes';

  /// The mask shape ("Rectangle mask").
  static String historyMaskShape(String shape) => shape == maskNone ? 'Remove mask' : '$shape mask';

  /// The mask reset.
  static const String historyResetMask = 'Reset mask';

  /// Mask handle drags.
  static const String historyMoveMask = 'Move mask';

  /// Mask handle drags.
  static const String historyResizeMask = 'Resize mask';

  /// Mask handle drags.
  static const String historyRotateMask = 'Rotate mask';

  /// Mask handle drags.
  static const String historyFeatherMask = 'Feather mask';

  /// The circle size row.
  static const String historyMaskSize = 'Change mask size';

  // ---- Actions -----------------------------------------------------------------------------------

  /// Disabled reason: nothing selected that has a transform.
  static const String selectItem = 'Select a clip or text first';

  /// Disabled reason: the selection has no picture to crop or mask.
  static const String selectClip = 'Select a video or photo clip first';

  /// Disabled reason while the project is still opening.
  static const String notOpen = 'The project is still opening';
}
