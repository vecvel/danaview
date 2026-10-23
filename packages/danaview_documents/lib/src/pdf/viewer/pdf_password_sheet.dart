// OWNER: HOM-24
//
// The password prompt of an encrypted PDF (HOM plan §8.4: "PDFKit unlocks them with a password
// prompt"), a kit sheet: an obscured field with the Unlock button next to it (no gap between
// related controls), a calm sentence when the password is wrong, Cancel. The sheet asks
// [tryPassword] itself, so a wrong password keeps it open. The password is never logged or stored
// (rule 30).

import 'dart:async';

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

/// Tries a password; true when it unlocked the document.
typedef PdfPasswordAttempt = Future<bool> Function(String password);

/// Shows the password sheet; completes with true once [tryPassword] accepted a password, false
/// when the user cancelled.
Future<bool> showPdfPasswordSheet(BuildContext context, {required PdfPasswordAttempt tryPassword}) async {
  final unlocked = await showDanaviewSheet<bool>(
    context,
    title: 'Password required',
    builder: (context) => PdfPasswordForm(tryPassword: tryPassword, onDone: (ok) => Navigator.of(context).pop(ok)),
  );
  return unlocked ?? false;
}

/// The body of the password sheet.
class PdfPasswordForm extends StatefulWidget {
  /// A form that calls [tryPassword] and then [onDone].
  const PdfPasswordForm({super.key, required this.tryPassword, required this.onDone});

  /// Checks a password.
  final PdfPasswordAttempt tryPassword;

  /// Called with true after a successful unlock, false on Cancel.
  final ValueChanged<bool> onDone;

  @override
  State<PdfPasswordForm> createState() => _PdfPasswordFormState();
}

class _PdfPasswordFormState extends State<PdfPasswordForm> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  bool _wrong = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _controller.text;
    if (_busy || password.isEmpty) return;
    setState(() {
      _busy = true;
      _wrong = false;
    });
    var ok = false;
    try {
      ok = await widget.tryPassword(password);
    } on Object {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      widget.onDone(true);
      return;
    }
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    setState(() {
      _busy = false;
      _wrong = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final field = DanaviewTextField(
      controller: _controller,
      hint: 'Password',
      prefixIcon: Icons.lock_outline_rounded,
      obscureText: true,
      autofocus: true,
      enabled: !_busy,
      showClearButton: false,
      textInputAction: TextInputAction.done,
      semanticLabel: 'Password',
      onChanged: (_) {
        if (_wrong) setState(() => _wrong = false);
      },
      onSubmitted: (_) => unawaited(_submit()),
    );
    final unlock = DanaviewButton.primary(
      label: _busy ? 'Unlocking' : 'Unlock',
      semanticLabel: 'Unlock',
      onPressed: _busy ? null : () => unawaited(_submit()),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('This PDF is protected. Enter its password to open it.', style: DanaviewTextStyles.bodySecondary),
        const SizedBox(height: DanaviewSpacing.md),
        LayoutBuilder(
          builder: (context, c) => c.maxWidth < 300
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [field, const SizedBox(height: DanaviewSpacing.sm), unlock],
                )
              : Row(children: [Expanded(child: field), const SizedBox(width: DanaviewSpacing.sm), unlock]),
        ),
        if (_wrong) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          Semantics(
            liveRegion: true,
            child: const Text('That password didn\'t work. Try again.', style: DanaviewTextStyles.caption),
          ),
        ],
        const SizedBox(height: DanaviewSpacing.md),
        Align(
          alignment: Alignment.centerRight,
          child: DanaviewButton.ghost(label: 'Cancel', semanticLabel: 'Cancel', onPressed: _busy ? null : () => widget.onDone(false)),
        ),
      ],
    );
  }
}
