// OWNER: UX-30
//
// Copy of the text tool, the text panel and the font picker (ux.md §10.8): plain, specific and
// with a next step where one exists (ARCH §19). Every choice has a text label; glyphs never carry
// meaning alone.

import 'package:danaview_editor_core/model.dart' show TextAlignH, TextAnimKind, TextSlideDirection;
import 'package:danaview_editor_fonts/danaview_editor_fonts.dart' show ContentFontCategory;

import '../../editor/contracts/inspector_routes.dart' show TextPanelTab;

/// Copy of the text panel (ux.md §10.8).
abstract final class TextStrings {
  // ---- Add text -------------------------------------------------------------------------------

  /// The text a new item starts with.
  static const String newText = 'Your text';

  /// Why "Add text" is disabled.
  static const String notEditable = "This project can't be edited right now.";

  /// Announced after a text item was added.
  static const String added = 'Text added';

  // ---- Tabs -----------------------------------------------------------------------------------

  /// The label of [tab].
  static String tab(TextPanelTab tab) => switch (tab) {
        TextPanelTab.edit => 'Edit',
        TextPanelTab.font => 'Font',
        TextPanelTab.style => 'Style',
        TextPanelTab.background => 'Background',
        TextPanelTab.stroke => 'Stroke',
        TextPanelTab.shadow => 'Shadow',
        TextPanelTab.animation => 'Animation',
      };

  /// Semantics label of the tab row.
  static const String tabs = 'Text settings';

  // ---- Notices --------------------------------------------------------------------------------

  /// The item is gone (deleted or undone).
  static const String missing = 'This text is no longer in the project.';

  /// The lane is locked.
  static const String locked = 'This text is on a locked track. Unlock the track to edit it.';

  // ---- Edit -----------------------------------------------------------------------------------

  /// Label of the text field.
  static const String textField = 'Text';

  /// Hint of the text field.
  static const String textHint = 'Type your text';

  /// Shown under the field while it is blank (the item keeps its last text).
  static const String emptyText = "Text can't be empty. The last text is kept.";

  /// Label of the duration field.
  static const String duration = 'Duration';

  /// Unit of seconds.
  static const String secondsUnit = 's';

  /// Semantics prefix of the live text chip shown while the preview is hidden.
  static const String livePreview = 'Text preview';

  // ---- Font -----------------------------------------------------------------------------------

  /// Hint of the font search field.
  static const String searchFonts = 'Search fonts';

  /// No font matches the search.
  static String noFonts(String query) => 'No font matches "$query".';

  /// Label of the size slider.
  static const String size = 'Size';

  /// Unit of the size.
  static const String pointsUnit = 'pt';

  /// Bold toggle.
  static const String bold = 'Bold';

  /// Italic toggle.
  static const String italic = 'Italic';

  /// Semantics of a font row ("Inter, sans serif, selected").
  static String fontRow(String family, ContentFontCategory category, {required bool selected}) =>
      '$family, ${categoryName(category)}${selected ? ', selected' : ''}';

  /// The name of a font category.
  static String categoryName(ContentFontCategory category) => switch (category) {
        ContentFontCategory.sans => 'sans serif',
        ContentFontCategory.serif => 'serif',
        ContentFontCategory.display => 'display',
        ContentFontCategory.handwriting => 'handwriting',
        ContentFontCategory.mono => 'monospaced',
      };

  // ---- Style ----------------------------------------------------------------------------------

  /// Text colour.
  static const String color = 'Color';

  /// Layer opacity.
  static const String opacity = 'Opacity';

  /// Alignment.
  static const String alignment = 'Alignment';

  /// The label of [align].
  static String align(TextAlignH align) => switch (align) {
        TextAlignH.left => 'Left',
        TextAlignH.center => 'Center',
        TextAlignH.right => 'Right',
      };

  /// Letter spacing.
  static const String letterSpacing = 'Letter spacing';

  /// Line spacing.
  static const String lineSpacing = 'Line spacing';

  // ---- Background / stroke / shadow -----------------------------------------------------------

  /// Background switch.
  static const String background = 'Background';

  /// Stroke switch.
  static const String stroke = 'Outline';

  /// Shadow switch.
  static const String shadow = 'Shadow';

  /// Padding.
  static const String padding = 'Padding';

  /// Corner radius.
  static const String cornerRadius = 'Corner radius';

  /// Width.
  static const String width = 'Width';

  /// Blur.
  static const String blur = 'Blur';

  /// Distance.
  static const String distance = 'Distance';

  /// Angle.
  static const String angle = 'Angle';

  /// Degrees unit.
  static const String degreesUnit = '°';

  /// Percent unit.
  static const String percentUnit = '%';

  /// Shown while a switch is off.
  static const String offHint = 'Turn it on to change these settings.';

  // ---- Animation ------------------------------------------------------------------------------

  /// In heading.
  static const String animIn = 'In';

  /// Out heading.
  static const String animOut = 'Out';

  /// The label of [kind].
  static String animKind(TextAnimKind kind) => switch (kind) {
        TextAnimKind.none => 'None',
        TextAnimKind.fade => 'Fade',
        TextAnimKind.slide => 'Slide',
        TextAnimKind.scale => 'Scale',
        TextAnimKind.typewriter => 'Typewriter',
      };

  /// Direction label.
  static const String direction = 'Direction';

  /// The label of [d].
  static String slideDirection(TextSlideDirection d) => switch (d) {
        TextSlideDirection.left => 'Left',
        TextSlideDirection.up => 'Up',
        TextSlideDirection.right => 'Right',
        TextSlideDirection.down => 'Down',
      };

  /// Animation duration.
  static const String animDuration = 'Duration';

  /// Shown when in + out were shortened to fit the item.
  static const String animShortened = 'In and out together can’t be longer than the text, so they were shortened.';

  /// Loop preview button (stopped).
  static const String playPreview = 'Preview';

  /// Loop preview button (running).
  static const String stopPreview = 'Stop preview';

  // ---- History labels (InspectorEditSession gestures) -------------------------------------------

  /// A style slider gesture.
  static const String historyStyle = 'Change text style';

  /// An animation duration gesture.
  static const String historyAnimation = 'Change text animation';
}
