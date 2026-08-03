import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/temporal_parser.dart';
import '../models/relic.dart';
import '../theme/relic_theme.dart';
import '../theme/tokens.dart';

const _monthLabels = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];
const _weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
int _secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

/// Date-filter modal: quick presets, a "Custom range" calendar, and a clear.
/// Reuses [parseTemporal] for the presets so they resolve identically to typing
/// the same phrase in the search box. Opened in the popup's dialog slot.
class DateFilterSheet extends StatefulWidget {
  final DateRange? current;

  /// Apply a range (null clears the filter). [label] is a friendly preset name;
  /// null means "derive a label from the dates".
  final void Function(DateRange? range, String? label) onPick;
  final VoidCallback onClose;

  const DateFilterSheet({
    super.key,
    required this.current,
    required this.onPick,
    required this.onClose,
  });

  @override
  State<DateFilterSheet> createState() => _DateFilterSheetState();
}

class _DateFilterSheetState extends State<DateFilterSheet> {
  bool _custom = false;

  static const _presets = [
    ('Today', 'today'),
    ('This week', 'this week'),
    ('Last 30 days', 'last 30 days'),
    ('This year', 'this year'),
  ];

  void _pickPreset(String label, String phrase) {
    final r = parseTemporal(phrase).range;
    widget.onPick(r, label);
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);
    return Container(
      width: m ? double.infinity : 320,
      constraints: const BoxConstraints(maxWidth: 360),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: c.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Icon(LucideIcons.calendar, size: m ? 18 : 15, color: c.accent),
                const SizedBox(width: 8),
                Text(
                  _custom ? 'Custom range' : 'Filter by date',
                  style: RelicTheme.sans(
                    size: m ? 15 : 13,
                    weight: FontWeight.w600,
                    color: c.text,
                  ),
                ),
                const Spacer(),
                _IconBtn(
                  icon: LucideIcons.x,
                  onTap: widget.onClose,
                ),
              ],
            ),
          ),
          Container(height: 1, color: c.border),
          if (!_custom) ...[
            for (final (label, phrase) in _presets)
              _Row(
                label: label,
                onTap: () => _pickPreset(label, phrase),
              ),
            _Row(
              label: 'Custom range…',
              icon: LucideIcons.calendarRange,
              onTap: () => setState(() => _custom = true),
            ),
            Container(height: 1, color: c.border),
            _Row(
              label: 'Clear date filter',
              icon: LucideIcons.x,
              muted: true,
              onTap: () => widget.onPick(null, null),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Text(
                'Tip: type dates in search, like “last week”, “before 2025”, “June 20”.',
                style: RelicTheme.mono(size: m ? 11 : 9.5, color: c.textFaintest),
              ),
            ),
          ] else
            DateRangeCalendar(
              initial: widget.current,
              onCancel: () => setState(() => _custom = false),
              onApply: (r) => widget.onPick(r, null),
            ),
        ],
      ),
    );
  }
}

