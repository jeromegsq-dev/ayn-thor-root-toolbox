import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart" show PlatformException;

import "package:thortoolbox/src/toolbox.dart";
import "package:thortoolbox/src/widgets.dart";

class AutoDimPage extends StatefulWidget {
  const AutoDimPage({required this.active, super.key});

  final bool active;

  @override
  State<AutoDimPage> createState() => _AutoDimPageState();
}

class _AutoDimPageState extends State<AutoDimPage> {
  static const _timeoutMin = 1;
  static const _timeoutMax = 60;
  static const _fadeStep = 100;
  static const _fadeMax = 5000;

  AutoDimConfig? _cfg;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(AutoDimPage old) {
    super.didUpdateWidget(old);

    if (widget.active && !old.active) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final cfg = await Toolbox.loadAutoDim();
    if (mounted) {
      setState(() => _cfg = cfg);
    }
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    final ok = await Toolbox.installAutoDim();
    if (!mounted) return;
    setState(() => _installing = false);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(ok ? "Service installed and running." : "Install failed — is the device rooted?")),
      );
    await _load();
  }

  Future<void> _commit(AutoDimConfig cfg) async {
    setState(() => _cfg = cfg);
    try {
      await Toolbox.saveAutoDim(cfg);
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text("Could not save: ${e.message}")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _cfg;
    if (cfg == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Automatic dimming"),
          value: cfg.enabled,
          onChanged: (on) => _commit(cfg.copyWith(enabled: on)),
        ),
        const Hint(
          "The bottom screen fades out when you stop touching it, and returns "
          "to its previous brightness as soon as you touch it again. The top "
          "screen is not affected.",
        ),
        SettingSlider(
          title: "Idle delay",
          value: cfg.timeout.toDouble().clamp(_timeoutMin.toDouble(), _timeoutMax.toDouble()),
          min: _timeoutMin.toDouble(),
          max: _timeoutMax.toDouble(),
          divisions: _timeoutMax - _timeoutMin,
          format: (v) => "${v.round()} s",
          onCommit: (v) => _commit(cfg.copyWith(timeout: v.round())),
        ),
        SettingSlider(
          title: "Minimum brightness",
          value: cfg.minPercent.toDouble(),
          max: 100,
          divisions: 100,
          format: (v) => v.round() == 0 ? "0 % (fully off)" : "${v.round()} %",
          onCommit: (v) => _commit(cfg.withMinPercent(v.round())),
        ),
        SettingSlider(
          title: "Fade duration",
          value: cfg.fade.toDouble().clamp(_fadeStep.toDouble(), _fadeMax.toDouble()),
          min: _fadeStep.toDouble(),
          max: _fadeMax.toDouble(),
          divisions: _fadeMax ~/ _fadeStep - 1,
          format: (v) => "${v.round()} ms",
          onCommit: (v) => _commit(cfg.copyWith(fade: v.round())),
        ),
        const SizedBox(height: 16),
        if (cfg.serviceRunning)
          const Hint(
            "Service running. Add the “AutoDim” tile from the quick "
            "settings panel to toggle it in one tap.",
          )
        else ...<Widget>[
          const Hint(
            "Service not found: /data/adb/service.d/bottom-autodim.sh is "
            "not running.",
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _installing ? null : _install,
            icon: _installing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
            label: Text(_installing ? "Installing…" : "Install service"),
          ),
        ],
      ],
    );
  }
}
