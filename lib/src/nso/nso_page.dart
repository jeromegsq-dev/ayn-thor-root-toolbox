import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:thortoolbox/src/toolbox.dart";

/// Bring-up screen for the NSO GameCube pad over Bluetooth LE.
///
/// The pad speaks a proprietary Nintendo GATT protocol that nothing on Android
/// recognises, so it has to be walked through a fixed init sequence before it
/// emits anything. Whether Android's GATT client can do that at all is the
/// open question — BlueZ cannot, Windows can — so this screen is built to
/// answer it: the sequence runs step by step in the log, every attribute the
/// pad exposes is listed with its handle, and input is shown raw as well as
/// parsed. A run that fails still says exactly where it stopped and what the
/// pad actually offers.
class NsoPage extends StatefulWidget {
  const NsoPage({required this.active, super.key});

  final bool active;

  @override
  State<NsoPage> createState() => _NsoPageState();
}

enum _WizMode { off, running, done }

class _NsoPageState extends State<NsoPage> {
  StreamSubscription<Map<String, Object?>>? _sub;

  final _devices = <String, _Device>{};
  final _log = <String>[];
  final _attrs = <_Attr>[];

  String _state = "idle";
  String? _error;
  _Input? _input;
  String? _connectedTo;

  /// Whether a connected pad is also published as an evdev node for gpmerge to
  /// merge — which is what makes it work in games rather than only here.
  bool _publish = true;

  /// The pad remembered from a previous session, offered as a one-tap
  /// reconnect so a returning user never has to scan for the same pad twice.
  NsoKnownPad? _known;

  /// 0..100, persisted regardless of whether a pad is connected right now —
  /// it is a preference about the pad, not a property of the live session.
  int _rumbleStrength = 100;

  // ---- Mapping wizard ---------------------------------------------------
  //
  // Walks every control in turn and asks it to be held for three seconds,
  // rather than trusting protocol notes or a hand-typed hex dump: the pad's
  // own reports have twice turned out to disagree with both. Holding is what
  // tells a real press from noise — a single frame with a bit set proves
  // nothing on its own.

  _WizMode _wizMode = _WizMode.off;
  _Input? _wizBaseline;
  int _wizIndex = 0;
  String? _wizCandidate;
  DateTime? _wizCandidateSince;
  final _wizResults = <String, String>{};

  static const _wizTargets = <String>[
    "A", "B", "X", "Y",
    "L1", "R1", "Z (extra, above R)", "ZL (extra, above L)",
    "Start", "Select / Capture", "Home / Guide", "C (GameChat)",
    "D-Pad Up", "D-Pad Down", "D-Pad Left", "D-Pad Right",
    "Left Stick — Up", "Left Stick — Down", "Left Stick — Left", "Left Stick — Right",
    "Right Stick — Up", "Right Stick — Down", "Right Stick — Left", "Right Stick — Right",
    "Left Trigger (LT)", "Right Trigger (RT)",
  ];

  void _startWizard() {
    setState(() {
      _wizMode = _WizMode.running;
      _wizBaseline = _input ?? const _Input(buttons: 0, bits: <int>[], lx: 2048, ly: 2048, rx: 2048, ry: 2048, lt: 0, rt: 0, hex: "");
      _wizIndex = 0;
      _wizCandidate = null;
      _wizCandidateSince = null;
      _wizResults.clear();
    });
  }

  void _skipWizardTarget() {
    setState(() {
      _wizIndex++;
      _wizCandidate = null;
      _wizCandidateSince = null;
      if (_wizIndex >= _wizTargets.length) _wizMode = _WizMode.done;
    });
  }

  void _cancelWizard() => setState(() => _wizMode = _WizMode.off);

