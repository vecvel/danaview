import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_button.dart';
import 'danaview_button_bar.dart';
import 'danaview_sheet.dart';

const List<String> danaviewMonthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

const List<String> _weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// "14 March 1990", or "Wednesday, 14 March 1990" with [weekday].
String danaviewFormatDate(DateTime date, {bool weekday = false}) {
  final text = '${date.day} ${danaviewMonthNames[date.month - 1]} ${date.year}';
  return weekday ? '${_weekdayNames[date.weekday - 1]}, $text' : text;
}

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime _clampDate(DateTime date, DateTime first, DateTime last) =>
    date.isBefore(first) ? first : (date.isAfter(last) ? last : date);

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Picks a calendar day on three wheels (day, month, year) in a sheet. Resolves to the chosen
/// date at midnight, or null when cancelled or dismissed. Dates outside [firstDate]..[lastDate]
/// show dimmed and the wheels settle back inside the range.
Future<DateTime?> showDanaviewDatePicker(
  BuildContext context, {
  DateTime? initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  String? title,
}) {
  final first = _dateOnly(firstDate ?? DateTime(1900));
  final last = _dateOnly(lastDate ?? DateTime(2100, 12, 31));
  assert(!last.isBefore(first), 'lastDate must not be before firstDate');
  final initial = _clampDate(_dateOnly(initialDate ?? DateTime.now()), first, last);
  return showDanaviewSheet<DateTime>(
    context,
    title: title ?? 'Choose a date',
    maxWidth: 520,
    builder: (context) => _DanaviewDatePickerSheet(initialDate: initial, firstDate: first, lastDate: last),
  );
}

class _DanaviewDatePickerSheet extends StatefulWidget {
  const _DanaviewDatePickerSheet({required this.initialDate, required this.firstDate, required this.lastDate});

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_DanaviewDatePickerSheet> createState() => _DanaviewDatePickerSheetState();
}

class _DanaviewDatePickerSheetState extends State<_DanaviewDatePickerSheet> {
  final GlobalKey<DanaviewDateWheelsState> _wheels = GlobalKey();
  late DateTime _value = widget.initialDate;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            danaviewFormatDate(_value, weekday: true),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DanaviewTextStyles.bodySecondary,
          ),
        ),
        const SizedBox(height: DanaviewSpacing.md),
        DanaviewDateWheels(
          key: _wheels,
          initialDate: widget.initialDate,
          firstDate: widget.firstDate,
          lastDate: widget.lastDate,
          onChanged: (date) => setState(() => _value = date),
        ),
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            DanaviewButton.primary(
              label: 'Done',
              // The wheels may still be settling; take their in-range value.
              onPressed: () => Navigator.of(context).pop(_wheels.currentState?.value ?? _value),
            ),
          ],
        ),
      ],
    );
  }
}

