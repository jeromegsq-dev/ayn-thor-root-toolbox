import "dart:async";

import "package:flutter/material.dart";
import "package:thortoolbox/src/gamepad/profile.dart";
import "package:thortoolbox/src/gamepad/watch.dart";
import "package:thortoolbox/src/toolbox.dart";
import "package:thortoolbox/src/widgets.dart";

class ProfilePage extends StatefulWidget {
  const ProfilePage({required this.pad, required this.profile, required this.onSave, super.key});

  final Pad pad;
  final Profile profile;

  final Future<bool> Function() onSave;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  Profile get _profile => widget.profile;

  Map<String, String> _mappings(PadControl kind) => kind == PadControl.button ? _profile.buttons : _profile.axes;

  Future<void> _change(void Function() edit) async {
    setState(edit);
    await widget.onSave();
  }

  Future<void> _assign(PadTarget target) async {
    final button = target.kind == PadControl.button;
    final source = await _capture(
      title: target.label,
      message: button
          ? "Press the button on ${widget.pad.name} that should act as "
                "“${target.label}”."
          : "Move the stick or trigger on ${widget.pad.name} that should act "
                "as “${target.label}”, all the way over.",
      start: () => button ? PadWatch.button(widget.pad.name) : PadWatch.axis(widget.pad.name),
      nothing: button ? "No button detected." : "No movement detected.",
    );
    if (source == null) {
      return;
    }
    await _change(() {
      final map = _mappings(target.kind);

      map.removeWhere((_, to) => to == target.code);
      map[source] = target.code;
    });
  }

  Future<void> _clear(PadTarget target) => _change(() => _mappings(target.kind).removeWhere((_, to) => to == target.code));

  Future<String?> _capture({
    required String title,
    required String message,
    required PadWatch Function() start,
    required String nothing,
  }) async {
    final code = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CaptureDialog(title: title, message: message, start: start),
    );
    if (code == null && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(nothing)));
    }
    return code;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.pad.name)),
      body: LayoutBuilder(builder: _body),
    );
  }

  Widget _body(BuildContext context, BoxConstraints box) {
    final theme = Theme.of(context);

    const gap = 12.0;
    final room = box.maxWidth - 32;
    final columns = (room / 340).floor().clamp(1, 3);
    final tile = (room - (columns - 1) * gap) / columns;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: <Widget>[
        Text("Face button layout", style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(value: "xbox", label: Text("Standard")),
              ButtonSegment<String>(value: "nintendo", label: Text("Swapped")),
            ],
            selected: <String>{if (_profile.preset != null) _profile.preset!},
            emptySelectionAllowed: true,
            onSelectionChanged: (s) => _change(() {
              _profile.preset = s.isEmpty ? null : s.first;
            }),
          ),
        ),
        const Hint("Swapped exchanges A/B and X/Y."),
        for (final section in kPadSections) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: Text(section.title, style: theme.textTheme.titleSmall),
          ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final target in section.targets)
                SizedBox(
                  width: tile,
                  child: _TargetTile(
                    target: target,
                    source: sourceFor(_mappings(target.kind), target.code),
                    onAssign: () => _assign(target),
                    onClear: () => _clear(target),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        _Advanced(profile: _profile, padName: widget.pad.name, change: _change, capture: _capture),
      ],
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({required this.target, required this.source, required this.onAssign, required this.onClear});

  final PadTarget target;

  final String? source;

  final VoidCallback onAssign;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final from = source;

    return Card.filled(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,

      color: from == null ? null : theme.colorScheme.primaryContainer,
      child: ListTile(
        dense: true,
        title: Text(target.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          from == null ? "The pad’s own" : "From $from",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: from == null ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onPrimaryContainer,
          ),
        ),
        trailing: from == null
            ? const Icon(Icons.add, size: 20)
            : IconButton(icon: const Icon(Icons.close), tooltip: "Back to the pad’s own", onPressed: onClear),
        onTap: onAssign,
      ),
    );
  }
}

class _Advanced extends StatelessWidget {
  const _Advanced({required this.profile, required this.padName, required this.change, required this.capture});

  final Profile profile;
  final String padName;
  final Future<void> Function(void Function()) change;
  final Future<String?> Function({
    required String title,
    required String message,
    required PadWatch Function() start,
    required String nothing,
  })
  capture;