  /// Called from inside the `setState` in [_onEvent] — mutates fields
  /// directly rather than wrapping its own, since the caller's rebuild
  /// already covers it.
  void _wizOnInput(_Input input) {
    final base = _wizBaseline;
    if (base == null || _wizIndex >= _wizTargets.length) return;

    final sig = _detectSignal(input, base);
    final now = DateTime.now();
    if (sig != _wizCandidate) {
      _wizCandidate = sig;
      _wizCandidateSince = sig == null ? null : now;
      return;
    }
    if (sig != null && _wizCandidateSince != null && now.difference(_wizCandidateSince!) >= const Duration(seconds: 3)) {
      _wizResults[_wizTargets[_wizIndex]] = sig;
      _wizIndex++;
      _wizCandidate = null;
      _wizCandidateSince = null;
      if (_wizIndex >= _wizTargets.length) _wizMode = _WizMode.done;
    }
  }

  /// The one thing that changed since [base], as a key comparable with `==`:
  /// `btn:<bit>`, `axis:<lx|ly|rx|ry>:<+|->` or `trig:<lt|rt>`. Null if
  /// nothing changed enough to be sure, or more than one thing did — holding
  /// a button steady should never look ambiguous.
  static String? _detectSignal(_Input i, _Input base) {
    const stickThreshold = 900; // out of a ~2048 half-range
    const triggerThreshold = 60; // out of 0..255

    final bits = i.bits.where((b) => !base.bits.contains(b)).toList();
    if (bits.length > 1) return null;

    final hits = <String>[];
    void axis(String name, int v, int b) {
      final d = v - b;
      if (d.abs() > stickThreshold) hits.add("axis:$name:${d < 0 ? "-" : "+"}");
    }

    axis("lx", i.lx, base.lx);
    axis("ly", i.ly, base.ly);
    axis("rx", i.rx, base.rx);
    axis("ry", i.ry, base.ry);
    if (i.lt - base.lt > triggerThreshold) hits.add("trig:lt");
    if (i.rt - base.rt > triggerThreshold) hits.add("trig:rt");

    if (bits.length + hits.length != 1) return null;
    return bits.isNotEmpty ? "btn:${bits.single}" : hits.single;
  }

  /// The raw signal key, decoded into the byte/bit terms `nsofeed.c`'s
  /// `B2`/`B3`/`B4` macros are written against.
  static String _describeSignal(String key) {
    if (key.startsWith("btn:")) {
      final bit = int.parse(key.substring(4));
      final int byteIndex;
      final int n;
      if (bit >= 16) {
        byteIndex = 4;
        n = bit - 16;
      } else if (bit >= 8) {
        byteIndex = 5;
        n = bit - 8;
      } else {
        byteIndex = 6;
        n = bit;
      }
      return "byte $byteIndex bit $n  (word bit $bit, 0x${(1 << n).toRadixString(16).padLeft(2, "0")})";
    }
    if (key.startsWith("axis:")) {
      final parts = key.split(":");
      return "stick axis ${parts[1]}, ${parts[2] == "+" ? "positive" : "negative"} direction";
    }
    if (key.startsWith("trig:")) return "trigger ${key.substring(5)}";
    return key;
  }

  @override
  void initState() {
    super.initState();
    // Attaches to a session already running rather than starting anything: the
    // pad outlives this screen, so arriving here should find it, not disturb it.
    if (widget.active) _listen(watch: true);
    unawaited(
      Toolbox.nsoKnownPad().then((known) {
        if (mounted) setState(() => _known = known);
      }),
    );
    unawaited(
      Toolbox.nsoRumbleStrength().then((strength) {
        if (mounted) setState(() => _rumbleStrength = strength);
      }),
    );
  }

  void _setRumbleStrength(int percent) {
    setState(() => _rumbleStrength = percent);
    unawaited(Toolbox.setNsoRumbleStrength(percent));
  }

  void _testRumble() => unawaited(Toolbox.testNsoRumble());

