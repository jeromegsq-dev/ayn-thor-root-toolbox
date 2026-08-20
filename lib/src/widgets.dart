import "package:flutter/material.dart";

class Hint extends StatelessWidget {
  const Hint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

class SettingSlider extends StatefulWidget {
  const SettingSlider({
    required this.title,
    required this.value,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onCommit,
    this.min = 0,
    super.key,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double value) format;
  final ValueChanged<double> onCommit;

  @override
  State<SettingSlider> createState() => _SettingSliderState();
}

class _SettingSliderState extends State<SettingSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = _dragging ?? widget.value;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(widget.title, style: theme.textTheme.titleSmall),
              Text(widget.format(value), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
          Slider(
            value: value.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: (v) => setState(() => _dragging = v),
            onChangeEnd: (v) {
              setState(() => _dragging = null);
              widget.onCommit(v);
            },
          ),
        ],
      ),
    );
  }
}

class SettingField extends StatelessWidget {
  const SettingField({required this.label, required this.controller, this.keyboardType, super.key});

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }
}
