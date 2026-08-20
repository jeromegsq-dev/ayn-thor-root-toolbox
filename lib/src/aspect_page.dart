import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart" show PlatformException;

import "package:thortoolbox/src/toolbox.dart";
import "package:thortoolbox/src/widgets.dart";

class DisplayMode {
  const DisplayMode(this.width, this.height, this.density);

  final int width;
  final int height;

  final int density;

  String get label => "$width × $height";

  String get dpMode => "${width}x$height@60";

  String get logicalSize => "${height}x$width";
}

const List<DisplayMode> kDisplayModes = <DisplayMode>[
  DisplayMode(640, 480, 164),
  DisplayMode(800, 600, 205),
  DisplayMode(1024, 768, 262),
  DisplayMode(1280, 1024, 349),
];

class AspectPage extends StatefulWidget {
  const AspectPage({required this.active, super.key});

  final bool active;

  @override
  State<AspectPage> createState() => _AspectPageState();
}

class _AspectPageState extends State<AspectPage> with WidgetsBindingObserver {
  final _pattern = TextEditingController();
  final _dpLogical = TextEditingController();
  final _density = TextEditingController();
  final _size = TextEditingController();

  StreamSubscription<AspectState>? _states;

  bool _loaded = false;
  bool _enabled = true;
  bool _manageDp = true;
  String _dpMode = "";
  AspectState? _state;
  List<DisplayInfo> _displays = const <DisplayInfo>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fire(_load().then((_) => _onVisibility()));
  }

  @override
  void didUpdateWidget(AspectPage old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      _onVisibility();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _onVisibility(resumed: state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_states?.cancel());
    _pattern.dispose();
    _dpLogical.dispose();
    _density.dispose();
    _size.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await Toolbox.loadAspect();
    if (!mounted) {
      return;
    }
    _pattern.text = cfg.pattern;
    _dpLogical.text = cfg.dpLogical;
    _density.text = "${cfg.density}";
    _size.text = cfg.size;
    setState(() {
      _enabled = cfg.enabled;
      _manageDp = cfg.manageDp;
      _dpMode = cfg.dpMode;
      _loaded = true;
    });
  }

  void _onVisibility({bool resumed = true}) {
    final wanted = widget.active && resumed && _loaded;
    if (wanted && _states == null) {
      _states = Toolbox.aspectStates().listen((s) {
        setState(() => _state = s);
        _fire(_refreshDisplays());
      });
      _fire(Toolbox.syncAspect());
      _fire(_refreshDisplays());
    } else if (!wanted && _states != null) {
      unawaited(_states!.cancel());
      _states = null;
    }
  }

  Future<void> _refreshDisplays() async {
    final list = await Toolbox.displays();
    if (mounted) {
      setState(() => _displays = list);
    }
  }

  void _fire(Future<void> work) {
    unawaited(
      work.catchError((Object e) {
        _say(e is PlatformException ? "${e.message}" : "$e");
      }),
    );
  }

  void _say(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  DisplayMode? get _current {
    for (final mode in kDisplayModes) {
      if (mode.dpMode == _dpMode && mode.logicalSize == _size.text.trim()) {
        return mode;
      }
    }
    return null;
  }

  Future<void> _choose(DisplayMode mode) async {
    _dpMode = mode.dpMode;
    _size.text = mode.logicalSize;
    _density.text = "${mode.density}";
    setState(() {});
    await _save(quiet: true);
    _say("${mode.label} — plug the screen in, or unplug and back in.");
  }

  Future<void> _save({bool quiet = false}) async {
    final size = _size.text.trim();
    if (!RegExp(r"^\d+x\d+$").hasMatch(size)) {
      return _say("Invalid size, expected e.g. 768x1024");
    }
    final density = int.tryParse(_density.text.trim());
    if (density == null) {
      return _say("Invalid density");
    }
    final pattern = _pattern.text.trim();
    if (!await Toolbox.patternCompiles(pattern)) {
      return _say("Invalid pattern");
    }
    if (!mounted) {
      return;
    }
    final dpMode = _dpMode.trim();
    if (_manageDp && !RegExp(r"^\d+x\d+@\d+$").hasMatch(dpMode)) {
      return _say("Invalid DP mode, expected e.g. 1024x768@60");
    }
    final dpLogical = _dpLogical.text.trim();
    if (dpLogical.isNotEmpty && !RegExp(r"^\d+x\d+$").hasMatch(dpLogical)) {
      return _say("Invalid DP logical size");
    }

    await Toolbox.saveAspect(
      AspectConfig(
        enabled: _enabled,
        size: size,
        density: density,
        pattern: pattern,
        manageDp: _manageDp,
        dpMode: dpMode,
        dpLogical: dpLogical,
      ),
    );
    if (!quiet) {
      _say("Saved");
    }
  }

  Future<void> _resetNow() async {
    final ok = await Toolbox.resetAspectNow();
    _say(ok ? "Screen restored to native" : "Failed: superuser access denied?");
    await _refreshDisplays();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: _body);
  }

  Widget _body(BuildContext context, BoxConstraints box) {
    final theme = Theme.of(context);
    final state = _state;
    final current = _current;

    const gap = 12.0;
    final room = box.maxWidth - 32;
    final columns = (room / 260).floor().clamp(1, 4);
    final tile = (room - (columns - 1) * gap) / columns;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: <Widget>[
        Card.filled(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              state == null
                  ? "Waiting for the watcher…"
                  : "External screen: "
                        '${state.external ? "connected" : "absent"}\n'
                        'Forced ratio: ${state.applied ? "forced" : "native"}',
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),

        if (_enabled && state == null)
          const Hint(
            "No word from the watch service yet. It comes up when this screen "
            "is open, so give it a moment; if this stays, it did not start — "
            "switching the tool off and on again starts it.",
          ),

        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Automatic switching"),
          value: _enabled,
          onChanged: (on) {
            setState(() => _enabled = on);
            _fire(Toolbox.setAspectEnabled(value: on));
          },
        ),
        const Hint(
          "The external output mirrors the top screen, so both share one "
          "ratio: forcing 4:3 on the VGA output stretches the top screen’s own "
          "16:9 panel. That is the trade-off, not a bug. Switched off, this "
          "tool asks for no superuser access at all.",
        ),

        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Text("Screen mode", style: theme.textTheme.titleSmall),
        ),
        Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final mode in kDisplayModes)
              SizedBox(
                width: tile,
                child: _ModeTile(mode: mode, selected: mode == current, onTap: () => _choose(mode)),
              ),
          ],
        ),
        Hint(
          current == null
              ? "None of these: the size and mode below were set by hand."
              : "Applied on the next hotplug — the vendor HAL reads the mode "
                    "as the cable goes in, so a screen already plugged in has to "
                    "be unplugged and back in.",
        ),

        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(onPressed: _resetNow, child: const Text("Restore native ratio now")),
        ),

        const SizedBox(height: 16),
        ExpansionTile(
          title: const Text("Advanced"),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          children: <Widget>[
            SettingField(label: "Forced logical size", controller: _size),
            const Hint(
              "In the panel’s native (portrait) coordinates: 768x1024 renders "
              "as 1024x768 in landscape.",
            ),
            SettingField(label: "Density", controller: _density, keyboardType: TextInputType.number),
            SettingField(label: "External screen name pattern", controller: _pattern),
            const Hint(
              "Screen-2 (the bottom panel) also carries FLAG_PRESENTATION, so "
              "external screens are matched by name instead.",
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("Manage the DP output"),
              value: _manageDp,
              onChanged: (on) {
                setState(() => _manageDp = on);
                _fire(Toolbox.setManageDp(value: on));
              },
            ),
            const Hint(
              "Sets the persist.vendor.dp.* props the vendor HAL reads during "
              "hotplug. Without them a HDMI-to-VGA adapter advertises a "
              "generic 1080p EDID and an older VGA screen shows “out of "
              "range”.",
            ),
            SettingField(label: "DP display logical size", controller: _dpLogical),
            const Hint(
              "Empty = native. Has no effect while the output mirrors the top "
              "screen; only useful in extended mode.",
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: _save, child: const Text("Save")),
            ),
            const SizedBox(height: 24),
            Text("Displays seen by the app:", style: theme.textTheme.bodySmall),
            SelectableText(
              _displays.map((d) => d.toString()).join("\n"),
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: "monospace", color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.mode, required this.selected, required this.onTap});

  final DisplayMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card.filled(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(mode.label, style: theme.textTheme.titleMedium),
              Text(
                "60 Hz",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