/// A tappable preset/action row.
class _Row extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool muted;
  final VoidCallback onTap;
  const _Row({
    required this.label,
    this.icon,
    this.muted = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);
    final color = muted ? c.textMuted : c.text;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: m ? 13 : 10),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: m ? 17 : 14, color: muted ? c.textMuted : c.accentMuted),
                const SizedBox(width: 10),
              ],
              Text(
                label,
                style: RelicTheme.sans(size: m ? 14.5 : 12.5, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bespoke two-tap (start → end) month calendar styled in Relic's tokens.
class DateRangeCalendar extends StatefulWidget {
  final DateRange? initial;
  final void Function(DateRange range) onApply;
  final VoidCallback onCancel;

  const DateRangeCalendar({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
  });

  @override
  State<DateRangeCalendar> createState() => _DateRangeCalendarState();
}

class _DateRangeCalendarState extends State<DateRangeCalendar> {
  late DateTime _month; // first day of the visible month
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init?.after != null) {
      _start = _startOfDay(
          DateTime.fromMillisecondsSinceEpoch(init!.after! * 1000));
    }
    if (init?.before != null) {
      // `before` is exclusive — the last included day is one second earlier.
      _end = _startOfDay(
          DateTime.fromMillisecondsSinceEpoch((init!.before! - 1) * 1000));
    }
    final anchor = _start ?? _end ?? DateTime.now();
    _month = DateTime(anchor.year, anchor.month, 1);
  }

  void _tapDay(DateTime d) {
    setState(() {
      if (_start == null || _end != null) {
        _start = d;
        _end = null;
      } else if (d.isBefore(_start!)) {
        _end = _start;
        _start = d;
      } else {
        _end = d;
      }
    });
  }

  void _apply() {
    final a = _start;
    if (a == null) return;
    final b = _end ?? a;
    widget.onApply(DateRange(
      after: _secs(_startOfDay(a)),
      before: _secs(DateTime(b.year, b.month, b.day + 1)),
    ));
  }

  bool _inRange(DateTime d) =>
      _start != null &&
      _end != null &&
      !d.isBefore(_start!) &&
      !d.isAfter(_end!);

  bool _isEndpoint(DateTime d) =>
      (_start != null && d == _start) || (_end != null && d == _end);

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);

    final firstWeekday = (_month.weekday - DateTime.monday + 7) % 7;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <DateTime?>[
      ...List.filled(firstWeekday, null),
      for (var d = 1; d <= daysInMonth; d++)
        DateTime(_month.year, _month.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }

    final today = _startOfDay(DateTime.now());
    final cell = m ? 40.0 : 34.0;

    Widget dayCell(DateTime? d) {
      if (d == null) return SizedBox(width: cell, height: cell);
      final endpoint = _isEndpoint(d);
      final within = _inRange(d);
      final future = d.isAfter(today);
      final isToday = d == today;
      Color bg = const Color(0x00000000);
      Color fg = future ? c.textFaintest : c.textSecondary;
      if (endpoint) {
        bg = c.accent;
        fg = c.onAccent;
      } else if (within) {
        bg = c.selected;
        fg = c.textOnSelected;
      }
      return GestureDetector(
        onTap: future ? null : () => _tapDay(d),
        child: MouseRegion(
          cursor: future ? MouseCursor.defer : SystemMouseCursors.click,
          child: Container(
            width: cell,
            height: cell,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(Radii.chip),
              border: isToday && !endpoint
                  ? Border.all(color: c.borderStrong, width: 1)
                  : null,
            ),
            child: Text(
              '${d.day}',
              style: RelicTheme.mono(
                size: m ? 13 : 11.5,
                weight: endpoint ? FontWeight.w700 : FontWeight.w400,
                color: fg,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Month nav
          Row(
            children: [
              _IconBtn(
                icon: LucideIcons.chevronLeft,
                onTap: () => setState(() =>
                    _month = DateTime(_month.year, _month.month - 1, 1)),
              ),
              Expanded(
                child: Text(
                  '${_monthLabels[_month.month - 1]} ${_month.year}',
                  textAlign: TextAlign.center,
                  style: RelicTheme.sans(
                    size: m ? 14.5 : 12.5,
                    weight: FontWeight.w600,
                    color: c.text,
                  ),
                ),
              ),
              _IconBtn(
                icon: LucideIcons.chevronRight,
                onTap: () => setState(() =>
                    _month = DateTime(_month.year, _month.month + 1, 1)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Weekday header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final w in _weekdayLabels)
                SizedBox(
                  width: cell,
                  child: Text(
                    w,
                    textAlign: TextAlign.center,
                    style: RelicTheme.mono(size: 10, color: c.textFaintest),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Day grid
          for (var i = 0; i < cells.length; i += 7)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [for (var j = 0; j < 7; j++) dayCell(cells[i + j])],
            ),
          const SizedBox(height: 10),
          // Footer
          Row(
            children: [
              Expanded(
                child: _FooterBtn(
                  label: 'Cancel',
                  onTap: widget.onCancel,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _FooterBtn(
                  label: _start == null
                      ? 'Pick a date'
                      : (_end == null ? 'Apply (1 day)' : 'Apply'),
                  primary: true,
                  enabled: _start != null,
                  onTap: _apply,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: m ? 34 : 26,
          height: m ? 34 : 26,
          alignment: Alignment.center,
          child: Icon(icon, size: m ? 18 : 15, color: c.textSecondary),
        ),
      ),
    );
  }
}

class _FooterBtn extends StatelessWidget {
  final String label;
  final bool primary;
  final bool enabled;
  final VoidCallback onTap;
  const _FooterBtn({
    required this.label,
    this.primary = false,
    this.enabled = true,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final m = RelicTheme.isMobileOf(context);
    final on = enabled;
    final bg = primary ? (on ? c.accent : c.surface) : c.surface;
    final fg = primary
        ? (on ? c.onAccent : c.textFaintest)
        : c.textSecondary;
    return GestureDetector(
      onTap: on ? onTap : null,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
        child: Container(
          height: m ? 42 : 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(Radii.input),
            border: Border.all(color: c.border, width: 1),
          ),
          child: Text(
            label,
            style: RelicTheme.mono(
              size: m ? 13 : 11.5,
              weight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
