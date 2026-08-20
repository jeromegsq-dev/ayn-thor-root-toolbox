import "package:flutter_test/flutter_test.dart";
import "package:thortoolbox/src/gamepad/profile.dart";
import "package:thortoolbox/src/gamepad/shortcuts.dart";

void main() {
  test("parses a profile", () {
    final profiles = parseConfig("""
# a comment
[AYN Thor Gamepad*]
preset nintendo
button BTN_A = BTN_B      # trailing comment
key BTN_X = BTN_Y
axis ABS_X = ABS_Z
invert ABS_Y
deadzone ABS_Z = 25
""");

    expect(profiles, hasLength(1));
    final p = profiles.single;
    expect(p.match, "AYN Thor Gamepad*");
    expect(p.preset, "nintendo");
    expect(p.buttons, <String, String>{"BTN_A": "BTN_B", "BTN_X": "BTN_Y"});
    expect(p.axes, <String, String>{"ABS_X": "ABS_Z"});
    expect(p.inverts, <String>{"ABS_Y"});
    expect(p.deadzones, <String, int>{"ABS_Z": 25});
    expect(p.changeCount, 5);
  });

  test("lines before any section are ignored", () {
    expect(parseConfig("button BTN_A = BTN_B"), isEmpty);
  });

  test("renders back to something that parses the same", () {
    const text = """
[pad one]
preset xbox
button BTN_A = BTN_B
axis ABS_X = ABS_Z
invert ABS_Y
deadzone ABS_Z = 25

[pad two]
button BTN_X = none
""";

    final once = parseConfig(text);
    final twice = parseConfig(renderConfig(once, const <Shortcut>[]));

    expect(twice, hasLength(2));
    expect(twice[0].match, "pad one");
    expect(twice[0].preset, "xbox");
    expect(twice[0].buttons, once[0].buttons);
    expect(twice[0].axes, once[0].axes);
    expect(twice[0].inverts, once[0].inverts);
    expect(twice[0].deadzones, once[0].deadzones);
    expect(twice[1].match, "pad two");
    expect(twice[1].preset, isNull);
    expect(twice[1].buttons, <String, String>{"BTN_X": "none"});
  });

  test("a profile with no preset renders no preset line", () {
    final text = renderConfig(<Profile>[Profile("pad")], const <Shortcut>[]);
    expect(text, endsWith("[pad]"));
    expect(text, isNot(contains("preset")));
  });

  group("glob matching, the daemon's own rule", () {
    test("matches on * and ignores case", () {
      expect(globMatches("AYN*Gamepad", "ayn thor gamepad"), isTrue);
      expect(globMatches("*", "anything"), isTrue);
      expect(globMatches("AYN*", "Xbox Wireless"), isFalse);
    });

    test("matches the whole name, not a part of it", () {
      expect(globMatches("Gamepad", "AYN Gamepad"), isFalse);
    });

    test("treats regex metacharacters as literal text", () {
      expect(globMatches("pad.one", "pad.one"), isTrue);
      expect(globMatches("pad.one", "padXone"), isFalse);
    });

    test("picks the first profile that matches", () {
      final profiles = <Profile>[Profile("AYN*"), Profile("*")];
      expect(profileFor(profiles, "AYN Thor")?.match, "AYN*");
      expect(profileFor(profiles, "Xbox")?.match, "*");
      expect(profileFor(<Profile>[Profile("AYN*")], "Xbox"), isNull);
    });
  });

  group("dead zones", () {
    test("are a share of the axis half-span", () {
      expect(deadzoneUnits("ABS_X", 10), 3276);
      expect(deadzonePercent("ABS_X", 3276), 9);
    });

    test("follow the shape of the axis, stick or trigger", () {
      expect(deadzoneUnits("ABS_Z", 10), deadzoneUnits("ABS_X", 10));
      expect(deadzoneUnits("ABS_RZ", 10), deadzoneUnits("ABS_Y", 10));
      expect(deadzoneUnits("ABS_GAS", 20), 102);
      expect(deadzoneUnits("ABS_BRAKE", 20), 102);
    });

    test("fall back to the stick span for an unknown axis", () {
      expect(deadzoneUnits("ABS_MYSTERY", 10), 3276);
    });
  });

  test("axis labels keep the raw code visible", () {
    expect(axisLabel("ABS_X"), "Left stick, horizontal  (ABS_X)");
    expect(axisLabel("ABS_UNKNOWN"), "ABS_UNKNOWN");
  });
}
