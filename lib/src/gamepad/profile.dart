library;

import "package:thortoolbox/src/gamepad/shortcuts.dart";

class Profile {
  Profile(this.match);

  String match;
  String? preset;

  final Map<String, String> buttons = <String, String>{};
  final Map<String, String> axes = <String, String>{};
  final Set<String> inverts = <String>{};
  final Map<String, int> deadzones = <String, int>{};

  int get changeCount => buttons.length + axes.length + inverts.length + deadzones.length;
}

enum PadControl { button, axis }

class PadTarget {
  const PadTarget(this.code, this.label, this.kind);

  final String code;

  final String label;

  final PadControl kind;
}

class PadSection {
  const PadSection(this.title, this.targets);

  final String title;
  final List<PadTarget> targets;
}

const List<PadSection> kPadSections = <PadSection>[
  PadSection("Face buttons", <PadTarget>[
    PadTarget("BTN_A", "A", PadControl.button),
    PadTarget("BTN_B", "B", PadControl.button),
    PadTarget("BTN_X", "X", PadControl.button),
    PadTarget("BTN_Y", "Y", PadControl.button),
  ]),
  PadSection("Bumpers", <PadTarget>[
    PadTarget("BTN_TL", "Left bumper (L1)", PadControl.button),
    PadTarget("BTN_TR", "Right bumper (R1)", PadControl.button),
  ]),
  PadSection("Triggers", <PadTarget>[
    PadTarget("ABS_BRAKE", "Left trigger (L2)", PadControl.axis),
    PadTarget("ABS_GAS", "Right trigger (R2)", PadControl.axis),
    PadTarget("BTN_TL2", "Left trigger, as a button", PadControl.button),
    PadTarget("BTN_TR2", "Right trigger, as a button", PadControl.button),
  ]),
  PadSection("D-pad", <PadTarget>[
    PadTarget("BTN_DPAD_UP", "Up", PadControl.button),
    PadTarget("BTN_DPAD_DOWN", "Down", PadControl.button),
    PadTarget("BTN_DPAD_LEFT", "Left", PadControl.button),
    PadTarget("BTN_DPAD_RIGHT", "Right", PadControl.button),
    PadTarget("ABS_HAT0X", "Horizontal, as an axis", PadControl.axis),
    PadTarget("ABS_HAT0Y", "Vertical, as an axis", PadControl.axis),
  ]),
  PadSection("Sticks", <PadTarget>[
    PadTarget("ABS_X", "Left stick, horizontal", PadControl.axis),
    PadTarget("ABS_Y", "Left stick, vertical", PadControl.axis),
    PadTarget("ABS_Z", "Right stick, horizontal", PadControl.axis),
    PadTarget("ABS_RZ", "Right stick, vertical", PadControl.axis),
    PadTarget("BTN_THUMBL", "Left stick, click (LS)", PadControl.button),
    PadTarget("BTN_THUMBR", "Right stick, click (RS)", PadControl.button),
  ]),
  PadSection("Menu", <PadTarget>[
    PadTarget("BTN_SELECT", "View / Select", PadControl.button),
    PadTarget("BTN_START", "Menu / Start", PadControl.button),
    PadTarget("BTN_MODE", "Guide", PadControl.button),
  ]),
];

final Set<String> kStandardTargets = <String>{
  for (final section in kPadSections)
    for (final target in section.targets) target.code,
};

String? sourceFor(Map<String, String> mappings, String target) {
  for (final entry in mappings.entries) {
    if (entry.value == target) {
      return entry.key;
    }
  }
  return null;
}

const List<String> kButtons = <String>[
  "BTN_A",
  "BTN_B",
  "BTN_X",
  "BTN_Y",
  "BTN_TL",
  "BTN_TR",
  "BTN_TL2",
  "BTN_TR2",
  "BTN_SELECT",
  "BTN_START",
  "BTN_MODE",
  "BTN_THUMBL",
  "BTN_THUMBR",
  "BTN_DPAD_UP",
  "BTN_DPAD_DOWN",
  "BTN_DPAD_LEFT",
  "BTN_DPAD_RIGHT",
  "KEY_HOME",
  "KEY_BACK",
  "KEY_APPSELECT",
  "KEY_VOLUMEUP",
  "KEY_VOLUMEDOWN",
];

