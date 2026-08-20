import "dart:async";
import "dart:math" as math;

import "package:thortoolbox/src/toolbox.dart";

class PadWatch {
  PadWatch._(this._parse, {int seconds = 20}) {
    _sub = Toolbox.gamepadWatch(seconds: seconds).listen(_onLine, onDone: _finish, onError: (Object _) => _finish());
  }

  factory PadWatch.button(String padName, {int seconds = 20}) => PadWatch._(_ButtonParser(padName), seconds: seconds);

  factory PadWatch.axis(String padName, {int seconds = 20}) => PadWatch._(_AxisParser(padName), seconds: seconds);

  final _Parser _parse;
  final Completer<String?> _done = Completer<String?>();
  late final StreamSubscription<String> _sub;

  Future<String?> get result => _done.future;

  Future<void> cancel() async {
    _finish();
    await _sub.cancel();
  }

  void _onLine(String line) {
    if (_done.isCompleted) {
      return;
    }
    final code = _parse.consume(line);
    if (code != null) {
      _done.complete(code);
      unawaited(_sub.cancel());
    }
  }

  void _finish() {
    if (!_done.isCompleted) {
      _done.complete(null);
    }
  }
}

abstract class _Parser {
  String? consume(String line);
}

class _ButtonParser implements _Parser {
  _ButtonParser(this.padName);

  final String padName;

  @override
  String? consume(String line) {
    final f = line.split("\t");
    if (f.length < 5 || f[0] != "EV" || f[2] != "KEY") {
      return null;
    }
    if (f[1] != padName || f[4] != "1") {
      return null;
    }
    return f[3];
  }
}

class _AxisParser implements _Parser {
  _AxisParser(this.padName);

  final String padName;

  final Map<String, (int, int)> _ranges = <String, (int, int)>{};
  final Map<String, int> _seenMin = <String, int>{};
  final Map<String, int> _seenMax = <String, int>{};

  static const double _triggerFraction = 0.45;

  @override
  String? consume(String line) {
    final f = line.split("\t");
    if (f.length < 5 || f[1] != padName) {
      return null;
    }

    if (f[0] == "AXIS") {
      final min = int.tryParse(f[3]);
      final max = int.tryParse(f[4]);
      if (min != null && max != null && max > min) {
        _ranges[f[2]] = (min, max);
      }
      return null;
    }

    if (f[0] != "EV" || f[2] != "ABS") {
      return null;
    }
    final code = f[3];
    final v = int.tryParse(f[4]);
    if (v == null) {
      return null;
    }
    _seenMin[code] = math.min(_seenMin[code] ?? v, v);
    _seenMax[code] = math.max(_seenMax[code] ?? v, v);

    final range = _ranges[code];
    if (range == null) {
      return null;
    }
    final travelled = (_seenMax[code]! - _seenMin[code]!) / (range.$2 - range.$1);
    return travelled >= _triggerFraction ? code : null;
  }
}
