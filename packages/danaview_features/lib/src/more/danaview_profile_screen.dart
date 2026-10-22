import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library/library_actions.dart';
import '../library/library_widgets.dart';
import 'profile_controller.dart';
import 'settings_widgets.dart';

enum _Field { name, email, phone }

/// Edits the optional on-device profile. Field errors appear once typing pauses (or the field
/// loses focus) and then follow every keystroke; Save stays disabled until the form is valid and
/// differs from what is stored.
class DanaviewProfileScreen extends ConsumerStatefulWidget {
  const DanaviewProfileScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<DanaviewProfileScreen> createState() => _DanaviewProfileScreenState();
}

class _DanaviewProfileScreenState extends ConsumerState<DanaviewProfileScreen> {
  static const _errorDelay = Duration(milliseconds: 700);

  final Map<_Field, TextEditingController> _controllers = {
    for (final field in _Field.values) field: TextEditingController(),
  };
  final Map<_Field, FocusNode> _focusNodes = {for (final field in _Field.values) field: FocusNode()};
  final Set<_Field> _visibleErrors = {};
  Timer? _errorTimer;

  DateTime? _dateOfBirth;
  UserProfile _saved = UserProfile.empty;
  bool _loaded = false;
  Object? _loadError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final field in _Field.values) {
      _focusNodes[field]!.addListener(() {
        if (!_focusNodes[field]!.hasFocus) _revealError(field);
      });
    }
    _load();
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await ref.read(profileProvider.future);
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loadError = null;
      });
      _apply(profile);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _retry() {
    setState(() => _loadError = null);
    ref.invalidate(profileRepositoryProvider);
    _load();
  }

  /// Shows [profile] in the form as the stored state.
  void _apply(UserProfile profile) {
    _errorTimer?.cancel();
    setState(() {
      _saved = profile;
      _dateOfBirth = profile.dateOfBirth;
      _visibleErrors.clear();
    });
    _controllers[_Field.name]!.text = profile.name;
    _controllers[_Field.email]!.text = profile.email;
    _controllers[_Field.phone]!.text = profile.phone;
  }

  UserProfile get _draft => UserProfile(
        name: _controllers[_Field.name]!.text,
        email: _controllers[_Field.email]!.text,
        phone: _controllers[_Field.phone]!.text,
        dateOfBirth: _dateOfBirth,
      ).normalized();

  bool get _dirty => _loaded && _draft != _saved;

  bool get _canSave => _dirty && !_saving && ProfileValidation.isValid(_draft);

  String? _errorFor(_Field field) {
    final text = _controllers[field]!.text;
    return switch (field) {
      _Field.name => ProfileValidation.name(text),
      _Field.email => ProfileValidation.email(text),
      _Field.phone => ProfileValidation.phone(text),
    };
  }

  void _onChanged(_Field field) {
    _errorTimer?.cancel();
    final error = _errorFor(field);
    setState(() {
      if (error == null) _visibleErrors.remove(field);
    });
    if (error != null && !_visibleErrors.contains(field)) {
      _errorTimer = Timer(_errorDelay, () => _revealError(field));
    }
  }

  void _revealError(_Field field) {
    if (!mounted || _visibleErrors.contains(field) || _errorFor(field) == null) return;
    setState(() => _visibleErrors.add(field));
  }

  Future<void> _pickDateOfBirth() async {
    final now = DateTime.now();
    final picked = await showDanaviewDatePicker(
      context,
      title: 'Date of birth',
      initialDate: _dateOfBirth ?? DateTime(now.year - 25),
      firstDate: ProfileValidation.earliestDateOfBirth(now: now),
      lastDate: now,
    );
    if (picked != null && mounted) setState(() => _dateOfBirth = picked);
  }

  void _clearDateOfBirth() => setState(() => _dateOfBirth = null);

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(profileProvider.notifier).save(_draft);
      if (!mounted) return;
      _apply(saved);
      showDanaviewSuccess(context, saved.isEmpty ? 'Profile cleared' : 'Profile saved');
    } catch (e) {
      debugPrint('[Profile] save failed: $e');
      if (mounted) {
        DanaviewToast.show(
          context,
          "Couldn't save your profile. Please try again.",
          kind: DanaviewToastKind.error,
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _revert() => _apply(_saved);

  Future<void> _clear() async {
    final confirmed = await showDanaviewConfirm(
      context,
      title: 'Clear profile',
      message: 'Your name, email, phone number and date of birth will be removed from this device.',
      confirmLabel: 'Clear',
      destructive: true,
      icon: Icons.person_remove_rounded,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(profileProvider.notifier).clear();
      if (!mounted) return;
      _apply(UserProfile.empty);
      showDanaviewSuccess(context, 'Profile cleared');
    } catch (e) {
      debugPrint('[Profile] clear failed: $e');
      if (mounted) {
        DanaviewToast.show(
          context,
          "Couldn't clear your profile. Please try again.",
          kind: DanaviewToastKind.error,
          icon: Icons.error_outline_rounded,
        );
      }
    }
  }

  /// Unsaved edits need a confirmation before leaving.
  Future<void> _leave() async {
    if (_dirty) {
      final discard = await showDanaviewConfirm(
        context,
        title: 'Discard changes',
        message: "Your edits to the profile haven't been saved.",
        confirmLabel: 'Discard',
        cancelLabel: 'Keep editing',
        destructive: true,
      );
      if (!discard || !mounted) return;
    }
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: DanaviewColors.background,
        body: DanaviewLibraryFrame(
          topBar: DanaviewLibraryTopBar(title: 'Profile', onBack: _leave),
          body: _loadError != null
              ? DanaviewEmptyState(
                  icon: Icons.error_outline_rounded,
                  iconColor: DanaviewColors.errorLight,
                  title: "Couldn't load your profile",
                  message: 'Nothing was changed. Try loading it again.',
                  actions: [
                    DanaviewButton.secondary(label: 'Try again', icon: Icons.refresh_rounded, onPressed: _retry),
                  ],
                )
              : !_loaded
                  ? const Center(child: DanaviewSpinner(size: 28))
                  : _form(context),
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final draft = _draft;
    final dobError = ProfileValidation.dateOfBirth(_dateOfBirth);
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        // The narrowest phones give the fields the card's padding back.
        final cardPadding = EdgeInsets.all(constraints.maxWidth < 360 ? DanaviewSpacing.md : DanaviewSpacing.lg);
        return ListView(
          padding: insets.copyWith(
            top: DanaviewSpacing.xl,
            bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
          ),
          children: [
            _Header(profile: draft),
            const SizedBox(height: DanaviewSpacing.xl),
            const _OnDeviceNote(),
            const DanaviewLibrarySectionHeader('Details', topSpacing: DanaviewSpacing.xl),
            DanaviewSurface(
              color: DanaviewColors.surface,
              padding: cardPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _textField(
                    _Field.name,
                    label: 'Name',
                    hint: 'Your name',
                    icon: Icons.person_rounded,
                    keyboardType: TextInputType.name,
                    capitalization: TextCapitalization.words,
                    next: _Field.email,
                  ),
                  const SizedBox(height: DanaviewSpacing.lg),
                  _textField(
                    _Field.email,
                    label: 'Email',
                    hint: 'name@example.com',
                    icon: Icons.mail_rounded,
                    keyboardType: TextInputType.emailAddress,
                    next: _Field.phone,
                  ),
                  const SizedBox(height: DanaviewSpacing.lg),
                  _textField(
                    _Field.phone,
                    label: 'Phone',
                    hint: '+1 555 010 0199',
                    icon: Icons.phone_rounded,
                    keyboardType: TextInputType.phone,
                    formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\-. ]'))],
                  ),
                  const SizedBox(height: DanaviewSpacing.lg),
                  const _FieldLabel('Date of birth'),
                  _DateOfBirthField(
                    value: _dateOfBirth,
                    error: dobError,
                    onTap: _pickDateOfBirth,
                    onClear: _clearDateOfBirth,
                  ),
                ],
              ),
            ),
            const SizedBox(height: DanaviewSpacing.xl),
            DanaviewButtonBar(
              children: [
                DanaviewButton.secondary(label: 'Undo changes', onPressed: _dirty && !_saving ? _revert : null),
                DanaviewButton.primary(
                  label: _saving ? 'Saving…' : 'Save',
                  icon: Icons.check_rounded,
                  onPressed: _canSave ? _save : null,
                ),
              ],
            ),
            const DanaviewLibrarySectionHeader('Remove'),
            DanaviewSurface(
              color: DanaviewColors.surface,
              padding: cardPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Clearing removes your profile from this device. Your videos, history and playlists are not '
                    'affected.',
                    style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.35),
                  ),
                  const SizedBox(height: DanaviewSpacing.md),
                  DanaviewButton.destructive(
                    label: 'Clear profile',
                    icon: Icons.delete_outline_rounded,
                    size: DanaviewButtonSize.sm,
                    onPressed: _saved.isEmpty && draft.isEmpty ? null : _clear,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _textField(
    _Field field, {
    required String label,
    required String hint,
    required IconData icon,
    required TextInputType keyboardType,
    TextCapitalization capitalization = TextCapitalization.none,
    List<TextInputFormatter>? formatters,
    _Field? next,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldLabel(label),
        DanaviewTextField(
          controller: _controllers[field],
          focusNode: _focusNodes[field],
          hint: hint,
          prefixIcon: icon,
          semanticLabel: label,
          keyboardType: keyboardType,
          textCapitalization: capitalization,
          inputFormatters: formatters,
          textInputAction: next == null ? TextInputAction.done : TextInputAction.next,
          errorText: _visibleErrors.contains(field) ? _errorFor(field) : null,
          onChanged: (_) => _onChanged(field),
          onSubmitted: (_) {
            _revealError(field);
            if (next != null) {
              _focusNodes[next]!.requestFocus();
            } else if (_canSave) {
              _save();
            }
          },
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: DanaviewSpacing.xs, bottom: 6),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DanaviewTextStyles.label.copyWith(color: DanaviewColors.textSecondary),
      ),
    );
  }
}

/// The avatar and a live preview of the name and email being edited.
class _Header extends StatelessWidget {
  const _Header({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final title = profile.name.isNotEmpty ? profile.name : 'Your profile';
    final subtitle = profile.email.isNotEmpty
        ? profile.email
        : profile.phone.isNotEmpty
            ? profile.phone
            : 'Add the details you want Danaview to show';
    return Column(
      children: [
        ProfileAvatar(initials: profile.initials, size: 88),
        const SizedBox(height: DanaviewSpacing.md),
        Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: DanaviewTextStyles.largeTitle,
        ),
        const SizedBox(height: DanaviewSpacing.xs),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: DanaviewTextStyles.bodySecondary,
        ),
      ],
    );
  }
}

class _OnDeviceNote extends StatelessWidget {
  const _OnDeviceNote();

  @override
  Widget build(BuildContext context) {
    return DanaviewSurface(
      color: DanaviewColors.surface,
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DanaviewTileIcon(Icons.lock_rounded, color: DanaviewColors.success, size: 32),
          const SizedBox(width: DanaviewSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                'Stored only on this device. Danaview has no accounts and never uploads your profile. '
                'Every field is optional.',
                style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.35, color: DanaviewColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Looks like a text field; opens the date picker. Shows the age under a valid date.
class _DateOfBirthField extends StatelessWidget {
  const _DateOfBirthField({
    required this.value,
    required this.error,
    required this.onTap,
    required this.onClear,
  });

  final DateTime? value;
  final String? error;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final date = value;
    final text = date == null ? 'Add date of birth' : danaviewFormatDate(date);
    final age = date == null || error != null ? null : ProfileValidation.ageOn(date, DateTime.now());
    // The error reads from its message below the field; the outline stays a neutral hairline.
    const border = DanaviewBorders.hairline;

    final field = DanaviewPressable.builder(
      onTap: onTap,
      semanticLabel: date == null ? 'Date of birth, not set. Choose a date' : 'Date of birth, $text. Change',
      pressedScale: 1,
      builder: (context, state) {
        return AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget),
          padding: EdgeInsetsDirectional.only(start: 10, end: date == null ? 12 : 2),
          decoration: BoxDecoration(
            color: state.focused || state.pressed ? DanaviewColors.fieldActive : DanaviewColors.surfaceElevatedHigher,
            borderRadius: DanaviewRadius.mdAll,
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: DanaviewRadius.mdAll,
            border: Border.fromBorderSide(state.focused ? DanaviewBorders.focus : border),
          ),
          child: Row(
            children: [
              Icon(
                Icons.cake_rounded,
                size: 18,
                color: state.focused ? DanaviewColors.primaryLight : DanaviewColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.3,
                      color: date == null ? DanaviewColors.textMuted : DanaviewColors.textPrimary,
                    ),
                  ),
                ),
              ),
              if (date == null)
                const Icon(Icons.calendar_month_rounded, size: 18, color: DanaviewColors.textMuted)
              else
                DanaviewIconButton(
                  icon: Icons.cancel_rounded,
                  size: 30,
                  iconSize: 18,
                  color: DanaviewColors.textMuted,
                  tooltip: 'Clear date of birth',
                  onPressed: onClear,
                ),
            ],
          ),
        );
      },
    );

    final note = error ?? (age == null ? null : 'Age $age');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
            child: Text(
              note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: error != null ? DanaviewColors.errorLight : DanaviewColors.textMuted),
            ),
          ),
      ],
    );
  }
}
