import "dart:async";

import "package:flutter/material.dart";
import "package:thortoolbox/src/gamepad/game_profiles_page.dart";
import "package:thortoolbox/src/gamepad/gamepad_preview.dart";
import "package:thortoolbox/src/gamepad/profile.dart";
import "package:thortoolbox/src/gamepad/profile_page.dart";
import "package:thortoolbox/src/gamepad/shortcuts.dart";
import "package:thortoolbox/src/toolbox.dart";
import "package:thortoolbox/src/widgets.dart";

class GamepadPage extends StatefulWidget {
  const GamepadPage({required this.active, super.key});

  final bool active;

  @override
  State<GamepadPage> createState() => GamepadPageState();
}

class GamepadPageState extends State<GamepadPage> {
  GamepadState? _state;
  List<Profile> _profiles = <Profile>[];

  List<Shortcut> _shortcuts = <Shortcut>[];
  String? _error;
  bool _busy = false;

  bool get busy => _busy;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      unawaited(refresh());
    }
  }

  @override
  void didUpdateWidget(GamepadPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.active && !oldWidget.active && _state == null && !_busy) {
      unawaited(refresh());
    }
  }

  Future<void> refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await Toolbox.gamepadState();
      if (!mounted) {
        return;
      }
      setState(() {
        _state = state;
        _profiles = parseConfig(state.config);
        _shortcuts = parseShortcuts(state.config);
        _busy = false;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = "$e";
          _busy = false;
        });
      }
    }
  }

  Future<bool> _save() async {
    final ok = await Toolbox.writeGamepadConfig(renderConfig(_profiles, _shortcuts));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Could not write the config file.")));
    }
    return ok;
  }

  Future<void> _hideExtras() async {
    final s = _state;
    if (s == null) {
      return;
    }
    final ok = await Toolbox.setExclusions(<String>{...s.excluded, ...s.phantoms}.toList());
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(ok ? "Hidden from the next boot onwards. Reboot to apply." : "Could not write the exclusion list."),
        ),
      );
    await refresh();
  }

  Future<void> _openGameProfiles() async {
    final s = _state;
    if (s == null) {
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GameProfilesPage(pads: s.pads)));
  }

  Future<void> _configure(Pad pad) async {
    var profile = profileFor(_profiles, pad.name);
    if (profile == null) {
      profile = Profile(pad.name);
      _profiles.add(profile);
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfilePage(pad: pad, profile: profile!, onSave: _save),
      ),
    );
    await refresh();
  }

  @override
  Widget build(BuildContext context) {
    final controllers = _Controllers(
      state: _state,
      profiles: _profiles,
      error: _error,
      busy: _busy,
      onRetry: refresh,
      onConfigure: _configure,
      onHide: _hideExtras,
      onGameProfiles: _openGameProfiles,
    );
    final preview = GamepadPreview(active: widget.active);

    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 720) {
          return Column(
            children: <Widget>[
              Expanded(child: controllers),
              const Divider(height: 1),
              Expanded(
                child: Padding(padding: const EdgeInsets.all(16), child: preview),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(flex: 5, child: controllers),
            const VerticalDivider(width: 1),
            Expanded(
              flex: 6,
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), child: preview),
            ),
          ],
        );
      },
    );
  }
}

class _Controllers extends StatelessWidget {
  const _Controllers({
    required this.state,
    required this.profiles,
    required this.error,
    required this.busy,
    required this.onRetry,
    required this.onConfigure,
    required this.onHide,
    required this.onGameProfiles,
  });

  final GamepadState? state;
  final List<Profile> profiles;
  final String? error;
  final bool busy;
  final VoidCallback onRetry;
  final void Function(Pad pad) onConfigure;
  final VoidCallback onHide;
  final VoidCallback onGameProfiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = state;

    if (busy && s == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return _Message(text: "Failed while talking to root:\n\n$error", onRetry: onRetry);
    }
    if (s == null) {
      return const SizedBox.shrink();
    }
    if (!s.rooted) {
      return _Message(text: "Root access denied.\n\nGrant it in Magisk, then try again.", onRetry: onRetry);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        Text(s.running ? "${s.pads.length} controller(s) merged" : "Daemon not running", style: theme.textTheme.titleMedium),
        if (!s.running) const Hint("Mappings will apply next time it starts."),
        const SizedBox(height: 8),
        if (s.pads.isEmpty) const Hint("No controller detected. Connect one and refresh."),
        for (final pad in s.pads)
          Card.filled(
            margin: const EdgeInsets.only(bottom: 8),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              title: Text(pad.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onConfigure(pad),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onGameProfiles,
          icon: const Icon(Icons.videogame_asset_outlined),
          label: const Text("Per-game profiles"),
        ),
        const SizedBox(height: 24),
        _SeenByGames(state: s, onHide: onHide),
      ],
    );
  }
}

class _SeenByGames extends StatelessWidget {
  const _SeenByGames({required this.state, required this.onHide});

  final GamepadState state;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phantoms = state.phantoms;
    final pending = state.phantomsPending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text("Seen by games", style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        if (state.androidPads.isEmpty) const Hint("Android sees no controller at all."),
        for (final name in state.androidPads)
          _Line(name: name, merged: name == state.merged, pending: name != state.merged && !state.excluded.contains(name)),
        const SizedBox(height: 4),
        if (phantoms.isEmpty)
          const Hint("Only the merged pad — nothing else is counted.")
        else if (pending) ...<Widget>[
          Hint(
            "${phantoms.length} extra controller(s) counted. Games that "
            "bind a player to a controller number will pick the wrong one.",
          ),
          FilledButton.tonalIcon(
            onPressed: onHide,
            icon: const Icon(Icons.visibility_off_outlined),
            label: const Text("Hide them from Android"),
          ),
        ] else
          const Hint("Already on the exclusion list — reboot to apply."),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.name, required this.merged, required this.pending});

  final String name;
  final bool merged;

  final bool pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = merged
        ? theme.colorScheme.primary
        : pending
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Icon(merged ? Icons.check_circle_outline : Icons.warning_amber_outlined, size: 18, color: colour),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: colour),
            ),
          ),
          if (merged) Text("merged", style: theme.textTheme.bodySmall?.copyWith(color: colour)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
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
}
