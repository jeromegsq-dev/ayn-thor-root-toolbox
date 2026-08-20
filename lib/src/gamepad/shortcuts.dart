import "dart:async";

import "package:thortoolbox/src/gamepad/profile.dart";
import "package:thortoolbox/src/toolbox.dart";

class Shortcut {
  const Shortcut(this.combo, this.command);

  final List<String> combo;

  final String command;

  ShortcutAction? get action {
    for (final a in kShortcutActions) {
      if (a.command == command) {
        return a;
      }
    }
    return null;
  }
}

class ShortcutAction {
  const ShortcutAction(this.group, this.label, this.command);

  final String group;
  final String label;
  final String command;
}

const String _topUp =
    r"v=$(settings get system screen_brightness);v=$((v+26));"
    r"[ $v -gt 255 ]&&v=255;settings put system screen_brightness $v";
const String _topDown =
    r"v=$(settings get system screen_brightness);v=$((v-26));"
    r"[ $v -lt 5 ]&&v=5;settings put system screen_brightness $v";

const String _bottomUp =
    r"f=/sys/class/backlight/panel1-backlight/brightness;"
    r"v=$(($(cat $f)+410));[ $v -gt 4095 ]&&v=4095;echo $v>$f";
const String _bottomDown =
    r"f=/sys/class/backlight/panel1-backlight/brightness;"
    r"v=$(($(cat $f)-410));[ $v -lt 80 ]&&v=80;echo $v>$f";

const String _topLouder = "cmd media_session volume --stream 3 --adj raise --show";
const String _topQuieter = "cmd media_session volume --stream 3 --adj lower --show";

const String _bottomLouder =
    r"v=$(settings get system secondary_screen_volume_level);v=$((v+1));"
    r"[ $v -gt 15 ]&&v=15;settings put system secondary_screen_volume_level $v";
const String _bottomQuieter =
    r"v=$(settings get system secondary_screen_volume_level);v=$((v-1));"
    r"[ $v -lt 0 ]&&v=0;settings put system secondary_screen_volume_level $v";

/// AutoDim's settings file — the same path `bottom-autodim.sh` reads, and the
/// only thing standing between the two: the script re-reads it on every idle
/// cycle, so flipping `enabled` is the whole switch. Turned off it also puts
/// the backlight back by itself, within one timeout.
const String _autoDimConf = "/data/user/0/com.jeromegsq.thortoolbox/files/config";

/// Sourcing the file is reading it: the app writes four `key=integer` lines
/// and nothing else, which is valid shell by construction, and the four
/// defaults ahead of it cover a line that is missing or empty. All four go
/// back, so the timeout, the floor and the fade survive a toggle.
///
/// Missing file means the app has never written its settings — there is
/// nothing worth guessing at, so it does nothing rather than invent a config.
const String _autoDimHead =
    "f=$_autoDimConf;"
    r"[ -r $f ]||exit;enabled=0;timeout=5;min=0;fade=800;. $f;";

/// Truncating the file that is already there, rather than writing a new one:
/// this runs as root inside the app's private directory, and a file created
/// here would come out owned by root, which the app could then no longer read.
/// `>` keeps the inode, so it keeps the owner and the SELinux label.
const String _autoDimTail =
    r"printf 'enabled=%s\ntimeout=%s\nmin=%s\nfade=%s\n' $enabled $timeout $min $fade>$f";

const String _autoDimToggle = "$_autoDimHead" r'[ "$enabled" = 1 ]&&enabled=0||enabled=1;' "$_autoDimTail";
const String _autoDimOn = "${_autoDimHead}enabled=1;$_autoDimTail";
const String _autoDimOff = "${_autoDimHead}enabled=0;$_autoDimTail";

