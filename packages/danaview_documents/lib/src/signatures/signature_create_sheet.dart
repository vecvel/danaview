// OWNER: HOM-30
//
// "New signature" (HOM plan §8.5 "draw, type or import a signature"), a kit sheet with three ways
// in, picked with a segmented control:
//
// * Draw: the pad (signature_pad.dart) in black or dark blue ink, with Undo and Clear.
// * Type: the name in the bundled script fonts the app hands in ([SignatureFont]; the app passes
//   OFL fonts it already bundles, the fallback is the app font in italic), each shown on paper to
//   pick from, in black or dark blue.
// * Import: a photo of a signature on paper (the app's picker); its background is removed and it
//   is cropped to the ink (signature_image.dart), with a preview before saving.
//
// Save turns the choice into a transparent PNG and adds it to the app-private store, refusing (with
// a clear sentence) when [SignatureStore.maxCount] are saved. Cinema B: neutral swatches with a
// check, 44 pt targets, no hover or press tints, labels for screen readers. Nothing here logs the
// name, a path or the image (rule 30).

import 'dart:async';
import 'dart:typed_data';

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import 'signature_image.dart';
import 'signature_pad.dart';
import 'signature_store.dart';

/// A script font for typed signatures.
@immutable
final class SignatureFont {
  /// [family] (from [package], when a package bundles it) shown as [label].
  const SignatureFont(this.label, this.family, {this.package, this.italic = false, this.weight = FontWeight.w400});

  /// The name the picker reads out.
  final String label;

  /// The font family.
  final String family;

  /// The package that declares it, if any.
  final String? package;

  /// Draw it in italic.
  final bool italic;

  /// Its weight.
  final FontWeight weight;

  /// The style of a typed signature in [color] at [size].
  TextStyle style(Color color, double size) => TextStyle(
        fontFamily: family,
        package: package,
        fontSize: size,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        fontWeight: weight,
        color: color,
        decoration: TextDecoration.none,
        height: 1.2,
      );
}

/// The fallback when the app bundles no script font: the app font in italic.
const SignatureFont signatureFallbackFont = SignatureFont('Italic', DanaviewFonts.family, italic: true, weight: FontWeight.w500);

/// Picks a photo of a signature; resolves to its bytes, or null when cancelled.
typedef SignaturePhotoPicker = Future<Uint8List?> Function(BuildContext context);

/// Makes the PNG of each way in (tests replace it).
class SignatureImageMaker {
  /// The real maker.
  const SignatureImageMaker();

  /// The drawn [strokes] on a [padSize] pad in [color].
  Future<Uint8List?> drawn(List<List<Offset>> strokes, Size padSize, Color color) async {
    final b = await renderDrawnSignature(strokes, padSize, color);
    return b == null ? null : encodeSignaturePng(b);
  }

  /// [name] in [font] and [color].
  Future<Uint8List?> typed(String name, SignatureFont font, Color color) async {
    final b = await renderTypedSignature(name, font.style(color, 64));
    return b == null ? null : encodeSignaturePng(b);
  }

  /// A photo's [bytes] cleaned: the PNG, or the problem.
  Future<({Uint8List? png, SignaturePhotoProblem? problem})> photo(Uint8List bytes) async {
    final decoded = await decodeSignaturePhoto(bytes);
    final cleaned = await cleanSignaturePhotoInBackground(decoded);
    final b = cleaned.bitmap;
    if (b == null) return (png: null, problem: cleaned.problem ?? SignaturePhotoProblem.noInk);
    return (png: await encodeSignaturePng(b), problem: null);
  }
}

/// The sentence for a photo that gave no signature.
String signaturePhotoProblemText(SignaturePhotoProblem problem) => switch (problem) {
      SignaturePhotoProblem.noInk => 'No signature found in this photo. Try a photo of dark ink on light paper.',
      SignaturePhotoProblem.notOnPaper => 'The background is too dark. Try a photo of the signature on white paper.',
    };

/// The sentence when the store is full.
const String signatureStoreFullText = 'You have ${SignatureStore.maxCount} saved signatures. Delete one to add another.';

