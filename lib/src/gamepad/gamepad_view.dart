import "dart:math" as math;

import "package:flutter/foundation.dart" show mapEquals, setEquals;
import "package:flutter/material.dart";

class GamepadView extends StatelessWidget {
  const GamepadView({required this.pressed, required this.axes, super.key});

  final Set<String> pressed;

  final Map<String, double> axes;

  static const Set<String> drawnKeys = <String>{
    "KEYCODE_BUTTON_A",
    "KEYCODE_BUTTON_B",
    "KEYCODE_BUTTON_X",
    "KEYCODE_BUTTON_Y",
    "KEYCODE_BUTTON_L1",
    "KEYCODE_BUTTON_R1",
    "KEYCODE_BUTTON_L2",
    "KEYCODE_BUTTON_R2",
    "KEYCODE_BUTTON_THUMBL",
    "KEYCODE_BUTTON_THUMBR",
    "KEYCODE_BUTTON_SELECT",
    "KEYCODE_BUTTON_START",
    "KEYCODE_BUTTON_MODE",
    "KEYCODE_DPAD_UP",
    "KEYCODE_DPAD_DOWN",
    "KEYCODE_DPAD_LEFT",
    "KEYCODE_DPAD_RIGHT",
  };

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: _GamepadPainter.design.width / _GamepadPainter.design.height,
      child: CustomPaint(
        painter: _GamepadPainter(pressed: pressed, axes: axes, scheme: Theme.of(context).colorScheme),
      ),
    );
  }
}

class _GamepadPainter extends CustomPainter {
  _GamepadPainter({required this.pressed, required this.axes, required this.scheme});

  static const Size design = Size(400, 200);

  final Set<String> pressed;
  final Map<String, double> axes;
  final ColorScheme scheme;

  late final Paint _shell = Paint()..color = scheme.surfaceContainerHighest;
  late final Paint _outline = Paint()
    ..color = scheme.outlineVariant
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  late final Paint _idle = Paint()..color = scheme.surfaceContainerLow;
  late final Paint _active = Paint()..color = scheme.primary;

  bool _down(String button) => pressed.contains("KEYCODE_$button");

  double _axis(String name) => axes[name] ?? 0;

  (double, double) get _rightStick {
    final z = _axis("AXIS_Z");
    final rz = _axis("AXIS_RZ");
    if (z != 0 || rz != 0) {
      return (z, rz);
    }
    return (_axis("AXIS_RX"), _axis("AXIS_RY"));
  }

  double _trigger({required bool left}) {
    final analogue = math.max(_axis(left ? "AXIS_BRAKE" : "AXIS_GAS"), _axis(left ? "AXIS_LTRIGGER" : "AXIS_RTRIGGER"));
    if (analogue > 0) {
      return analogue.clamp(0.0, 1.0);
    }
    return _down(left ? "BUTTON_L2" : "BUTTON_R2") ? 1 : 0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / design.width);

    _paintShell(canvas);

    _paintTrigger(canvas, const Rect.fromLTRB(72, 4, 128, 22), _trigger(left: true), "L2");
    _paintTrigger(canvas, const Rect.fromLTRB(272, 4, 328, 22), _trigger(left: false), "R2");
    _paintPill(canvas, const Rect.fromLTRB(66, 26, 134, 42), _down("BUTTON_L1"), "L1");
    _paintPill(canvas, const Rect.fromLTRB(266, 26, 334, 42), _down("BUTTON_R1"), "R1");

    _paintStick(canvas, const Offset(95, 88), _axis("AXIS_X"), _axis("AXIS_Y"), _down("BUTTON_THUMBL"));
    final (rx, ry) = _rightStick;
    _paintStick(canvas, const Offset(258, 136), rx, ry, _down("BUTTON_THUMBR"));

    _paintDpad(canvas, const Offset(142, 136));
    _paintFaceButtons(canvas, const Offset(305, 88));

