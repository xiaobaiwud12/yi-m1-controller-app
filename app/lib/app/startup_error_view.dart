import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// What the user sees when the app could not start.
class StartupErrorView extends StatelessWidget {
  final String message;

  /// Lets the user past the diagnostic and into the app anyway.
  final VoidCallback? onDismiss;

  const StartupErrorView(this.message, {super.key, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return Material(
      color: const Color(0xFF0E0E0E),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 40),
                const SizedBox(height: 12),
                Text(l.startupFailedTitle,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(
                  l.startupFailedBody,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 14),
                SelectableText(message,
                    style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.4)),
                if (onDismiss != null) ...[
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    key: const ValueKey<String>('btn-startup-error-dismiss'),
                    onPressed: onDismiss,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: Text(l.continueToApp),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