/// Shows "New signature"; resolves to the saved signature, or null.
Future<SavedSignature?> showSignatureCreateSheet(
  BuildContext context, {
  required SignatureStore store,
  List<SignatureFont> fonts = const [],
  SignaturePhotoPicker? pickPhoto,
  SignatureImageMaker maker = const SignatureImageMaker(),
}) =>
    showDanaviewSheet<SavedSignature>(
      context,
      title: 'New signature',
      builder: (sheetContext) => SignatureCreatePanel(
        store: store,
        fonts: fonts,
        pickPhoto: pickPhoto,
        maker: maker,
        onDone: (saved) => Navigator.of(sheetContext).pop(saved),
      ),
    );

/// The ways in.
enum SignatureCreateMode {
  /// The pad.
  draw,

  /// A typed name.
  type,

  /// A photo.
  import,
}

/// The body of "New signature".
class SignatureCreatePanel extends StatefulWidget {
  /// A panel saving into [store].
  const SignatureCreatePanel({
    super.key,
    required this.store,
    required this.onDone,
    this.fonts = const [],
    this.pickPhoto,
    this.maker = const SignatureImageMaker(),
  });

  /// Where it is saved.
  final SignatureStore store;

  /// The script fonts (empty: the fallback).
  final List<SignatureFont> fonts;

  /// The photo picker; null hides Import.
  final SignaturePhotoPicker? pickPhoto;

  /// Makes the PNGs.
  final SignatureImageMaker maker;

  /// Called with the saved signature (null: cancelled).
  final ValueChanged<SavedSignature?> onDone;

  @override
  State<SignatureCreatePanel> createState() => _SignatureCreatePanelState();
}

class _SignatureCreatePanelState extends State<SignatureCreatePanel> {
  SignatureCreateMode _mode = SignatureCreateMode.draw;
  int _ink = signatureInkColors.first;
  final SignaturePadController _pad = SignaturePadController();
  final TextEditingController _name = TextEditingController();
  int _font = 0;
  Uint8List? _photo;
  bool _working = false;
  String? _message;
  bool? _full;
  Size _padSize = Size.zero;

  List<SignatureFont> get _fonts => widget.fonts.isEmpty ? const [signatureFallbackFont] : widget.fonts;

  @override
  void initState() {
    super.initState();
    _pad.addListener(_changed);
    _name.addListener(_changed);
    unawaited(_checkFull());
  }

  Future<void> _checkFull() async {
    final full = await widget.store.count() >= SignatureStore.maxCount;
    if (mounted) setState(() => _full = full);
  }