const List<String> kAxes = <String>["ABS_X", "ABS_Y", "ABS_Z", "ABS_RZ", "ABS_GAS", "ABS_BRAKE", "ABS_HAT0X", "ABS_HAT0Y"];

const Map<String, String> kAxisLabels = <String, String>{
  "ABS_X": "Left stick, horizontal",
  "ABS_Y": "Left stick, vertical",
  "ABS_Z": "Right stick, horizontal",
  "ABS_RZ": "Right stick, vertical",
  "ABS_BRAKE": "Left trigger",
  "ABS_GAS": "Right trigger",
  "ABS_HAT0X": "D-pad, horizontal",
  "ABS_HAT0Y": "D-pad, vertical",
};

String axisLabel(String code) {
  final name = kAxisLabels[code];
  return name == null ? code : "$name  ($code)";
}

const Map<String, int> _halfSpan = <String, int>{
  "ABS_X": 32767,
  "ABS_Y": 32767,
  "ABS_Z": 32767,
  "ABS_RZ": 32767,
  "ABS_BRAKE": 512,
  "ABS_GAS": 512,
  "ABS_HAT0X": 1,
  "ABS_HAT0Y": 1,
};

int deadzoneUnits(String axis, int percent) => (_halfSpan[axis] ?? 32767) * percent ~/ 100;

int deadzonePercent(String axis, int units) {
  final half = _halfSpan[axis] ?? 32767;
  return half == 0 ? 0 : units * 100 ~/ half;
}

bool globMatches(String pattern, String name) {
  final body = pattern.split("*").map(RegExp.escape).join(".*");
  return RegExp("^$body\$", caseSensitive: false).hasMatch(name);
}

Profile? profileFor(List<Profile> profiles, String padName) {
  for (final p in profiles) {
    if (globMatches(p.match, padName)) {
      return p;
    }
  }
  return null;
}

List<Profile> parseConfig(String text) {
  final out = <Profile>[];
  Profile? current;

  for (final raw in text.split("\n")) {
    final line = _before(raw, "#").trim();
    if (line.isEmpty) {
      continue;
    }

    if (line.startsWith("[") && line.endsWith("]")) {
      final name = line.substring(1, line.length - 1).trim();

      if (name.toLowerCase() == kShortcutsSection) {
        current = null;
        continue;
      }
      current = Profile(name);
      out.add(current);
      continue;
    }
    final p = current;
    if (p == null) {
      continue;
    }

    final verb = _before(line, " ").toLowerCase();
    final rest = line.contains(" ") ? _after(line, " ").trim() : "";
    final lhs = _before(rest, "=").trim();
    final rhs = rest.contains("=") ? _after(rest, "=").trim() : null;

    switch (verb) {
      case "preset":
        p.preset = rest;
      case "button":
      case "key":
        if (rhs != null) p.buttons[lhs] = rhs;
      case "axis":
        if (rhs != null) p.axes[lhs] = rhs;
      case "invert":
        p.inverts.add(lhs);
      case "deadzone":
        final v = int.tryParse(rhs ?? "");
        if (v != null) p.deadzones[lhs] = v;
    }
  }
  return out;
}

String renderConfig(List<Profile> profiles, List<Shortcut> shortcuts) {
  final sb = StringBuffer()
    ..writeln("# gpmerge - per-controller remapping profiles")
    ..writeln(
      "# Written by the AYN Thor Toolbox app. Hand edits are preserved "
      "on re-read,",
    )
    ..writeln("# but comments inside sections are not.")
    ..writeln();

  for (final p in profiles) {
    sb.writeln("[${p.match}]");
    final preset = p.preset;
    if (preset != null && preset.trim().isNotEmpty) {
      sb.writeln("preset $preset");
    }
    p.buttons.forEach((from, to) => sb.writeln("button $from = $to"));
    p.axes.forEach((from, to) => sb.writeln("axis $from = $to"));
    for (final axis in p.inverts) {
      sb.writeln("invert $axis");
    }
    p.deadzones.forEach((axis, v) => sb.writeln("deadzone $axis = $v"));
    sb.writeln();
  }
  sb.write(renderShortcuts(shortcuts));
  return sb.toString().trimRight();
}

String _before(String s, String sep) {
  final i = s.indexOf(sep);
  return i < 0 ? s : s.substring(0, i);
}

String _after(String s, String sep) {
  final i = s.indexOf(sep);
  return i < 0 ? "" : s.substring(i + sep.length);
}
