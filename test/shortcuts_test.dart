import "package:flutter_test/flutter_test.dart";
import "package:thortoolbox/src/gamepad/profile.dart";
import "package:thortoolbox/src/gamepad/shortcuts.dart";

void main() {
  const config = """
[Odin Controller]
preset xbox
button BTN_X = BTN_A

[shortcuts]
combo BTN_MODE+BTN_DPAD_UP = cmd media_session volume --stream 3 --adj raise --show
combo BTN_MODE+BTN_START = echo hand written
""";

  test("parses combos out of the shortcuts section", () {
    final shortcuts = parseShortcuts(config);

    expect(shortcuts, hasLength(2));
    expect(shortcuts.first.combo, <String>["BTN_MODE", "BTN_DPAD_UP"]);
    expect(shortcuts.first.command, "cmd media_session volume --stream 3 --adj raise --show");
    expect(shortcuts.first.action?.label, "Louder");
    expect(shortcuts.last.action, isNull, reason: "not one of ours");
  });

  test("the shortcuts section is not read as a controller profile", () {
    final profiles = parseConfig(config);

    expect(profiles, hasLength(1));
    expect(profiles.single.match, "Odin Controller");
    expect(profileFor(profiles, "shortcuts"), isNull);
  });

  test("a profile save keeps the combos", () {
    final text = renderConfig(parseConfig(config), parseShortcuts(config));
    final shortcuts = parseShortcuts(text);

    expect(shortcuts, hasLength(2));
    expect(shortcuts.first.combo, <String>["BTN_MODE", "BTN_DPAD_UP"]);
    expect(parseConfig(text).single.buttons, <String, String>{"BTN_X": "BTN_A"});
  });

  test("a shortcut save keeps the profiles", () {
    final text = renderConfig(parseConfig(config), <Shortcut>[
      Shortcut(const <String>["BTN_MODE"], kShortcutActions.first.command),
    ]);

    expect(parseConfig(text).single.match, "Odin Controller");
    expect(parseShortcuts(text), hasLength(1));
  });

  test("nothing is written when there is no shortcut", () {
    final text = renderConfig(parseConfig(config), const <Shortcut>[]);

    expect(text, isNot(contains("[shortcuts]")));
    expect(parseShortcuts(text), isEmpty);
  });

  group("the commands the daemon will run", () {
    test("stay on one line and carry no comment marker", () {
      for (final action in kShortcutActions) {
        expect(action.command, isNot(contains("\n")), reason: action.label);
        expect(action.command, isNot(contains("#")), reason: action.label);
        expect(action.command.length, lessThan(384), reason: action.label);
      }
    });

    test("are each their own action", () {
      final commands = kShortcutActions.map((a) => a.command).toSet();
      expect(commands, hasLength(kShortcutActions.length));
    });
  });

  group("a press is recorded as the merged pad will emit it", () {
    final profiles = parseConfig("""
[Odin Controller]
button BTN_SELECT = BTN_MODE

[Switch*]
preset nintendo
""");

    test("follows the profile's own remapping", () {
      expect(mergedCode(profiles, "Odin Controller", "BTN_SELECT"), "BTN_MODE");
      expect(mergedCode(profiles, "Odin Controller", "BTN_A"), "BTN_A");
    });

    test("follows the preset", () {
      expect(mergedCode(profiles, "Switch Pro", "BTN_A"), "BTN_B");
      expect(mergedCode(profiles, "Switch Pro", "BTN_X"), "BTN_Y");
      expect(mergedCode(profiles, "Switch Pro", "BTN_TL"), "BTN_TL");
    });

    test("passes a pad with no profile through", () {
      expect(mergedCode(profiles, "Some Other Pad", "BTN_A"), "BTN_A");
    });
  });

  test("combos read back in player words", () {
    expect(comboLabel(const <String>["BTN_MODE", "BTN_DPAD_UP"]), "Guide + D-pad up");
    expect(buttonLabel("BTN_UNKNOWN"), "BTN_UNKNOWN");
  });

  group("a stick crosses into a shortcut combo the way gpmerge.c will see it", () {
    // min=0, max=200 so 90%/75% of half-span land near round values: centre
    // 100, half 100. 191, not 190, to clear the 90% line comfortably —
    // 190/200 lands close enough to it that double rounding can put the
    // share on either side of >=90.
    const profiles = <Profile>[];

    List<(String, bool)> at(int value, {bool Function(String) isHeld = _never}) => stickHoldChanges(
      profiles: profiles,
      padName: "Odin Controller",
      axisCode: "ABS_X",
      value: value,
      min: 0,
      max: 200,
      isHeld: isHeld,
    );

    test("holds the positive side past 90%", () {
      expect(at(191), <(String, bool)>[("LSTICK_RIGHT", true)]);
      expect(at(200), <(String, bool)>[("LSTICK_RIGHT", true)]);
    });

    test("holds the negative side past 90% the other way", () {
      expect(at(10), <(String, bool)>[("LSTICK_LEFT", true)]);
    });

    test("does nothing under the threshold", () {
      expect(at(150), isEmpty);
      expect(at(100), isEmpty);
    });

    test("does not re-fire while already held, inside the hysteresis band", () {
      expect(at(180, isHeld: (c) => c == "LSTICK_RIGHT"), isEmpty);
    });

    test("releases once it drops under 75%, not the moment it leaves 90%", () {
      expect(at(185, isHeld: (c) => c == "LSTICK_RIGHT"), isEmpty);
      expect(at(150, isHeld: (c) => c == "LSTICK_RIGHT"), <(String, bool)>[("LSTICK_RIGHT", false)]);
    });

    test("follows a profile's axis remap to the stick it actually lands on", () {
      final remapped = parseConfig("""
[Odin Controller]
axis ABS_X = ABS_Y
""");
      expect(
        stickHoldChanges(profiles: remapped, padName: "Odin Controller", axisCode: "ABS_X", value: 191, min: 0, max: 200, isHeld: _never),
        <(String, bool)>[("LSTICK_DOWN", true)],
      );
    });

    test("follows a profile's invert", () {
      final inverted = parseConfig("""
[Odin Controller]
invert ABS_X
""");
      expect(
        stickHoldChanges(profiles: inverted, padName: "Odin Controller", axisCode: "ABS_X", value: 191, min: 0, max: 200, isHeld: _never),
        <(String, bool)>[("LSTICK_LEFT", true)],
      );
    });

    test("triggers and the d-pad hat are not shortcut sticks", () {
      expect(
        stickHoldChanges(profiles: profiles, padName: "Odin Controller", axisCode: "ABS_GAS", value: 200, min: 0, max: 200, isHeld: _never),
        isEmpty,
      );
    });
  });
}

bool _never(String code) => false;