/// The top panel does 60 and 120, and nothing in between: its two modes are
/// 1080x1920 at 60.000004 and at 120.00001. The pair of settings below is what
/// Android's mode director votes on — floor and ceiling — so writing the same
/// number to both pins the rate there rather than leaving it free to wander.
/// Which is how this device ships anyway: both sat at 120 out of the box.
///
/// The bottom screen has its own two modes and is not part of this vote — it
/// stayed at 120 throughout, which is the point of doing it this way rather
/// than through a display mode.
const String _hz60 = "settings put system peak_refresh_rate 60;settings put system min_refresh_rate 60";
const String _hz120 = "settings put system peak_refresh_rate 120;settings put system min_refresh_rate 120";

/// Reads the ceiling back to decide which way to go. The value comes back as
/// `120.00001` or `120` depending on who last wrote it, and as `null` when it
/// has never been set, so only the part before the dot is compared and
/// anything unrecognised falls to 120.
const String _hzToggle =
    r"p=$(settings get system peak_refresh_rate);case ${p%%.*} in 120)n=60;;*)n=120;;esac;"
    r"settings put system peak_refresh_rate $n;settings put system min_refresh_rate $n";

const List<ShortcutAction> kShortcutActions = <ShortcutAction>[
  ShortcutAction("Both screens", "Brighter", "$_topUp;$_bottomUp"),
  ShortcutAction("Both screens", "Dimmer", "$_topDown;$_bottomDown"),
  ShortcutAction("Both screens", "Louder", "$_topLouder;$_bottomLouder"),
  ShortcutAction("Both screens", "Quieter", "$_topQuieter;$_bottomQuieter"),
  ShortcutAction("Top screen", "Brighter", _topUp),
  ShortcutAction("Top screen", "Dimmer", _topDown),
  ShortcutAction("Top screen", "Louder", _topLouder),
  ShortcutAction("Top screen", "Quieter", _topQuieter),
  ShortcutAction("Bottom screen", "Brighter", _bottomUp),
  ShortcutAction("Bottom screen", "Dimmer", _bottomDown),
  ShortcutAction("Bottom screen", "Louder", _bottomLouder),
  ShortcutAction("Bottom screen", "Quieter", _bottomQuieter),
  // The bottom screen's own dimming, from inside a game — which is where it
  // gets in the way, and the one place the quick settings tile cannot be
  // reached without leaving what you are doing.
  ShortcutAction("AutoDim (bottom screen)", "Toggle", _autoDimToggle),
  ShortcutAction("AutoDim (bottom screen)", "On", _autoDimOn),
  ShortcutAction("AutoDim (bottom screen)", "Off", _autoDimOff),
  // Half the refresh rate is most of the panel's power, and a game locked to
  // 60 anyway loses nothing by it — which is a decision worth making from
  // inside the game rather than before starting it.
  ShortcutAction("Top screen refresh rate", "Toggle 60 / 120", _hzToggle),
  ShortcutAction("Top screen refresh rate", "60 Hz", _hz60),
  ShortcutAction("Top screen refresh rate", "120 Hz", _hz120),
];

const String kShortcutsSection = "shortcuts";

List<Shortcut> parseShortcuts(String text) {
  final out = <Shortcut>[];
  var inSection = false;

  for (final raw in text.split("\n")) {
    final line = raw.split("#").first.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith("[") && line.endsWith("]")) {
      inSection = line.substring(1, line.length - 1).trim().toLowerCase() == kShortcutsSection;
      continue;
    }
    if (!inSection || !line.toLowerCase().startsWith("combo ")) {
      continue;
    }
    final rest = line.substring("combo ".length);
    final eq = rest.indexOf("=");
    if (eq < 0) {
      continue;
    }
    final combo = rest.substring(0, eq).split("+").map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final command = rest.substring(eq + 1).trim();
    if (combo.isNotEmpty && command.isNotEmpty) {
      out.add(Shortcut(combo, command));
    }
  }
  return out;
}

