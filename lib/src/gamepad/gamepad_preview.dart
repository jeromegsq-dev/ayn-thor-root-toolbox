import "dart:async";

import "package:flutter/material.dart";
import "package:thortoolbox/src/gamepad/gamepad_view.dart";
import "package:thortoolbox/src/toolbox.dart";

class GamepadPreview extends StatefulWidget {
  const GamepadPreview({required this.active, super.key});

  final bool active;

  @override
  State<GamepadPreview> createState() => _GamepadPreviewState();
}

class _GamepadPreviewState extends State<GamepadPreview> with WidgetsBindingObserver {
  StreamSubscription<GamepadInput>? _sub;

  final Set<String> _pressed = <String>{};
  Map<String, double> _axes = const <String, double>{};

  String _device = "";
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync();
  }

  @override
  void didUpdateWidget(GamepadPreview old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _sync() {
    final wanted = widget.active && _resumed;
    if (wanted && _sub == null) {
      _sub = Toolbox.gamepadInputs().listen(_onInput);
    } else if (!wanted && _sub != null) {
      unawaited(_sub!.cancel());
      _sub = null;

      setState(() {
        _pressed.clear();
        _axes = const <String, double>{};
      });
    }
  }

  void _onInput(GamepadInput e) {
    setState(() {
      _device = e.device;
      final key = e.key;
      if (key != null) {
        if (e.down) {
          _pressed.add(key);
        } else {
          _pressed.remove(key);
        }
      }
      final axes = e.axes;
      if (axes != null) {
        _axes = axes;
      }
    });
  }

  List<String> get _extraKeys =>
      _pressed.where((k) => !GamepadView.drawnKeys.contains(k)).map((k) => k.replaceFirst("KEYCODE_", "")).toList()..sort();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(_device.isEmpty ? "Press anything on the controller" : _device, style: theme.textTheme.titleMedium),
        Text("What a game sees", style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Expanded(
          child: Center(
            child: GamepadView(pressed: Set<String>.of(_pressed), axes: _axes),
          ),
        ),
        if (_extraKeys.isNotEmpty)
          Wrap(
            spacing: 8,
            children: <Widget>[for (final key in _extraKeys) Chip(label: Text(key), visualDensity: VisualDensity.compact)],
          ),
        Text(
          _axisReadout(),
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: "monospace", color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  String _axisReadout() {
    final live = _axes.entries.where((e) => e.value.abs() >= 0.01).toList()..sort((a, b) => a.key.compareTo(b.key));
    if (live.isEmpty) {
      return "all axes centred";
    }
    return live.map((e) => '${e.key.replaceFirst('AXIS_', '')} ${e.value.toStringAsFixed(2)}').join("   ");
  }
}
