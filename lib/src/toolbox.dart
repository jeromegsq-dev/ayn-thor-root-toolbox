import "package:flutter/services.dart";

class Toolbox {
  const Toolbox._();

  static const _methods = MethodChannel("com.jeromegsq.thortoolbox/methods");
  static const _aspectState = EventChannel("com.jeromegsq.thortoolbox/aspect_state");
  static const _gamepadWatch = EventChannel("com.jeromegsq.thortoolbox/gamepad_watch");
  static const _gamepadInput = EventChannel("com.jeromegsq.thortoolbox/gamepad_input");
  static const _nso = EventChannel("com.jeromegsq.thortoolbox/nso");

  static Future<AutoDimConfig> loadAutoDim() async {
    final map = await _methods.invokeMapMethod<String, Object?>("autodim.load");
    return AutoDimConfig.fromMap(map!);
  }

  static Future<void> saveAutoDim(AutoDimConfig cfg) => _methods.invokeMethod<bool>("autodim.save", <String, Object?>{
    "enabled": cfg.enabled,
    "timeout": cfg.timeout,
    "min": cfg.min,
    "fade": cfg.fade,
  });

  /// Copies `bottom-autodim.sh` to `/data/adb/service.d/` as root and starts
  /// it right away — no adb, no reboot. True once the service reports itself
  /// running, false on a `su` failure or if it never came up in time.
  static Future<bool> installAutoDim() async => await _methods.invokeMethod<bool>("autodim.install") ?? false;

  static Future<AspectConfig> loadAspect() async {
    final map = await _methods.invokeMapMethod<String, Object?>("aspect.load");
    return AspectConfig.fromMap(map!);
  }

  static Future<void> saveAspect(AspectConfig cfg) => _methods.invokeMethod<bool>("aspect.save", cfg.toMap());

  static Future<void> setAspectEnabled({required bool value}) => _methods.invokeMethod<void>("aspect.setEnabled", value);

  static Future<void> setManageDp({required bool value}) => _methods.invokeMethod<void>("aspect.setManageDp", value);

  static Future<void> syncAspect() => _methods.invokeMethod<void>("aspect.sync");

  static Future<bool> resetAspectNow() async => await _methods.invokeMethod<bool>("aspect.resetNow") ?? false;

  static Future<bool> patternCompiles(String pattern) async =>
      await _methods.invokeMethod<bool>("aspect.checkPattern", pattern) ?? false;

  static Future<List<DisplayInfo>> displays() async {
    final list = await _methods.invokeListMethod<Object?>("aspect.displays");
    return <DisplayInfo>[for (final d in list ?? const <Object?>[]) DisplayInfo.fromMap((d as Map).cast<String, Object?>())];
  }

  static Stream<AspectState> aspectStates() =>
      _aspectState.receiveBroadcastStream().map((e) => AspectState.fromMap((e as Map).cast<String, Object?>()));

  static Future<GamepadState> gamepadState() async {
    final map = await _methods.invokeMapMethod<String, Object?>("gamepad.state");
    return GamepadState.fromMap(map!);
  }

  static Future<bool> writeGamepadConfig(String text) async =>
      await _methods.invokeMethod<bool>("gamepad.writeConfig", text) ?? false;

  static Future<bool> setExclusions(List<String> names) async =>
      await _methods.invokeMethod<bool>("gamepad.setExclusions", names) ?? false;

  static Stream<String> gamepadWatch({int seconds = 20}) =>
      _gamepadWatch.receiveBroadcastStream(<String, Object?>{"seconds": seconds}).cast<String>();

  static Stream<GamepadInput> gamepadInputs() =>
      _gamepadInput.receiveBroadcastStream().map((e) => GamepadInput.fromMap((e as Map).cast<String, Object?>()));

  /// Installed apps, for the "add a game" picker — icon included, since the
  /// point of asking is to draw a list of them.
  static Future<List<InstalledApp>> installedApps() async {
    final list = await _methods.invokeListMethod<Object?>("apps.list");
    return <InstalledApp>[for (final a in list ?? const <Object?>[]) InstalledApp.fromMap((a as Map).cast<String, Object?>())];
  }

  static Future<GameProfilesState> loadGameProfiles() async {
    final map = await _methods.invokeMapMethod<String, Object?>("gameprofiles.load");
    final games = (map!["games"] as List<Object?>?) ?? const <Object?>[];
    return GameProfilesState(
      enabled: map["enabled"] as bool,
      games: <GameProfile>[for (final g in games) GameProfile.fromMap((g as Map).cast<String, Object?>())],
    );
  }

  /// Starts or stops [GameProfileService] to match — switching by game only
  /// polls root while this is on.
  static Future<void> setGameProfilesEnabled({required bool value}) =>
      _methods.invokeMethod<void>("gameprofiles.setEnabled", value);

  /// Adds a game with an empty profile. Does nothing if it is already there.
  static Future<void> addGameProfile(String package, String label) => _methods.invokeMethod<void>(
    "gameprofiles.addGame",
    <String, Object?>{"package": package, "label": label},
  );

