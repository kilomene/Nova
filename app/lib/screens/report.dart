import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';

/// Reusable report dialog (videos, comments, users, live sessions).
/// Rights-holder takedowns use the 'copyright' reason.
class ReportDialog extends StatefulWidget {
  final String targetType; // video | comment | user | live
  final String targetId;
  const ReportDialog({super.key, required this.targetType, required this.targetId});

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  String _reason = 'nudity';
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1a1a1a),
      title: const Text('Report', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioGroup<String>(
            groupValue: _reason,
            onChanged: (v) => setState(() => _reason = v!),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final r in ReportReasons.all)
                  RadioListTile<String>(
                    value: r,
                    title: Text(ReportReasons.labels[r]!, style: TextStyle(color: Colors.white, fontSize: 14)),
                    activeColor: Theme.of(context).colorScheme.primary,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Theme.of(context).colorScheme.onPrimary),
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    await context.read<AppState>().submitReport(
                          targetType: widget.targetType,
                          targetId: widget.targetId,
                          reason: _reason,
                        );
                    if (context.mounted) {
                      Navigator.of(context).pop(true);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted. Our reviewers will take a look.')));
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Report failed: ${e is ApiException ? e.message : e}')));
                      Navigator.of(context).pop(false);
                    }
                  }
                },
          child: Text(_busy ? 'Sending…' : 'Submit report'),
        ),
      ],
    );
  }
}

Future<void> showReportDialog(BuildContext context, {required String targetType, required String targetId}) {
  return showDialog(
    context: context,
    builder: (_) => ReportDialog(targetType: targetType, targetId: targetId),
  );
}