String renderShortcuts(List<Shortcut> shortcuts) {
  if (shortcuts.isEmpty) {
    return "";
  }
  final sb = StringBuffer("[$kShortcutsSection]\n");
  for (final s in shortcuts) {
    sb.writeln('combo ${s.combo.join('+')} = ${s.command}');
  }
  return sb.toString();
}

const Map<String, String> kButtonLabels = <String, String>{
  "BTN_A": "A",
  "BTN_B": "B",
  "BTN_X": "X",
  "BTN_Y": "Y",
  "BTN_TL": "L1",
  "BTN_TR": "R1",
  "BTN_TL2": "L2",
  "BTN_TR2": "R2",
  "BTN_SELECT": "View",
  "BTN_START": "Menu",
  "BTN_MODE": "Guide",
  "BTN_THUMBL": "L3",
  "BTN_THUMBR": "R3",
  "BTN_DPAD_UP": "D-pad up",
  "BTN_DPAD_DOWN": "D-pad down",
  "BTN_DPAD_LEFT": "D-pad left",
  "BTN_DPAD_RIGHT": "D-pad right",
  "LSTICK_UP": "Left stick up",
  "LSTICK_DOWN": "Left stick down",
  "LSTICK_LEFT": "Left stick left",
  "LSTICK_RIGHT": "Left stick right",
  "RSTICK_UP": "Right stick up",
  "RSTICK_DOWN": "Right stick down",
  "RSTICK_LEFT": "Right stick left",
  "RSTICK_RIGHT": "Right stick right",
};

String buttonLabel(String code) => kButtonLabels[code] ?? code;

String comboLabel(List<String> combo) => combo.map(buttonLabel).join(" + ");

String mergedCode(List<Profile> profiles, String padName, String code) {
  final profile = profileFor(profiles, padName);
  if (profile == null) {
    return code;
  }
  var out = code;
  final table = switch (profile.preset?.toLowerCase()) {
    "nintendo" => _nintendo,
    _ => null,
  };
  if (table != null) {
    out = table[out] ?? out;
  }
  return profile.buttons[out] ?? out;
}

const Map<String, String> _nintendo = <String, String>{"BTN_A": "BTN_B", "BTN_B": "BTN_A", "BTN_X": "BTN_Y", "BTN_Y": "BTN_X"};

/// The output axis a source one merges into, the same lookup [mergedCode]
/// does for buttons — `axis` defaults to passthrough by name, matching the
/// daemon's default identity remap.
String _mergedAxis(List<Profile> profiles, String padName, String code) {
  final profile = profileFor(profiles, padName);
  return profile?.axes[code] ?? code;
}

/// Which two pseudo buttons (see `PB_*` in gpmerge.c) an output axis drives:
/// X/Y carry the left stick, Z/RZ the right one.
const Map<String, (String neg, String pos)> _stickPairs = <String, (String, String)>{
  "ABS_X": ("LSTICK_LEFT", "LSTICK_RIGHT"),
  "ABS_Y": ("LSTICK_UP", "LSTICK_DOWN"),
  "ABS_Z": ("RSTICK_LEFT", "RSTICK_RIGHT"),
  "ABS_RZ": ("RSTICK_UP", "RSTICK_DOWN"),
};

/// Percent of the axis's half-span — must match `STICK_ON`/`STICK_OFF` in
/// gpmerge.c, or a combo recorded here would not be the one that actually
/// fires in a game.
const double kStickOn = 90;
const double kStickOff = 75;