  static Future<void> removeGameProfile(String package) => _methods.invokeMethod<void>("gameprofiles.removeGame", package);

  static Future<void> saveGameProfile(String package, String config) => _methods.invokeMethod<void>(
    "gameprofiles.saveGame",
    <String, Object?>{"package": package, "config": config},
  );

  /// The NSO GameCube pad, over BLE: scan results with no [address], or the
  /// bring-up of that one pad with it. Each event is a map tagged by `kind` —
  /// `device`, `log`, `attr`, `state`, `input`, `raw` or `error`.
  ///
  /// Re-subscribing is how the screen switches between the two: cancelling
  /// tears the whole GATT connection down, so there is never more than one.
  /// With [publish], a connected pad is also republished as an evdev node, so
  /// gpmerge folds it into the merged controller and it reaches games.
  ///
  /// [auto] scans and then connects to the pad itself, without waiting for a
  /// row to be picked; [watch] attaches to whatever session is already running
  /// without starting a scan or a connection — the pad outlives this screen, so
  /// reopening it should find the pad rather than disturb it. Cancelling only
  /// detaches.
  static Stream<Map<String, Object?>> nsoEvents({
    String? address,
    bool publish = true,
    bool watch = false,
    bool auto = false,
  }) => _nso
      .receiveBroadcastStream(<String, Object?>{
        if (address != null) "address": address,
        "publish": publish,
        "watch": watch,
        "auto": auto,
      })
      .map((e) => (e as Map).cast<String, Object?>());

  /// Ends the pad session for good, rather than merely looking away.
  static Future<void> nsoDisconnect() => _methods.invokeMethod<void>("nso.disconnect");

  /// Scan and connect in one go: back to the remembered pad if there is one,
  /// otherwise to the first device that answers looking like a GameCube pad.
  ///
  /// A method rather than another way to subscribe, so a launcher tile can
  /// start it with no screen open. False means Bluetooth permission was
  /// missing and has just been asked for — try again once it is granted.
  static Future<bool> nsoAutoConnect() async => await _methods.invokeMethod<bool>("nso.autoConnect") ?? false;

  /// The pad remembered from whenever one last connected, or null if none
  /// ever has. Lets a freshly opened screen offer a one-tap reconnect instead
  /// of making the user scan again for a pad it has already seen.
  static Future<NsoKnownPad?> nsoKnownPad() async {
    final map = await _methods.invokeMapMethod<String, Object?>("nso.known");
    return map == null ? null : NsoKnownPad.fromMap(map);
  }

  /// Tells the pad it is player one again.
  ///
  /// It is told so during bring-up already, and once more when input starts
  /// flowing; this is for the run where it still ends up chasing its lamps
  /// around. Nothing can read the lamps back, so nothing can do this on its
  /// own the moment it goes wrong.
  static Future<void> nsoPlayerLed() => _methods.invokeMethod<void>("nso.playerLed");

  /// 0..100, persisted independently of any active session — the pad has no
  /// magnitude of its own, so this is how hard the PWM chop pretends it is
  /// pressed. 0 mutes rumble outright.
  static Future<int> nsoRumbleStrength() async => await _methods.invokeMethod<int>("nso.rumbleStrength") ?? 100;

  static Future<void> setNsoRumbleStrength(int percent) =>
      _methods.invokeMethod<void>("nso.setRumbleStrength", percent);

  /// A short pulse at the current strength — answers "does rumble work" with
  /// no game and no gpmerge merge needed.
  static Future<void> testNsoRumble() => _methods.invokeMethod<void>("nso.testRumble");
}

class NsoKnownPad {
  const NsoKnownPad({required this.address, this.name});

  factory NsoKnownPad.fromMap(Map<String, Object?> m) =>
      NsoKnownPad(address: m["address"] as String, name: m["name"] as String?);

  final String address;
  final String? name;
}

class GamepadInput {
  const GamepadInput({required this.device, this.key, this.down = false, this.axes});

  factory GamepadInput.fromMap(Map<String, Object?> m) => GamepadInput(
    device: m["device"] as String,
    key: m["kind"] == "key" ? m["name"] as String : null,
    down: m["kind"] == "key" && m["down"] as bool,
    axes: m["kind"] == "motion" ? (m["axes"] as Map).cast<String, double>() : null,
  );

  final String device;

  final String? key;
  final bool down;

  final Map<String, double>? axes;
}

class AutoDimConfig {
  const AutoDimConfig({
    required this.enabled,
    required this.timeout,
    required this.min,
    required this.fade,
    required this.brightnessMax,
    required this.serviceRunning,
  });

  factory AutoDimConfig.fromMap(Map<String, Object?> m) => AutoDimConfig(
    enabled: m["enabled"] as bool,
    timeout: m["timeout"] as int,
    min: m["min"] as int,
    fade: m["fade"] as int,
    brightnessMax: m["brightnessMax"] as int,
    serviceRunning: m["serviceRunning"] as bool,
  );

