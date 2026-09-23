import 'package:flutter/material.dart';

/// Stat tile shared by the thank-you and expired upsell sheets.
/// Borderless by design: plain number-over-label, separated by hairline
/// dividers in the parent row — never a button look.
class SheetStatTile extends StatelessWidget {
  final String value;
  final String label;
  const SheetStatTile({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFFFD60A),
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hairline divider for stat rows.
class SheetStatDivider extends StatelessWidget {
  const SheetStatDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 44,
      color: Colors.white.withValues(alpha: 0.1),
    );
  }
}
