// OWNER: UX-37
//
// Spoken-language choice (ux.md §12.2 step 1, ai.md §11.3, D-19): a search field over whisper's 99
// languages (matching English name, native name and code), recent languages and the device
// language at the top, then "Detect automatically" as a secondary row (never the default unless the
// user chose it before), then every language by English name. Used by the configure step and by
// "Other language…" of the low-confidence question (where "Detect automatically" is hidden).

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_transcription/danaview_transcription.dart' show AutoLanguage, FixedLanguage, SpokenLanguage, TranscriptionLanguage;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/strings/captions_strings.dart';
import 'captions_progress_panel.dart' show CaptionsText;

/// Whether [language] matches the search [query] (English name, native name, whisper code or
/// BCP-47 tag; case-insensitive).
bool languageMatches(TranscriptionLanguage language, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return language.englishName.toLowerCase().contains(q) ||
      language.nativeName.toLowerCase().contains(q) ||
      language.whisperCode.toLowerCase() == q ||
      language.bcp47.toLowerCase() == q;
}

/// The language list with search.
class LanguagePicker extends StatefulWidget {
  /// Creates the picker.
  const LanguagePicker({
    super.key,
    required this.languages,
    required this.selected,
    required this.onSelected,
    this.recent = const [],
    this.deviceLanguage,
    this.allowAuto = true,
    this.onBack,
  });

  /// Every language (whisper order).
  final List<TranscriptionLanguage> languages;

  /// The current choice.
  final SpokenLanguage? selected;

  /// Receives the choice.
  final ValueChanged<SpokenLanguage> onSelected;

  /// Recent whisper codes, newest first.
  final List<String> recent;

  /// The device locale's language (D-19), if whisper knows it.
  final TranscriptionLanguage? deviceLanguage;

  /// Whether "Detect automatically" is offered.
  final bool allowAuto;

  /// Back to the previous view; null hides the button.
  final VoidCallback? onBack;

  @override
  State<LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<LanguagePicker> {
  String _query = '';

  bool _isSelected(TranscriptionLanguage l) => switch (widget.selected) {
        FixedLanguage(:final code) => code == l.whisperCode,
        _ => false,
      };

  Widget _tile(TranscriptionLanguage l, {String prefix = ''}) => DanaviewListTile(
        key: ValueKey('captions-language-$prefix${l.whisperCode}'),
        title: l.englishName,
        subtitle: l.nativeName == l.englishName ? null : l.nativeName,
        selected: _isSelected(l),
        dense: true,
        trailing: _isSelected(l) ? const Icon(Icons.check_rounded, size: 18, color: DanaviewColors.primaryLight) : null,
        onTap: () => widget.onSelected(FixedLanguage(l.whisperCode)),
      );

  @override
  Widget build(BuildContext context) {
    final byCode = {for (final l in widget.languages) l.whisperCode: l};
    final searching = _query.trim().isNotEmpty;
    final sorted = [...widget.languages]..sort((a, b) => a.englishName.compareTo(b.englishName));
    final matches = [for (final l in sorted) if (languageMatches(l, _query)) l];
    final top = <TranscriptionLanguage>[];
    for (final c in widget.recent) {
      final l = byCode[c];
      if (l != null && !top.contains(l)) top.add(l);
    }
    final device = widget.deviceLanguage;
    final showDevice = device != null && !top.contains(device);
    return Column(
      key: const ValueKey('captions-language-picker'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (widget.onBack != null) ...[
              DanaviewIconButton(
                key: const ValueKey('captions-language-back'),
                icon: Icons.arrow_back_rounded,
                size: 36,
                iconSize: 18,
                tooltip: CaptionsStrings.back,
                onPressed: widget.onBack,
              ),
              const SizedBox(width: DanaviewSpacing.sm),
            ],
            Expanded(child: Semantics(header: true, child: Text(CaptionsStrings.chooseLanguage, style: CaptionsText.headline))),
          ],
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewSearchField(
          key: const ValueKey('captions-language-search'),
          hint: CaptionsStrings.searchLanguages,
          semanticLabel: CaptionsStrings.searchLanguages,
          debounce: Duration.zero,
          onChanged: (q) => setState(() => _query = q),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        if (!searching) ...[
          if (top.isNotEmpty) ...[
            _Section(CaptionsStrings.recent),
            for (final l in top) _tile(l, prefix: 'recent-'),
          ],
          if (showDevice) ...[
            _Section(CaptionsStrings.deviceLanguage),
            _tile(device, prefix: 'device-'),
          ],
          if (widget.allowAuto)
            DanaviewListTile(
              key: const ValueKey('captions-language-auto'),
              title: CaptionsStrings.detectAutomatically,
              subtitle: CaptionsStrings.detectHint,
              subtitleMaxLines: 2,
              dense: true,
              leading: const Icon(Icons.hearing_rounded, size: 18, color: DanaviewColors.textSecondary),
              selected: widget.selected is AutoLanguage,
              onTap: () => widget.onSelected(const AutoLanguage()),
            ),
          _Section(CaptionsStrings.allLanguages),
        ],
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.lg),
            child: Text(CaptionsStrings.noLanguageFound, key: const ValueKey('captions-language-none'), style: CaptionsText.secondary),
          ),
        for (final l in matches) _tile(l),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.md, bottom: DanaviewSpacing.xs),
        child: Semantics(header: true, child: Text(title, style: CaptionsText.section)),
      );
}
