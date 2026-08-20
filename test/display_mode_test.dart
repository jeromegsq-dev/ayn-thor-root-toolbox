import "package:flutter_test/flutter_test.dart";
import "package:thortoolbox/src/aspect_page.dart";

void main() {
  test("the logical size is the mode turned on its side", () {
    expect(const DisplayMode(640, 480, 164).logicalSize, "480x640");
    expect(const DisplayMode(1024, 768, 262).logicalSize, "768x1024");
    expect(const DisplayMode(1280, 1024, 349).logicalSize, "1024x1280");
  });

  test("the DP mode is what the vendor HAL is asked for", () {
    expect(const DisplayMode(800, 600, 205).dpMode, "800x600@60");
  });

  test("every mode is a real VGA one, and 60 Hz", () {
    expect(kDisplayModes.map((m) => m.label), <String>["640 × 480", "800 × 600", "1024 × 768", "1280 × 1024"]);
    for (final mode in kDisplayModes) {
      expect(mode.dpMode, endsWith("@60"), reason: mode.label);
    }
  });

  test("the interface keeps its size across modes", () {
    double dpAcross(DisplayMode m) => m.height / (m.density / 160);

    final reference = dpAcross(const DisplayMode(1024, 768, 262));
    for (final mode in kDisplayModes) {
      expect(
        (dpAcross(mode) - reference).abs() / reference,
        lessThan(0.05),
        reason: "${mode.label} at density ${mode.density}",
      );
    }
  });
}