/// Which of a stick's two pseudo buttons a raw reading should hold or
/// release, given which of the two [isHeld] says are currently down — the
/// pure logic behind [ComboRecorder]'s stick handling, mirrored from
/// `update_stick_shortcuts()` in gpmerge.c so a macro recorded here is the
/// one that will actually fire. Kept free of the watch stream so it can be
/// tested directly.
List<(String code, bool down)> stickHoldChanges({
  required List<Profile> profiles,
  required String padName,
  required String axisCode,
  required int value,
  required int min,
  required int max,
  required bool Function(String code) isHeld,
}) {
  final pair = _stickPairs[_mergedAxis(profiles, padName, axisCode)];
  if (pair == null || max <= min) {
    return const <(String, bool)>[];
  }

  var frac = (value.clamp(min, max) - min) / (max - min);
  final profile = profileFor(profiles, padName);
  if (profile != null && profile.inverts.contains(axisCode)) {
    frac = 1 - frac;
  }
  final towardsPos = (2 * frac - 1) * 100;
  final towardsNeg = -towardsPos;

  final (negCode, posCode) = pair;
  final out = <(String, bool)>[];
  if (towardsNeg >= kStickOn && !isHeld(negCode)) {
    out.add((negCode, true));
  } else if (towardsNeg <= kStickOff && isHeld(negCode)) {
    out.add((negCode, false));
  }
  if (towardsPos >= kStickOn && !isHeld(posCode)) {
    out.add((posCode, true));
  } else if (towardsPos <= kStickOff && isHeld(posCode)) {
    out.add((posCode, false));
  }
  return out;
}

class ComboRecorder {
  ComboRecorder({required this.profiles, int seconds = 15}) {
    _sub = Toolbox.gamepadWatch(seconds: seconds).listen(_onLine, onDone: _giveUp, onError: (Object _) => _giveUp());
  }

  final List<Profile> profiles;

  final Completer<List<String>?> _done = Completer<List<String>?>();
  late final StreamSubscription<String> _sub;

  final Set<String> _held = <String>{};
  final List<String> _seen = <String>[];

  /// Raw device range per `"<pad>\t<axis>"`, from the daemon's `AXIS`
  /// announcements — needed to turn a raw value into a share of travel.
  final Map<String, (int min, int max)> _ranges = <String, (int, int)>{};

  Future<List<String>?> get result => _done.future;

  List<String> get pressed => List<String>.unmodifiable(_seen);

  void Function()? onChanged;

  Future<void> cancel() async {
    _finish(null);
    await _sub.cancel();
  }

  void _onLine(String line) {
    if (_done.isCompleted) {
      return;
    }
    final f = line.split("\t");
    if (f.length < 5) {
      return;
    }

    if (f[0] == "AXIS") {
      final min = int.tryParse(f[3]);
      final max = int.tryParse(f[4]);
      if (min != null && max != null && max > min) {
        _ranges["${f[1]}\t${f[2]}"] = (min, max);
      }
      return;
    }
    if (f[0] != "EV") {
      return;
    }

    if (f[2] == "KEY") {
      final code = mergedCode(profiles, f[1], f[3]);
      if (code != "none") {
        _apply(code, f[4] == "1");
      }
    } else if (f[2] == "ABS") {
      _consumeAxis(f[1], f[3], f[4]);
    }
  }

  void _consumeAxis(String padName, String axisCode, String rawValue) {
    final value = int.tryParse(rawValue);
    final range = _ranges["$padName\t$axisCode"];
    if (value == null || range == null) {
      return;
    }
    for (final (code, down) in stickHoldChanges(
      profiles: profiles,
      padName: padName,
      axisCode: axisCode,
      value: value,
      min: range.$1,
      max: range.$2,
      isHeld: _held.contains,
    )) {
      _apply(code, down);
    }
  }

  void _apply(String code, bool down) {
    if (down) {
      _held.add(code);
      if (!_seen.contains(code)) {
        _seen.add(code);
      }
    } else {
      _held.remove(code);
    }
    onChanged?.call();

    if (!down && _held.isEmpty && _seen.isNotEmpty) {
      _finish(List<String>.of(_seen));
    }
  }

  void _giveUp() => _finish(_seen.isEmpty ? null : List<String>.of(_seen));

  void _finish(List<String>? combo) {
    if (_done.isCompleted) {
      return;
    }
    _done.complete(combo);
    unawaited(_sub.cancel());
  }
}
