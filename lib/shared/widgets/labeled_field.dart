import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ShadTheme.of(context).textTheme.small),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}
