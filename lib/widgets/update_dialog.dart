import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart';

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.info});
  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final notes = info.notes.length > 300
        ? '${info.notes.substring(0, 300)}...'
        : info.notes;
    return AlertDialog(
      title: const Text('Nova versão disponível'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Versão ${info.version} disponível!'),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(notes, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Agora não'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(context).pop();
            final uri = Uri.parse(info.downloadUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          child: const Text('Baixar'),
        ),
      ],
    );
  }
}
