// OWNER: HOM-28
// EXTENDED: HOM-29 (the environment carries the annotate engine; the viewer offers "Annotate" when
// it is set and the platform reports the tool.)
//
// How screens reach the PDF page tools (HOM plan §8.5): the app root builds one
// [PdfToolsEnvironment] (documents for thumbnails and passwords, the page tools, the library result
// sink, the merge picker) and provides it above the PDF viewer with [PdfToolsScope]; the viewer's
// top bar, the document row menu and the multi-select bar open the organiser or the merge screen
// through [openPdfOrganiser] and [openPdfMerge] as full-screen routes. Behind DANAVIEW_FILES_HOME
// at the app root; without a scope the viewer shows no tool buttons.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';

import '../../router/viewer_file.dart';
import 'pdf_merge_screen.dart';
import 'pdf_page_organiser.dart';
import 'pdf_tool_save.dart';

/// One input of a merge.
@immutable
final class PdfMergeItem {
  /// A PDF or (with [isImage]) an image at [path], shown as [displayName].
  const PdfMergeItem({required this.path, required this.displayName, this.isImage = false, this.entryId, this.password});

  /// The PDF input of [file].
  factory PdfMergeItem.ofFile(ViewerFile file, {String? password}) =>
      PdfMergeItem(path: file.path, displayName: file.displayName, isImage: file.kind == FileKind.photo, entryId: file.entryId, password: password);

  /// Absolute local path (read only).
  final String path;

  /// The name shown.
  final String displayName;

  /// The input is a photo that becomes one page.
  final bool isImage;

  /// Its Danaview folder entry, when it is one (the result goes next to the first such entry).
  final EntryId? entryId;

  /// The password of an encrypted PDF, once given.
  final String? password;

  /// This item with [password].
  PdfMergeItem withPassword(String password) => PdfMergeItem(path: path, displayName: displayName, isImage: isImage, entryId: entryId, password: password);

  /// The tool input.
  PdfToolInput get input => isImage ? PdfToolInput.image(path) : PdfToolInput.pdf(path, password: password);

  @override
  bool operator ==(Object other) => other is PdfMergeItem && other.path == path && other.isImage == isImage && other.entryId == entryId;

  @override
  int get hashCode => Object.hash(path, isImage, entryId);

  // Never prints the name, the path or the password (rule 30).
  @override
  String toString() => 'PdfMergeItem(${isImage ? 'image' : 'pdf'})';
}

/// Picks more files to merge (PDFs and photos in the library); [current] are already listed.
typedef PdfMergePicker = Future<List<PdfMergeItem>> Function(BuildContext context, List<PdfMergeItem> current);

/// What the page tools need, built once by the app root.
@immutable
final class PdfToolsEnvironment {
  /// An environment.
  const PdfToolsEnvironment({required this.documents, required this.tools, required this.sink, this.pickMergeInputs, this.annotate});

  /// Read-only documents (thumbnails, passwords, page counts).
  final PdfDocuments documents;

  /// The page tools.
  final PdfPageTools tools;

  /// Where results are saved.
  final PdfResultSink sink;

  /// "Add files" in the merge screen; null hides it.
  final PdfMergePicker? pickMergeInputs;

  /// Annotate mode and its save (HOM-29); null hides "Annotate".
  final PdfAnnotateEngine? annotate;
}

/// Provides a [PdfToolsEnvironment] to the PDF viewer below it.
class PdfToolsScope extends InheritedWidget {
  /// Provides [environment] to [child].
  const PdfToolsScope({super.key, required this.environment, required super.child});

  /// The tools' dependencies.
  final PdfToolsEnvironment environment;

  /// The environment above [context], or null (no tool buttons).
  static PdfToolsEnvironment? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PdfToolsScope>()?.environment;

  @override
  bool updateShouldNotify(PdfToolsScope oldWidget) => !identical(environment, oldWidget.environment);
}

Route<T> _toolRoute<T>(BuildContext context, String name, WidgetBuilder builder) {
  final disable = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  return PageRouteBuilder<T>(
    opaque: true,
    settings: RouteSettings(name: name),
    transitionDuration: disable ? Duration.zero : DanaviewMotion.normal,
    reverseTransitionDuration: disable ? Duration.zero : DanaviewMotion.fast,
    pageBuilder: (context, _, __) => ColoredBox(
      color: DanaviewColors.background,
      child: DefaultTextStyle.merge(
        style: DanaviewTextStyles.body.copyWith(decoration: TextDecoration.none),
        child: Builder(builder: builder),
      ),
    ),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
}

/// Opens the page organiser for the PDF [file] ([password] when the caller already unlocked it).
/// Resolves to the saved result that ended it (a new file or the replaced original), or null.
Future<PdfSavedFile?> openPdfOrganiser(BuildContext context, PdfToolsEnvironment environment, ViewerFile file, {String? password}) =>
    Navigator.of(context).push<PdfSavedFile>(_toolRoute(
      context,
      'pdf-organiser',
      (routeContext) => PdfPageOrganiser(
        file: file,
        environment: environment,
        password: password,
        onClose: (saved) => Navigator.of(routeContext).pop(saved),
        onMergeWith: environment.pickMergeInputs == null
            ? null
            : (pw) => openPdfMerge(routeContext, environment, [PdfMergeItem.ofFile(file, password: pw)], pickFirst: true),
      ),
    ));

/// Opens the merge screen with [items] in order; with [pickFirst] the picker opens at once (Merge
/// with…). Resolves to the merged file, or null.
Future<PdfSavedFile?> openPdfMerge(BuildContext context, PdfToolsEnvironment environment, List<PdfMergeItem> items, {bool pickFirst = false}) =>
    Navigator.of(context).push<PdfSavedFile>(_toolRoute(
      context,
      'pdf-merge',
      (routeContext) => PdfMergeScreen(
        items: items,
        environment: environment,
        pickFirst: pickFirst,
        onClose: (saved) => Navigator.of(routeContext).pop(saved),
      ),
    ));
