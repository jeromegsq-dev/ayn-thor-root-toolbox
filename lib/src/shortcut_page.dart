import "dart:async";

import "package:flutter/material.dart";

import "package:thortoolbox/src/gamepad/profile.dart";
import "package:thortoolbox/src/gamepad/shortcuts.dart";
import "package:thortoolbox/src/toolbox.dart";
import "package:thortoolbox/src/widgets.dart";

class ShortcutPage extends StatefulWidget {
  const ShortcutPage({required this.active, super.key});

  final bool active;

  @override
  State<ShortcutPage> createState() => _ShortcutPageState();
}

class _ShortcutPageState extends State<ShortcutPage> {
  List<Profile> _profiles = <Profile>[];
  List<Shortcut> _shortcuts = <Shortcut>[];

  bool _rooted = false;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(ShortcutPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.active && !oldWidget.active) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final state = await Toolbox.gamepadState();
      if (!mounted) {
        return;
      }
      setState(() {
        _rooted = state.rooted;
        _profiles = parseConfig(state.config);
        _shortcuts = parseShortcuts(state.config);
        _loaded = true;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = "$e";
          _loaded = true;
        });
      }
    }
  }

  Future<void> _save() async {
    final ok = await Toolbox.writeGamepadConfig(renderConfig(_profiles, _shortcuts));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text("Could not write the config file.")));
    }
  }

  Shortcut? _boundTo(ShortcutAction action) {
    for (final s in _shortcuts) {
      if (s.command == action.command) {
        return s;
      }
    }
    return null;
  }

  Future<void> _record(ShortcutAction action) async {
    final combo = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecordDialog(action: action, profiles: _profiles),
    );
    if (combo == null || combo.isEmpty) {
      return;
    }
    setState(() {
      _shortcuts = <Shortcut>[
        for (final s in _shortcuts)
          if (s.command != action.command && !_sameCombo(s.combo, combo)) s,
        Shortcut(combo, action.command),
      ];
    });
    await _save();
  }

  Future<void> _clear(ShortcutAction action) async {
    setState(() {
      _shortcuts = <Shortcut>[
        for (final s in _shortcuts)
          if (s.command != action.command) s,
      ];
    });
    await _save();
  }

  static bool _sameCombo(List<String> a, List<String> b) => a.length == b.length && a.toSet().containsAll(b);

  List<Shortcut> get _custom => _shortcuts.where((s) => s.action == null).toList();

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Retry(text: "Failed while talking to root:\n\n$_error", onRetry: _load);
    }
    if (!_rooted) {
      return _Retry(text: "Root access denied.\n\nGrant it in Magisk, then try again.", onRetry: _load);
    }

    final groups = <String, List<ShortcutAction>>{};
    for (final a in kShortcutActions) {
      groups.putIfAbsent(a.group, () => <ShortcutAction>[]).add(a);
    }

    return LayoutBuilder(builder: (context, box) => _list(context, box, groups));
  }

  Widget _list(BuildContext context, BoxConstraints box, Map<String, List<ShortcutAction>> groups) {
    final theme = Theme.of(context);

    const gap = 12.0;
    final room = box.maxWidth - 32;
    final columns = (room / 340).floor().clamp(1, 3);
    final tile = (room - (columns - 1) * gap) / columns;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: <Widget>[
        const Hint(
          "Hold a combination on the controller and it runs on the device, "
          "even inside a game — the daemon catches it before Android does.",
        ),
        const Hint(
          "The button you hold first keeps its own job: tap it and the game "
          "gets a normal press, hold it and the game gets nothing — nor "
          "anything else you press while it is down. So View, or any button "
          "you actually use, is a fair modifier. Guide is not, on this device "
          "— the AYN pads route their system buttons through Home and Back "
          "instead, so nothing may send it at all.",
        ),
        const Hint(
          "A stick direction works differently: pushing it still reaches the "
          "game exactly as it always did — the shortcut only fires once it is "
          "past 90% of the way over, on top of that, not instead of it. Hold "
          "it that far to record one, the same as a button.",
        ),
        for (final entry in groups.entries) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: Text(entry.key, style: theme.textTheme.titleSmall),
          ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final action in entry.value)
                SizedBox(
                  width: tile,
                  child: _ActionTile(
                    action: action,
                    bound: _boundTo(action),
                    onRecord: () => _record(action),
                    onClear: () => _clear(action),
                  ),
                ),
            ],
          ),
        ],
        if (_custom.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 24, bottom: 8),
            child: Text("Written by hand", style: theme.textTheme.titleSmall),
          ),
          for (final s in _custom)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(comboLabel(s.combo)),
              subtitle: Text(
                s.command,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: "monospace", color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action, required this.bound, required this.onRecord, required this.onClear});

  final ShortcutAction action;
  final Shortcut? bound;
  final VoidCallback onRecord;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final combo = bound?.combo;

    return Card.filled(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: combo == null ? null : theme.colorScheme.primaryContainer,
      child: ListTile(
        dense: true,
        title: Text(action.label),
        subtitle: Text(
          combo == null ? "No combination" : comboLabel(combo),
          style: theme.textTheme.bodySmall?.copyWith(
            color: combo == null ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onPrimaryContainer,
          ),
        ),
        trailing: combo == null
            ? const Icon(Icons.add, size: 20)
            : IconButton(icon: const Icon(Icons.close), tooltip: "Remove", onPressed: onClear),
        onTap: onRecord,
      ),
    );
  }
}

class _RecordDialog extends StatefulWidget {
  const _RecordDialog({required this.action, required this.profiles});

  final ShortcutAction action;

  final List<Profile> profiles;

  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  late final ComboRecorder _recorder;

  @override
  void initState() {
    super.initState();
    _recorder = ComboRecorder(profiles: widget.profiles)..onChanged = () => setState(() {});
    unawaited(
      _recorder.result.then((combo) {
        if (mounted) {
          Navigator.pop(context, combo);
        }
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_recorder.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pressed = _recorder.pressed;

    return AlertDialog(
      title: Text(widget.action.label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text("Hold the buttons or stick you want, then let go."),
          const SizedBox(height: 16),
          Text(pressed.isEmpty ? "Waiting…" : comboLabel(pressed), style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
      actions: <Widget>[TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel"))],
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text("Retry")),
        ],
      ),
    ),
  );
}