  Map<String, String> get _offMap => <String, String>{
    for (final e in <MapEntry<String, String>>[...profile.buttons.entries, ...profile.axes.entries])
      if (!kStandardTargets.contains(e.value)) e.key: e.value,
  };

  @override
  Widget build(BuildContext context) {
    final extras = _offMap;

    return ExpansionTile(
      title: const Text("Advanced"),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      children: <Widget>[
        for (final entry in extras.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text("${entry.key}  →  ${entry.value}"),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => change(() {
                profile.buttons.remove(entry.key);
                profile.axes.remove(entry.key);
              }),
            ),
          ),
        for (final axis in profile.inverts.toList())
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text("Inverted: ${axisLabel(axis)}"),
            trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => change(() => profile.inverts.remove(axis))),
          ),
        for (final entry in profile.deadzones.entries.toList())
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              "Dead zone ${deadzonePercent(entry.key, entry.value)}%:"
              " ${axisLabel(entry.key)}",
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => change(() => profile.deadzones.remove(entry.key)),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton(onPressed: () => _invert(context), child: const Text("Invert an axis…")),
            OutlinedButton(onPressed: () => _deadzone(context), child: const Text("Set a dead zone…")),
            OutlinedButton(onPressed: () => _toHome(context), child: const Text("Send to Android Home…")),
            OutlinedButton(onPressed: () => _disable(context), child: const Text("Switch a button off…")),
          ],
        ),
        const Hint(
          "Inverting and dead zones are the daemon’s, and apply to the axis "
          "after it has been remapped.",
        ),
      ],
    );
  }

  Future<void> _invert(BuildContext context) async {
    final axis = await _pick<String>(context, title: "Invert which axis?", items: kAxes, label: axisLabel);
    if (axis != null) {
      await change(() => profile.inverts.add(axis));
    }
  }

  Future<void> _deadzone(BuildContext context) async {
    final axis = await _pick<String>(context, title: "Dead zone on which axis?", items: kAxes, label: axisLabel);
    if (axis == null || !context.mounted) {
      return;
    }
    const percents = <int>[0, 3, 5, 8, 12, 20];
    final percent = await _pick<int>(context, title: "Dead zone for ${axisLabel(axis)}", items: percents, label: (v) => "$v%");
    if (percent == null) {
      return;
    }
    await change(() {
      if (percent == 0) {
        profile.deadzones.remove(axis);
      } else {
        profile.deadzones[axis] = deadzoneUnits(axis, percent);
      }
    });
  }

  Future<void> _toHome(BuildContext context) async {
    final source = await capture(
      title: "Send to Android Home",
      message:
          "Press the button on $padName that should go to the Home "
          "screen instead of the game.",
      start: () => PadWatch.button(padName),
      nothing: "No button detected.",
    );
    if (source != null) {
      await change(() => profile.buttons[source] = "KEY_HOME");
    }
  }

  Future<void> _disable(BuildContext context) async {
    final source = await capture(
      title: "Switch a button off",
      message: "Press the button on $padName that should stop doing anything.",
      start: () => PadWatch.button(padName),
      nothing: "No button detected.",
    );
    if (source != null) {
      await change(() => profile.buttons[source] = "none");
    }
  }

  Future<T?> _pick<T>(
    BuildContext context, {
    required String title,
    required List<T> items,
    required String Function(T value) label,
  }) => showDialog<T>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: <Widget>[
        for (final item in items) SimpleDialogOption(onPressed: () => Navigator.pop(context, item), child: Text(label(item))),
      ],
    ),
  );
}

class _CaptureDialog extends StatefulWidget {
  const _CaptureDialog({required this.title, required this.message, required this.start});

  final String title;
  final String message;
  final PadWatch Function() start;

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  late final PadWatch _watch;

  @override
  void initState() {
    super.initState();
    _watch = widget.start();
    unawaited(
      _watch.result.then((code) {
        if (mounted) {
          Navigator.pop(context, code);
        }
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_watch.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Row(
      children: <Widget>[
        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 16),
        Expanded(child: Text(widget.message)),
      ],
    ),
    actions: <Widget>[TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel"))],
  );
}
