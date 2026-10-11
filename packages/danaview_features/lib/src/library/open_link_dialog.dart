import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Asks for a stream or video link; resolves to the parsed remote ref, or null when cancelled.
Future<MediaRef?> showDanaviewOpenLinkDialog(
  BuildContext context, {
  String title = 'Open link',
  String confirmLabel = 'Play',
  IconData confirmIcon = Icons.play_arrow_rounded,
}) {
  return showDanaviewDialog<MediaRef>(
    context,
    builder: (context) => _DanaviewOpenLinkDialog(
      title: title,
      confirmLabel: confirmLabel,
      confirmIcon: confirmIcon,
    ),
  );
}

class _DanaviewOpenLinkDialog extends StatefulWidget {
  const _DanaviewOpenLinkDialog({
    required this.title,
    required this.confirmLabel,
    required this.confirmIcon,
  });

  final String title;
  final String confirmLabel;
  final IconData confirmIcon;

  @override
  State<_DanaviewOpenLinkDialog> createState() => _DanaviewOpenLinkDialogState();
}

class _DanaviewOpenLinkDialogState extends State<_DanaviewOpenLinkDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _attempted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    if (!_attempted) return;
    setState(() => _error = MediaUrl.validationError(_controller.text));
  }

  void _submit() {
    final error = MediaUrl.validationError(_controller.text);
    final media = error == null ? MediaUrl.tryParse(_controller.text) : null;
    if (media == null) {
      setState(() {
        _attempted = true;
        _error = error ?? 'Enter a valid link.';
      });
      return;
    }
    Navigator.of(context).pop(media);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      DanaviewToast.show(context, 'Nothing to paste. Copy a link first.', icon: Icons.content_paste_off_rounded);
      return;
    }
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    return DanaviewDialog(
      icon: Icons.link_rounded,
      iconColor: DanaviewColors.cyan,
      title: widget.title,
      message: 'Paste the address of a video or live stream: HTTP(S), HLS, DASH, RTSP, RTMP and more.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DanaviewTextField(
            controller: _controller,
            hint: 'https://example.com/video.mp4',
            prefixIcon: Icons.link_rounded,
            errorText: _error,
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onChanged: _onChanged,
            onSubmitted: (_) => _submit(),
            semanticLabel: 'Link',
          ),
          const SizedBox(height: DanaviewSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: DanaviewButton.ghost(
              label: 'Paste',
              icon: Icons.content_paste_rounded,
              size: DanaviewButtonSize.sm,
              onPressed: _paste,
            ),
          ),
        ],
      ),
      actions: [
        DanaviewButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        DanaviewButton.primary(label: widget.confirmLabel, icon: widget.confirmIcon, onPressed: _submit),
      ],
    );
  }
}
