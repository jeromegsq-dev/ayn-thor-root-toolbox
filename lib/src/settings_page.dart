import "package:flutter/material.dart";

import "package:thortoolbox/src/aspect_page.dart";
import "package:thortoolbox/src/autodim_page.dart";
import "package:thortoolbox/src/gamepad/gamepad_page.dart";
import "package:thortoolbox/src/nso/nso_page.dart";
import "package:thortoolbox/src/shortcut_page.dart";

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _Tool {
  const _Tool(this.title, this.icon, this.builder, {this.actions});

  final String title;
  final IconData icon;

  // ignore: avoid_positional_boolean_parameters
  final Widget Function(bool active) builder;

  final List<Widget> Function()? actions;
}

class _SettingsPageState extends State<SettingsPage> {
  final _gamepad = GlobalKey<GamepadPageState>();

  late final List<_Tool> _tools = <_Tool>[
    _Tool("AutoDim bottom screen", Icons.brightness_4_outlined, (active) => AutoDimPage(active: active)),
    _Tool("4:3 on external screen", Icons.aspect_ratio_outlined, (active) => AspectPage(active: active)),
    _Tool(
      "Gamepad merger",
      Icons.sports_esports_outlined,
      (active) => GamepadPage(key: _gamepad, active: active),
      actions: () => <Widget>[
        IconButton(icon: const Icon(Icons.refresh), tooltip: "Refresh", onPressed: () => _gamepad.currentState?.refresh()),
      ],
    ),
    _Tool("Shortcut", Icons.keyboard_command_key_outlined, (active) => ShortcutPage(active: active)),
    _Tool("NSO GameCube pad", Icons.bluetooth_searching, (active) => NsoPage(active: active)),
  ];

  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tool = _tools[_index];

    return Scaffold(
      appBar: AppBar(title: Text(tool.title), actions: tool.actions?.call()),
      drawer: NavigationDrawer(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          Navigator.pop(context);
        },
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 16, 16),
            child: Text("AYN Thor Toolbox", style: Theme.of(context).textTheme.titleLarge),
          ),
          for (final entry in _tools) NavigationDrawerDestination(icon: Icon(entry.icon), label: Text(entry.title)),
        ],
      ),

      body: IndexedStack(
        index: _index,
        children: <Widget>[for (var i = 0; i < _tools.length; i++) _tools[i].builder(i == _index)],
      ),
    );
  }
}
