import "dart:async";

import "package:flutter/material.dart";
import "package:thortoolbox/src/gamepad/profile.dart";
import "package:thortoolbox/src/gamepad/profile_page.dart";
import "package:thortoolbox/src/gamepad/shortcuts.dart";
import "package:thortoolbox/src/toolbox.dart";
import "package:thortoolbox/src/widgets.dart";

/// Which controller remap applies to which installed game, on top of the
/// pad-only profiles the main Gamepad merger screen edits.
///
/// A background service (`GameProfileService`, native side) polls root for
/// the foreground app and swaps a game's own profile into `gpmerge.conf`
/// before the merger reads it, then restores whatever was live once the game
/// is no longer in front — the "Default" a game has no profile of its own
/// falls back to.
class GameProfilesPage extends StatefulWidget {
  const GameProfilesPage({required this.pads, super.key});

  final List<Pad> pads;

  @override
  State<GameProfilesPage> createState() => _GameProfilesPageState();
}

class _GameProfilesPageState extends State<GameProfilesPage> {
  GameProfilesState? _state;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final state = await Toolbox.loadGameProfiles();
    if (mounted) setState(() => _state = state);
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    await Toolbox.setGameProfilesEnabled(value: on);
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addGame() async {
    setState(() => _busy = true);
    final apps = await Toolbox.installedApps();
    if (!mounted) return;
    setState(() => _busy = false);

    final picked = await Navigator.of(
      context,
    ).push(MaterialPageRoute<InstalledApp>(builder: (_) => _AppPickerPage(apps: apps)));
    if (picked == null) return;
    await Toolbox.addGameProfile(picked.package, picked.label);
    await _load();
  }

  Future<void> _removeGame(GameProfile g) async {
    await Toolbox.removeGameProfile(g.package);
    await _load();
  }

  Future<void> _editGame(GameProfile g) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _GameEditorPage(game: g, pads: widget.pads)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _state;

    return Scaffold(
      appBar: AppBar(title: const Text("Per-game profiles")),
      body: state == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Switch automatically"),
                  value: state.enabled,
                  onChanged: _busy ? null : _toggle,
                ),
                const Hint(
                  "A background service checks which app is in front and, for "
                  "a game listed below, swaps its own mapping in before the "
                  "merger reads it — even with this app closed. Anything else "
                  "in front, including this screen, uses the mapping from the "
                  "Gamepad merger screen. It polls root the whole time this is on.",
                ),
                const SizedBox(height: 16),
                Text("Games", style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (state.games.isEmpty) const Hint("No game has its own mapping yet."),
                for (final g in state.games)
                  Card.filled(
                    margin: const EdgeInsets.only(bottom: 8),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      title: Text(g.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(g.package, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: "Remove",
                        onPressed: () => _removeGame(g),
                      ),
                      onTap: () => _editGame(g),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _addGame,
                  icon: const Icon(Icons.add),
                  label: const Text("Add a game"),
                ),
              ],
            ),
    );
  }
}

class _AppPickerPage extends StatefulWidget {
  const _AppPickerPage({required this.apps});

  final List<InstalledApp> apps;

  @override
  State<_AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends State<_AppPickerPage> {
  String _query = "";

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final filtered = query.isEmpty ? widget.apps : widget.apps.where((a) => a.label.toLowerCase().contains(query)).toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(hintText: "Search apps", border: InputBorder.none),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      body: ListView.builder(
        itemCount: filtered.length,
        itemBuilder: (context, i) {
          final app = filtered[i];
          return ListTile(
            leading: app.icon == null
                ? const Icon(Icons.android)
                : Image.memory(app.icon!, width: 32, height: 32, gaplessPlayback: true),
            title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(app.package, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.of(context).pop(app),
          );
        },
      ),
    );
  }
}

class _GameEditorPage extends StatefulWidget {
  const _GameEditorPage({required this.game, required this.pads});

  final GameProfile game;
  final List<Pad> pads;

  @override
  State<_GameEditorPage> createState() => _GameEditorPageState();
}

class _GameEditorPageState extends State<_GameEditorPage> {
  late final List<Profile> _profiles = parseConfig(widget.game.config);

  Future<bool> _save() async {
    await Toolbox.saveGameProfile(widget.game.package, renderConfig(_profiles, const <Shortcut>[]));
    return true;
  }

  Future<void> _configure(Pad pad) async {
    var profile = profileFor(_profiles, pad.name);
    if (profile == null) {
      profile = Profile(pad.name);
      _profiles.add(profile);
    }
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ProfilePage(pad: pad, profile: profile!, onSave: _save)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.game.label)),
      body: widget.pads.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Hint("No controller detected. Connect one from the Gamepad merger screen, then come back here."),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: <Widget>[
                const Hint("Captured the same way as the Gamepad merger screen — press the physical button to assign it."),
                const SizedBox(height: 8),
                for (final pad in widget.pads)
                  Card.filled(
                    margin: const EdgeInsets.only(bottom: 8),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      title: Text(pad.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _configure(pad),
                    ),
                  ),
              ],
            ),
    );
  }
}