  final int timeout;

  final int min;

  final int fade;

  final bool enabled;

  final int brightnessMax;

  final bool serviceRunning;

  int get minPercent => (min * 100 / brightnessMax).round().clamp(0, 100);

  AutoDimConfig copyWith({bool? enabled, int? timeout, int? min, int? fade}) => AutoDimConfig(
    enabled: enabled ?? this.enabled,
    timeout: timeout ?? this.timeout,
    min: min ?? this.min,
    fade: fade ?? this.fade,
    brightnessMax: brightnessMax,
    serviceRunning: serviceRunning,
  );

  AutoDimConfig withMinPercent(int percent) => copyWith(min: percent * brightnessMax ~/ 100);
}

class AspectConfig {
  const AspectConfig({
    required this.enabled,
    required this.size,
    required this.density,
    required this.pattern,
    required this.manageDp,
    required this.dpMode,
    required this.dpLogical,
  });

  factory AspectConfig.fromMap(Map<String, Object?> m) => AspectConfig(
    enabled: m["enabled"] as bool,
    size: m["size"] as String,
    density: m["density"] as int,
    pattern: m["pattern"] as String,
    manageDp: m["manageDp"] as bool,
    dpMode: m["dpMode"] as String,
    dpLogical: m["dpLogical"] as String,
  );

  final bool enabled;
  final String size;
  final int density;
  final String pattern;
  final bool manageDp;
  final String dpMode;
  final String dpLogical;

  Map<String, Object?> toMap() => <String, Object?>{
    "enabled": enabled,
    "size": size,
    "density": density,
    "pattern": pattern,
    "manageDp": manageDp,
    "dpMode": dpMode,
    "dpLogical": dpLogical,
  };
}

class AspectState {
  const AspectState({required this.external, required this.applied});

  factory AspectState.fromMap(Map<String, Object?> m) =>
      AspectState(external: m["external"] as bool, applied: m["applied"] as bool);

  final bool external;
  final bool applied;
}

class Pad {
  const Pad({required this.name, required this.vendor, required this.product, required this.node});

  factory Pad.fromMap(Map<String, Object?> m) =>
      Pad(name: m["name"] as String, vendor: m["vendor"] as String, product: m["product"] as String, node: m["node"] as String);

  final String name;
  final String vendor;
  final String product;
  final String node;
}

class GamepadState {
  const GamepadState({
    required this.rooted,
    required this.running,
    required this.pads,
    required this.config,
    required this.androidPads,
    required this.excluded,
    required this.merged,
  });

  factory GamepadState.fromMap(Map<String, Object?> m) => GamepadState(
    rooted: m["rooted"] as bool,
    running: m["running"] as bool,
    pads: <Pad>[for (final p in m["pads"] as List<Object?>) Pad.fromMap((p as Map).cast<String, Object?>())],
    config: m["config"] as String,
    androidPads: <String>[for (final p in m["androidPads"] as List<Object?>) (p as Map)["name"] as String],
    excluded: (m["excluded"] as List<Object?>).cast<String>(),
    merged: m["merged"] as String,
  );

  final bool rooted;
  final bool running;
  final List<Pad> pads;

  final String config;

  final List<String> androidPads;

  final List<String> excluded;

  final String merged;

  List<String> get phantoms => androidPads.where((name) => name != merged).toList();

  bool get phantomsPending => phantoms.any((name) => !excluded.contains(name));
}

class InstalledApp {
  const InstalledApp({required this.package, required this.label, required this.icon});

  factory InstalledApp.fromMap(Map<String, Object?> m) =>
      InstalledApp(package: m["package"] as String, label: m["label"] as String, icon: m["icon"] as Uint8List?);

  final String package;
  final String label;
  final Uint8List? icon;
}

/// A game's own gpmerge remap, kept and applied separately from the one every
/// other game falls back to.
///
/// [config] is rendered `[glob]` profile text — the same shape
/// `lib/src/gamepad/profile.dart` reads and writes for the live file, just
/// scoped to one game rather than pushed to `gpmerge.conf` directly. Only
/// [GameProfileService] does that, once this game is actually in front.
class GameProfile {
  const GameProfile({required this.package, required this.label, required this.config});

  factory GameProfile.fromMap(Map<String, Object?> m) =>
      GameProfile(package: m["package"] as String, label: m["label"] as String, config: m["config"] as String? ?? "");

  final String package;
  final String label;
  final String config;
}

class GameProfilesState {
  const GameProfilesState({required this.enabled, required this.games});

  final bool enabled;
  final List<GameProfile> games;
}

class DisplayInfo {
  const DisplayInfo({required this.id, required this.name, required this.width, required this.height});

  factory DisplayInfo.fromMap(Map<String, Object?> m) =>
      DisplayInfo(id: m["id"] as int, name: m["name"] as String, width: m["width"] as int, height: m["height"] as int);

  final int id;
  final String name;
  final int width;
  final int height;

  @override
  String toString() => '  id $id  "$name"  ${width}x$height';
}