    _paintPill(canvas, Rect.fromCenter(center: const Offset(176, 88), width: 26, height: 11), _down("BUTTON_SELECT"), null);
    _paintPill(canvas, Rect.fromCenter(center: const Offset(224, 88), width: 26, height: 11), _down("BUTTON_START"), null);
    _paintCircle(canvas, const Offset(200, 110), 9, _down("BUTTON_MODE"), null);
  }

  void _paintShell(Canvas canvas) {
    final body = Path()..addRRect(RRect.fromLTRBR(25, 40, 375, 166, const Radius.circular(46)));
    final grips = Path()
      ..addOval(Rect.fromCircle(center: const Offset(92, 138), radius: 46))
      ..addOval(Rect.fromCircle(center: const Offset(308, 138), radius: 46));
    final shell = Path.combine(PathOperation.union, body, grips);
    canvas
      ..drawPath(shell, _shell)
      ..drawPath(shell, _outline);
  }

  void _paintStick(Canvas canvas, Offset centre, double x, double y, bool clicked) {
    const well = 26.0;
    const knob = 14.0;
    canvas
      ..drawCircle(centre, well, _idle)
      ..drawCircle(centre, well, _outline);

    final offset = Offset(centre.dx + x.clamp(-1.0, 1.0) * (well - knob), centre.dy + y.clamp(-1.0, 1.0) * (well - knob));
    final moved = x.abs() > 0.02 || y.abs() > 0.02;
    canvas
      ..drawCircle(offset, knob, clicked || moved ? _active : _shell)
      ..drawCircle(offset, knob, _outline);
  }

  void _paintDpad(Canvas canvas, Offset centre) {
    final hatX = _axis("AXIS_HAT_X");
    final hatY = _axis("AXIS_HAT_Y");
    final arms = <(Rect, bool)>[
      (Rect.fromLTRB(centre.dx - 7, centre.dy - 25, centre.dx + 7, centre.dy - 6), hatY < -0.5 || _down("DPAD_UP")),
      (Rect.fromLTRB(centre.dx - 7, centre.dy + 6, centre.dx + 7, centre.dy + 25), hatY > 0.5 || _down("DPAD_DOWN")),
      (Rect.fromLTRB(centre.dx - 25, centre.dy - 7, centre.dx - 6, centre.dy + 7), hatX < -0.5 || _down("DPAD_LEFT")),
      (Rect.fromLTRB(centre.dx + 6, centre.dy - 7, centre.dx + 25, centre.dy + 7), hatX > 0.5 || _down("DPAD_RIGHT")),
    ];

    for (final (rect, on) in arms) {
      final shape = RRect.fromRectAndRadius(rect, const Radius.circular(3));
      canvas
        ..drawRRect(shape, on ? _active : _idle)
        ..drawRRect(shape, _outline);
    }
    final hub = RRect.fromRectAndRadius(Rect.fromCenter(center: centre, width: 14, height: 14), const Radius.circular(2));
    canvas
      ..drawRRect(hub, _idle)
      ..drawRRect(hub, _outline);
  }

  void _paintFaceButtons(Canvas canvas, Offset centre) {
    const spread = 21.0;
    _paintCircle(canvas, centre.translate(0, spread), 13, _down("BUTTON_A"), "A");
    _paintCircle(canvas, centre.translate(spread, 0), 13, _down("BUTTON_B"), "B");
    _paintCircle(canvas, centre.translate(-spread, 0), 13, _down("BUTTON_X"), "X");
    _paintCircle(canvas, centre.translate(0, -spread), 13, _down("BUTTON_Y"), "Y");
  }

  void _paintCircle(Canvas canvas, Offset centre, double radius, bool on, String? label) {
    canvas
      ..drawCircle(centre, radius, on ? _active : _idle)
      ..drawCircle(centre, radius, _outline);
    if (label != null) {
      _paintLabel(canvas, centre, label, on ? scheme.onPrimary : scheme.onSurfaceVariant);
    }
  }

  void _paintPill(Canvas canvas, Rect rect, bool on, String? label) {
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    canvas
      ..drawRRect(shape, on ? _active : _idle)
      ..drawRRect(shape, _outline);
    if (label != null) {
      _paintLabel(canvas, rect.center, label, on ? scheme.onPrimary : scheme.onSurfaceVariant);
    }
  }

  void _paintTrigger(Canvas canvas, Rect rect, double value, String label) {
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    canvas.drawRRect(shape, _idle);
    if (value > 0) {
      canvas
        ..save()
        ..clipRect(Rect.fromLTWH(rect.left, rect.top, rect.width * value, rect.height))
        ..drawRRect(shape, _active)
        ..restore();
    }
    canvas.drawRRect(shape, _outline);
    _paintLabel(canvas, rect.center, label, value > 0.5 ? scheme.onPrimary : scheme.onSurfaceVariant);
  }

  void _paintLabel(Canvas canvas, Offset centre, String text, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, centre - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(_GamepadPainter old) =>
      !setEquals(old.pressed, pressed) || !mapEquals(old.axes, axes) || old.scheme != scheme;
}