  @override
  void didUpdateWidget(NsoPage old) {
    super.didUpdateWidget(old);
    // Detaching is all that happens on the way out — a scan is a real radio cost
    // and worth stopping, but the connection is the point and stays up.
    if (!widget.active && old.active) {
      _detach();
    } else if (widget.active && !old.active) {
      _listen(watch: true);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _detach() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// Ends the session outright, which closing the screen deliberately does not.
  void _disconnect() {
    unawaited(Toolbox.nsoDisconnect());
    // Also drops the watch subscription: leaving it up kept "Merge into the
    // AYN pad" permanently disabled, since nothing else ever nulled _sub —
    // not even reopening the screen, which reattaches with watch:true right
    // in didUpdateWidget, before a tap could land.
    unawaited(_sub?.cancel());
    _sub = null;
    setState(() {
      _connectedTo = null;
      _input = null;
      _state = "idle";
    });
  }

  /// [watch] attaches to whatever is already running; the platform replays the
  /// session's log so a reopened screen is not blank. [auto] scans and then
  /// connects to the pad without waiting for a row to be picked.
  void _listen({String? address, bool watch = false, bool auto = false}) {
    unawaited(_sub?.cancel());
    setState(() {
      _error = null;
      if (!watch) {
        _input = null;
        _attrs.clear();
        _log.clear();
        _connectedTo = address;
        _state = address == null ? "scanning" : "connecting";
        if (address == null) _devices.clear();
      }
    });
    _sub = Toolbox.nsoEvents(address: address, publish: _publish, watch: watch, auto: auto).listen(
      _onEvent,
      onError: (Object e) {
        if (mounted) setState(() => _error = "$e");
      },
    );
  }

  void _onEvent(Map<String, Object?> event) {
    if (!mounted) return;
    setState(() {
      switch (event["kind"]) {
        case "device":
          final address = event["address"]! as String;
          _devices[address] = _Device(
            address: address,
            name: (event["name"] as String?) ?? "",
            rssi: (event["rssi"] as int?) ?? 0,
            likely: (event["likely"] as bool?) ?? false,
          );
        case "log":
          _log.add(event["message"]! as String);
        case "attr":
          _attrs.add(
            _Attr(
              handle: (event["handle"] as int?) ?? 0,
              uuid: (event["uuid"] as String?) ?? "",
              props: event["props"] as int?,
              what: (event["what"] as String?) ?? "",
            ),
          );
        case "session":
          // Sent when a screen attaches: says which pad is running, if any, so
          // a reopened page shows the session instead of an empty device list.
          _connectedTo = event["address"] as String?;
          if (event["active"] != true) _state = "idle";
        case "state":
          _state = event["state"]! as String;
        case "error":
          _error = event["message"] as String?;
        case "input":
          _input = _Input.fromMap(event);
          if (_wizMode == _WizMode.running) _wizOnInput(_input!);
        case "raw":
          _log.add("raw ${event["hex"]}");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Tight at the bottom: with a pad connected the header, the live report
      // card and the tabs together want every pixel of a 16:9 landscape screen.
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              // The one button that does the whole thing: come back to the pad
              // already known, or scan and connect to whatever answers looking
              // like one. The manual scan below stays for a pad it guesses
              // wrong about, and for reading what is actually advertising.
              FilledButton.icon(
                onPressed: _state == "scanning" ? null : () => _listen(auto: true),
                icon: const Icon(Icons.bolt),
                label: const Text("Auto connect"),
              ),
              OutlinedButton.icon(
                onPressed: _state == "scanning" ? null : () => _listen(),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text("Scan"),
              ),
              OutlinedButton.icon(
                // Ends the session for good. Leaving the screen no longer does
                // this, so there has to be a way to say it deliberately.
                onPressed: _connectedTo == null && _state == "idle" ? null : _disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text("Disconnect"),
              ),
              OutlinedButton.icon(
                // For the run where the pad keeps chasing its lamps around
                // even though it is connected and sending input.
                onPressed: _state == "connected" ? () => unawaited(Toolbox.nsoPlayerLed()) : null,
                icon: const Icon(Icons.looks_one_outlined),
                label: const Text("Player 1 LED"),
              ),
              OutlinedButton.icon(
                onPressed: _connectedTo == null ? null : _startWizard,
                icon: const Icon(Icons.rule),
                label: const Text("Mapping wizard"),
              ),
              Text(_state, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text("Merge into the AYN pad"),
            value: _publish,
            // Taken at connect time, so flipping it mid-session would say one
            // thing and do another — but only an actual live session is that
            // risk. Gating this on _sub instead once left it permanently
            // stuck off: opening the screen alone starts a watch attach and
            // sets _sub, whether or not anything is even connected.
            onChanged: _state == "connected" ? null : (on) => setState(() => _publish = on),
          ),
          Row(
            children: <Widget>[
              const Icon(Icons.vibration, size: 20),
              const SizedBox(width: 12),
              const Text("Rumble"),
              Expanded(
                child: Slider(
                  // The pad has no waveform, only on/off — this is a PWM duty
                  // cycle faked in the app, not a hardware intensity — so 0
                  // reads as "off" rather than a very faint buzz.
                  value: _rumbleStrength.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: _rumbleStrength == 0 ? "Off" : "$_rumbleStrength%",
                  onChanged: (v) => _setRumbleStrength(v.round()),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  _rumbleStrength == 0 ? "Off" : "$_rumbleStrength%",
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.play_circle_outline),
                tooltip: "Test",
                onPressed: _state == "connected" && _rumbleStrength > 0 ? _testRumble : null,
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text("$_error", style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _wizMode != _WizMode.off ? _wizardView() : (_connectedTo == null ? _deviceList() : _session()),
          ),
        ],
      ),
    );
  }

  Widget _wizardView() {
    if (_wizMode == _WizMode.done) return _wizardResults();

    final target = _wizTargets[_wizIndex];
    final held = _wizCandidateSince == null ? Duration.zero : DateTime.now().difference(_wizCandidateSince!);
    final progress = (held.inMilliseconds / 3000).clamp(0.0, 1.0);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text("${_wizIndex + 1} / ${_wizTargets.length}", style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(target, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 20),
          SizedBox(width: 220, child: LinearProgressIndicator(value: progress)),
          const SizedBox(height: 8),
          Text(
            _wizCandidate == null ? "Press and hold…" : "Holding — keep it down",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton(
                // Not every target exists on every pad — this one has no stick
                // clicks, for instance — so getting stuck on one is not an option.
                onPressed: _skipWizardTarget,
                child: const Text("Skip"),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: _cancelWizard, child: const Text("Cancel")),
            ],
          ),
        ],
      ),
    );
  }

  Widget _wizardResults() {
    final lines = <String>[
      for (final target in _wizTargets)
        "$target\t${_wizResults.containsKey(target) ? _describeSignal(_wizResults[target]!) : "(skipped)"}",
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text("Results", style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: lines.join("\n")));
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Copied")));
              },
            ),
            TextButton(onPressed: () => setState(() => _wizMode = _WizMode.off), child: const Text("Close")),
          ],
        ),
        Expanded(
          child: ListView(
            children: <Widget>[
              for (final target in _wizTargets)
                ListTile(
                  dense: true,
                  title: Text(target),
                  trailing: Text(
                    _wizResults.containsKey(target) ? _describeSignal(_wizResults[target]!) : "—",
                    style: const TextStyle(fontFamily: "monospace", fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _deviceList() {
    final found = _devices.values.toList()
      // The pad's advertised name is not documented, so nothing is filtered
      // out — the likely ones are only floated to the top.
      ..sort((a, b) {
        if (a.likely != b.likely) return a.likely ? -1 : 1;
        return b.rssi.compareTo(a.rssi);
      });

    final known = _known;
    final knownTile = known == null
        ? null
        : Card.filled(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const Icon(Icons.bolt),
              title: Text(known.name?.isNotEmpty == true ? known.name! : "Known pad"),
              subtitle: Text(known.address, style: const TextStyle(fontFamily: "monospace")),
              trailing: FilledButton.tonal(
                onPressed: () => _listen(address: known.address),
                child: const Text("Quick connect"),
              ),
              onTap: () => _listen(address: known.address),
            ),
          );

    if (found.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (knownTile != null) knownTile,
          Expanded(
            child: Center(
              child: Text(
                _state == "scanning" ? "Scanning — hold SYNC on the pad…" : "Nothing yet — press Auto connect",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      itemCount: found.length + (knownTile == null ? 0 : 1),
      itemBuilder: (context, i) {
        if (knownTile != null) {
          if (i == 0) return knownTile;
          i -= 1;
        }
        final device = found[i];
        return ListTile(
          dense: true,
          leading: Icon(device.likely ? Icons.videogame_asset : Icons.bluetooth, size: 20),
          title: Text(device.name.isEmpty ? "(unnamed)" : device.name),
          subtitle: Text("${device.address}   ${device.rssi} dBm", style: const TextStyle(fontFamily: "monospace")),
          onTap: () => _listen(address: device.address),
        );
      },
    );
  }

  Widget _session() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(_connectedTo!, style: const TextStyle(fontFamily: "monospace")),
        const SizedBox(height: 8),
        if (_input != null) _liveInput(_input!),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: <Widget>[
                const TabBar(
                  tabs: <Widget>[
                    Tab(text: "Log"),
                    Tab(text: "Attributes"),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _monoList(_log),
                      _monoList(<String>[for (final a in _attrs) a.line]),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _monoList(List<String> lines) {
    if (lines.isEmpty) {
      return Center(child: Text("Nothing yet", style: Theme.of(context).textTheme.bodySmall));
    }
    return ListView.builder(
      reverse: false,
      itemCount: lines.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: SelectableText(lines[i], style: const TextStyle(fontFamily: "monospace", fontSize: 12)),
      ),
    );
  }

  Widget _liveInput(_Input input) {
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              flex: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text("buttons 0x${input.buttons.toRadixString(16).padLeft(6, "0")}", style: _mono),
                  // The bit indices, not just the hex: the mapping in nsofeed.c is
                  // written against these, so a button landing on the wrong one is
                  // read straight off here.
                  Text("bits ${input.bits.isEmpty ? "—" : input.bits.join(" ")}", style: _mono),
                  Text("L ${input.lx}, ${input.ly}   R ${input.rx}, ${input.ry}", style: _mono),
                  Text("LT ${input.lt}   RT ${input.rt}", style: _mono),
                  const SizedBox(height: 4),
                  Text(input.hex, style: const TextStyle(fontFamily: "monospace", fontSize: 10), maxLines: 3),
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: input.hex));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Copied to clipboard")));
              },
              icon: Icon(Icons.copy),
            ),
          ],
        ),
      ),
    );
  }

  static const _mono = TextStyle(fontFamily: "monospace", fontSize: 13);
}

class _Device {
  const _Device({required this.address, required this.name, required this.rssi, required this.likely});

  final String address;
  final String name;
  final int rssi;
  final bool likely;
}

class _Attr {
  const _Attr({required this.handle, required this.uuid, required this.props, required this.what});

  final int handle;
  final String uuid;
  final int? props;

  /// `service`, `char` or `desc`.
  final String what;

  String get handleHex => "0x${handle.toRadixString(16).padLeft(4, "0").toUpperCase()}";

  /// One monospaced row: handle, what it is, its UUID, and — for a
  /// characteristic — the property bits, which is what says whether it can
  /// notify or be written without a response.
  String get line {
    final tail = props == null ? "" : "  props 0x${props!.toRadixString(16)}";
    return "$handleHex  ${what.padRight(7)}  $uuid$tail";
  }
}

class _Input {
  const _Input({
    required this.buttons,
    required this.bits,
    required this.lx,
    required this.ly,
    required this.rx,
    required this.ry,
    required this.lt,
    required this.rt,
    required this.hex,
  });

  factory _Input.fromMap(Map<String, Object?> m) => _Input(
    buttons: (m["buttons"] as int?) ?? 0,
    bits: (m["bits"] as List<Object?>?)?.cast<int>() ?? const <int>[],
    lx: (m["lx"] as int?) ?? 0,
    ly: (m["ly"] as int?) ?? 0,
    rx: (m["rx"] as int?) ?? 0,
    ry: (m["ry"] as int?) ?? 0,
    lt: (m["lt"] as int?) ?? 0,
    rt: (m["rt"] as int?) ?? 0,
    hex: (m["hex"] as String?) ?? "",
  );

  final int buttons;

  /// Indices of the set button bits, which is what names them.
  final List<int> bits;
  final int lx;
  final int ly;
  final int rx;
  final int ry;
  final int lt;
  final int rt;
  final String hex;
}