  @override
  void dispose() {
    _pad.removeListener(_changed);
    _name.removeListener(_changed);
    _pad.dispose();
    _name.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() => _message = null);
  }

  bool get _ready => switch (_mode) {
        SignatureCreateMode.draw => !_pad.isEmpty,
        SignatureCreateMode.type => _name.text.trim().isNotEmpty,
        SignatureCreateMode.import => _photo != null,
      };

  Future<void> _pickPhoto() async {
    final pick = widget.pickPhoto;
    if (pick == null || _working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final bytes = await pick(context);
      if (bytes == null || !mounted) return;
      final result = await widget.maker.photo(bytes);
      if (!mounted) return;
      setState(() {
        _photo = result.png;
        _message = result.problem == null ? null : signaturePhotoProblemText(result.problem!);
      });
    } on Object {
      if (mounted) setState(() => _message = 'This photo couldn’t be read. Try another one.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _save() async {
    if (!_ready || _working || _full == true) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final color = Color(_ink);
      final Uint8List? png;
      final SignatureKind kind;
      switch (_mode) {
        case SignatureCreateMode.draw:
          png = await widget.maker.drawn(_pad.strokes, _padSize, color);
          kind = SignatureKind.drawn;
        case SignatureCreateMode.type:
          png = await widget.maker.typed(_name.text, _fonts[_font], color);
          kind = SignatureKind.typed;
        case SignatureCreateMode.import:
          png = _photo;
          kind = SignatureKind.imported;
      }
      if (png == null) {
        if (mounted) setState(() => _message = 'Nothing to save yet.');
        return;
      }
      final saved = await widget.store.add(png, kind: kind);
      if (mounted) widget.onDone(saved);
    } on SignatureStoreFullException {
      if (mounted) {
        setState(() {
          _full = true;
          _message = signatureStoreFullText;
        });
      }
    } on Object {
      if (mounted) setState(() => _message = 'The signature couldn’t be saved. Try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final modes = [
      const DanaviewOption(value: SignatureCreateMode.draw, label: 'Draw', icon: Icons.gesture_rounded),
      const DanaviewOption(value: SignatureCreateMode.type, label: 'Type', icon: Icons.keyboard_rounded),
      if (widget.pickPhoto != null) const DanaviewOption(value: SignatureCreateMode.import, label: 'Import', icon: Icons.photo_outlined),
    ];
    final message = _message ?? (_full == true ? signatureStoreFullText : null);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DanaviewSegmentedControl<SignatureCreateMode>(
            key: const ValueKey('signature-create-mode'),
            value: _mode,
            options: modes,
            enabled: !_working,
            onChanged: (m) => setState(() {
              _mode = m;
              _message = null;
            }),
          ),
          const SizedBox(height: DanaviewSpacing.md),
          ..._body(),
          if (message != null) ...[
            const SizedBox(height: DanaviewSpacing.sm),
            Text(message, key: const ValueKey('signature-create-message'), style: DanaviewTextStyles.footnote.copyWith(color: DanaviewColors.textSecondary)),
          ],
          const SizedBox(height: DanaviewSpacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: DanaviewSpacing.sm,
            runSpacing: DanaviewSpacing.xs,
            children: [
              DanaviewButton.secondary(
                key: const ValueKey('signature-create-cancel'),
                label: 'Cancel',
                semanticLabel: 'Cancel',
                onPressed: _working ? null : () => widget.onDone(null),
              ),
              DanaviewButton.primary(
                key: const ValueKey('signature-create-save'),
                label: 'Save signature',
                semanticLabel: 'Save signature',
                onPressed: _ready && !_working && _full == false ? () => unawaited(_save()) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _body() => switch (_mode) {
        SignatureCreateMode.draw => [
            LayoutBuilder(
              builder: (context, c) {
                final height = (c.maxWidth / 2.6).clamp(140.0, 240.0);
                _padSize = Size(c.maxWidth, height);
                return SizedBox(
                  height: height,
                  child: SignaturePad(key: const ValueKey('signature-pad'), controller: _pad, color: Color(_ink), enabled: !_working),
                );
              },
            ),
            const SizedBox(height: DanaviewSpacing.xs),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: DanaviewSpacing.xs,
              children: [
                ..._inks(),
                DanaviewIconButton.toolbar(
                  key: const ValueKey('signature-pad-undo'),
                  icon: Icons.undo_rounded,
                  tooltip: 'Undo stroke',
                  semanticLabel: 'Undo stroke',
                  onPressed: _pad.isEmpty || _working ? null : _pad.undo,
                ),
                DanaviewIconButton.toolbar(
                  key: const ValueKey('signature-pad-clear'),
                  icon: Icons.delete_sweep_outlined,
                  tooltip: 'Clear',
                  semanticLabel: 'Clear drawing',
                  onPressed: _pad.isEmpty || _working ? null : _pad.clear,
                ),
              ],
            ),
          ],
        SignatureCreateMode.type => [
            DanaviewTextField(
              key: const ValueKey('signature-type-name'),
              controller: _name,
              hint: 'Your name',
              enabled: !_working,
              textCapitalization: TextCapitalization.words,
              semanticLabel: 'Your name',
            ),
            const SizedBox(height: DanaviewSpacing.sm),
            for (final (i, f) in _fonts.indexed) ...[
              _FontChoice(
                key: ValueKey('signature-type-font-$i'),
                font: f,
                text: _name.text.trim().isEmpty ? 'Your name' : _name.text.trim(),
                color: Color(_ink),
                selected: _font == i,
                onTap: _working ? null : () => setState(() => _font = i),
              ),
              const SizedBox(height: DanaviewSpacing.xs),
            ],
            Wrap(spacing: DanaviewSpacing.xs, children: _inks()),
          ],
        SignatureCreateMode.import => [
            if (_photo case final png?)
              Container(
                key: const ValueKey('signature-import-preview'),
                constraints: const BoxConstraints(minHeight: 120, maxHeight: 200),
                padding: const EdgeInsets.all(DanaviewSpacing.md),
                decoration: const ShapeDecoration(
                  color: signaturePaperColor,
                  shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.controlAll, side: DanaviewBorders.hairline),
                ),
                child: Semantics(label: 'Imported signature', image: true, child: Image.memory(
                    png,
                    fit: BoxFit.contain,
                    errorBuilder: (context, _, __) => const Icon(Icons.broken_image_outlined, size: 24, color: Color(0xFF8A8A8E)),
                  ),
                ),
              )
            else
              Text(
                'Take or choose a photo of your signature in dark ink on light paper. The paper is removed.',
                style: DanaviewTextStyles.bodySecondary,
              ),
            const SizedBox(height: DanaviewSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: DanaviewButton.tonal(
                key: const ValueKey('signature-import-pick'),
                label: _photo == null ? 'Choose photo' : 'Choose another photo',
                icon: Icons.photo_library_outlined,
                semanticLabel: _photo == null ? 'Choose photo' : 'Choose another photo',
                onPressed: _working ? null : () => unawaited(_pickPhoto()),
              ),
            ),
          ],
      };

  List<Widget> _inks() => [
        for (final c in signatureInkColors)
          SignatureInkSwatch(
            key: ValueKey('signature-ink-${c.toRadixString(16)}'),
            color: Color(c),
            label: signatureInkNames[c]!,
            selected: _ink == c,
            onTap: _working ? null : () => setState(() => _ink = c),
          ),
      ];
}

/// One typed-signature font: the name on paper; the chosen one has a check.
class _FontChoice extends StatelessWidget {
  const _FontChoice({super.key, required this.font, required this.text, required this.color, required this.selected, required this.onTap});

  final SignatureFont font;
  final String text;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DanaviewPressable.builder(
      onTap: onTap,
      enabled: onTap != null,
      selected: selected,
      semanticLabel: '${font.label} style',
      builder: (context, state) => Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.sm),
        decoration: const ShapeDecoration(
          color: signaturePaperColor,
          shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.controlAll, side: DanaviewBorders.hairline),
        ),
        foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, borderRadius: DanaviewRadius.controlAll),
        child: Row(
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: font.style(color, 30)),
              ),
            ),
            SizedBox.square(
              dimension: 28,
              child: selected
                  ? const DecoratedBox(
                      decoration: BoxDecoration(color: Color(0xFF1C1C1E), shape: BoxShape.circle),
                      child: Icon(Icons.check_rounded, size: 18, color: Color(0xFFFFFFFF)),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// An ink swatch: a 28 pt disc in a 44 pt target; the chosen one shows a check (never an outline).
class SignatureInkSwatch extends StatelessWidget {
  /// A swatch of [color] named [label].
  const SignatureInkSwatch({super.key, required this.color, required this.label, required this.selected, required this.onTap});

  /// The ink.
  final Color color;

  /// Its spoken name.
  final String label;

  /// It is the chosen ink.
  final bool selected;

  /// Picks it.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DanaviewPressable.builder(
      onTap: onTap,
      enabled: onTap != null,
      selected: selected,
      semanticLabel: '$label ink',
      tooltip: '$label ink',
      builder: (context, state) => SizedBox.square(
        dimension: DanaviewSpacing.minTapTarget,
        child: Center(
          child: Container(
            width: 28,
            height: 28,
            decoration: DanaviewDepth.circle(color: color, side: const BorderSide(color: Color(0x4DFFFFFF))),
            foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, circle: true),
            child: selected ? const Icon(Icons.check_rounded, size: 16, color: Color(0xFFFFFFFF)) : null,
          ),
        ),
      ),
    );
  }
}