/// Day, month and year wheels with a shared selection band. The day wheel follows the month's
/// length (Feb 29 only in leap years), and a date outside [firstDate]..[lastDate] settles back
/// to the nearest one in range once the wheels stop. Arrow keys turn the focused wheel; each
/// wheel is one adjustable control for screen readers.
///
/// The dates are read once; give the widget a new key to start over with others.
class DanaviewDateWheels extends StatefulWidget {
  const DanaviewDateWheels({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    this.onChanged,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  /// Called with each settled, in-range date.
  final ValueChanged<DateTime>? onChanged;

  @override
  State<DanaviewDateWheels> createState() => DanaviewDateWheelsState();
}

enum _Wheel { day, month, year }

class DanaviewDateWheelsState extends State<DanaviewDateWheels> {
  late DateTime _first;
  late DateTime _last;
  late int _year;
  late int _month;
  late int _day;
  late DateTime _reported;
  late final FixedExtentScrollController _dayController;
  late final FixedExtentScrollController _monthController;
  late final FixedExtentScrollController _yearController;
  double _itemExtent = 40;
  bool _settleScheduled = false;

  @override
  void initState() {
    super.initState();
    _first = _dateOnly(widget.firstDate);
    _last = _dateOnly(widget.lastDate);
    final initial = _clampDate(_dateOnly(widget.initialDate), _first, _last);
    _year = initial.year;
    _month = initial.month;
    _day = initial.day;
    _reported = initial;
    _dayController = FixedExtentScrollController(initialItem: _day - 1);
    _monthController = FixedExtentScrollController(initialItem: _month - 1);
    _yearController = FixedExtentScrollController(initialItem: _year - _first.year);
  }

  @override
  void dispose() {
    _dayController.dispose();
    _monthController.dispose();
    _yearController.dispose();
    super.dispose();
  }

  int get _dayCount => _daysInMonth(_year, _month);

  /// The selected date, moved into range.
  DateTime get value => _clampDate(DateTime(_year, _month, math.min(_day, _dayCount)), _first, _last);

  FixedExtentScrollController _controllerFor(_Wheel wheel) => switch (wheel) {
        _Wheel.day => _dayController,
        _Wheel.month => _monthController,
        _Wheel.year => _yearController,
      };

  int _countFor(_Wheel wheel) => switch (wheel) {
        _Wheel.day => _dayCount,
        _Wheel.month => 12,
        _Wheel.year => _last.year - _first.year + 1,
      };

  int _indexFor(_Wheel wheel) => switch (wheel) {
        _Wheel.day => math.min(_day, _dayCount) - 1,
        _Wheel.month => _month - 1,
        _Wheel.year => _year - _first.year,
      };

  String _labelFor(_Wheel wheel, int index) => switch (wheel) {
        _Wheel.day => '${index + 1}',
        _Wheel.month => danaviewMonthNames[index],
        _Wheel.year => '${_first.year + index}',
      };

  bool _inRange(_Wheel wheel, int index) {
    final (DateTime start, DateTime end) = switch (wheel) {
      _Wheel.day => (DateTime(_year, _month, index + 1), DateTime(_year, _month, index + 1)),
      _Wheel.month => (DateTime(_year, index + 1), DateTime(_year, index + 2, 0)),
      _Wheel.year => (DateTime(_first.year + index), DateTime(_first.year + index, 12, 31)),
    };
    return !end.isBefore(_first) && !start.isAfter(_last);
  }

  void _onSelected(_Wheel wheel, int index) {
    setState(() {
      switch (wheel) {
        case _Wheel.day:
          _day = index + 1;
        case _Wheel.month:
          _month = index + 1;
        case _Wheel.year:
          _year = _first.year + index;
      }
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification is ScrollEndNotification) _scheduleSettle();
    return false;
  }

  void _scheduleSettle() {
    if (_settleScheduled) return;
    _settleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleScheduled = false;
      if (mounted) _settle();
    });
  }

  /// Moves any wheel that points outside the valid date (a day the month doesn't have, a month
  /// out of range) to it, and reports the date when it changed.
  void _settle() {
    final target = value;
    if (target.year != _year || target.month != _month || target.day != _day) {
      setState(() {
        _year = target.year;
        _month = target.month;
        _day = target.day;
      });
    }
    for (final wheel in _Wheel.values) {
      _moveTo(wheel, _indexFor(wheel));
    }
    if (target != _reported) {
      _reported = target;
      widget.onChanged?.call(target);
    }
  }

  void _moveTo(_Wheel wheel, int index) {
    final controller = _controllerFor(wheel);
    if (!controller.hasClients) return;
    final position = controller.position;
    // A wheel the user is still turning settles again when it stops.
    if (position.isScrollingNotifier.value) return;
    if ((position.pixels - index * _itemExtent).abs() < 0.5) return;
    controller.animateToItem(index, duration: DanaviewMotion.normal, curve: DanaviewMotion.curve);
  }

  void _step(_Wheel wheel, int delta) {
    final controller = _controllerFor(wheel);
    if (!controller.hasClients) return;
    final index = (controller.selectedItem + delta).clamp(0, _countFor(wheel) - 1);
    if (index == controller.selectedItem) return;
    controller.animateToItem(index, duration: DanaviewMotion.fast, curve: DanaviewMotion.curve);
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    _itemExtent = math.max(40.0, (scaler.scale(17) * 1.3 + 14).roundToDouble());
    // Short windows (a landscape phone) show three rows instead of five.
    final rows = MediaQuery.sizeOf(context).height < 560 ? 3 : 5;
    final height = _itemExtent * rows;

    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Center(
            child: Container(
              height: _itemExtent,
              decoration: const BoxDecoration(
                color: DanaviewColors.surfaceElevatedHigher,
                borderRadius: DanaviewRadius.mdAll,
              ),
              foregroundDecoration: const BoxDecoration(borderRadius: DanaviewRadius.mdAll, border: DanaviewBorders.all),
            ),
          ),
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
              stops: [0, 0.32, 0.68, 1],
            ).createShader(bounds),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final monthWidth = (constraints.maxWidth - 2 * DanaviewSpacing.xs) * 4 / 9;
                final shortMonths = _widestMonth(context) > monthWidth - 12;
                return Row(
                  children: [
                    Expanded(flex: 2, child: _wheel(_Wheel.day, 'Day')),
                    const SizedBox(width: DanaviewSpacing.xs),
                    Expanded(flex: 4, child: _wheel(_Wheel.month, 'Month', shortLabels: shortMonths)),
                    const SizedBox(width: DanaviewSpacing.xs),
                    Expanded(flex: 3, child: _wheel(_Wheel.year, 'Year')),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static const TextStyle _itemStyle = TextStyle(fontSize: 17, height: 1.2, letterSpacing: -0.2);

  double _widestMonth(BuildContext context) {
    var widest = 0.0;
    final style = DefaultTextStyle.of(context).style.merge(_itemStyle.copyWith(fontWeight: FontWeight.w600));
    for (final name in danaviewMonthNames) {
      final painter = TextPainter(
        text: TextSpan(text: name, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return widest;
  }

  Widget _wheel(_Wheel wheel, String label, {bool shortLabels = false}) {
    final count = _countFor(wheel);
    final selected = _indexFor(wheel);
    String display(int index) {
      final text = _labelFor(wheel, index);
      return shortLabels ? text.substring(0, 3) : text;
    }

    final list = ListWheelScrollView.useDelegate(
      controller: _controllerFor(wheel),
      itemExtent: _itemExtent,
      diameterRatio: 1.6,
      perspective: 0.004,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: (index) => _onSelected(wheel, index),
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: count,
        builder: (context, index) {
          final isSelected = index == selected;
          final enabled = _inRange(wheel, index);
          final color = !enabled
              ? DanaviewColors.disabled(DanaviewColors.textMuted)
              : isSelected
                  ? DanaviewColors.textPrimary
                  : DanaviewColors.textSecondary;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controllerFor(wheel)
                .animateToItem(index, duration: DanaviewMotion.normal, curve: DanaviewMotion.curve),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    display(index),
                    maxLines: 1,
                    softWrap: false,
                    style: _itemStyle.copyWith(
                      color: color,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    return _WheelFocus(
      onStep: (delta) => _step(wheel, delta),
      child: Semantics(
        container: true,
        label: label,
        value: _labelFor(wheel, selected),
        increasedValue: selected + 1 < count ? _labelFor(wheel, selected + 1) : null,
        decreasedValue: selected > 0 ? _labelFor(wheel, selected - 1) : null,
        onIncrease: selected + 1 < count ? () => _step(wheel, 1) : null,
        onDecrease: selected > 0 ? () => _step(wheel, -1) : null,
        child: ExcludeSemantics(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: KeyedSubtree(key: ValueKey('danaview-date-wheel-${wheel.name}'), child: list),
          ),
        ),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}

/// Makes a wheel focusable: arrow keys and Page Up/Down turn it, and a focus ring shows in
/// keyboard mode.
class _WheelFocus extends StatefulWidget {
  const _WheelFocus({required this.onStep, required this.child});

  final ValueChanged<int> onStep;
  final Widget child;

  @override
  State<_WheelFocus> createState() => _WheelFocusState();
}

class _WheelFocusState extends State<_WheelFocus> {
  static const Map<ShortcutActivator, Intent> _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp): _StepIntent(-1),
    SingleActivator(LogicalKeyboardKey.arrowDown): _StepIntent(1),
    SingleActivator(LogicalKeyboardKey.pageUp): _StepIntent(-5),
    SingleActivator(LogicalKeyboardKey.pageDown): _StepIntent(5),
  };

  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      shortcuts: _shortcuts,
      actions: <Type, Action<Intent>>{
        _StepIntent: CallbackAction<_StepIntent>(onInvoke: (intent) {
          widget.onStep(intent.delta);
          return null;
        }),
      },
      onShowFocusHighlight: (value) {
        if (_focused != value) setState(() => _focused = value);
      },
      child: Container(
        foregroundDecoration: BoxDecoration(
          borderRadius: DanaviewRadius.mdAll,
          border: Border.fromBorderSide(
            _focused ? DanaviewBorders.focus : DanaviewBorders.focus.copyWith(color: const Color(0x00FFFFFF)),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
