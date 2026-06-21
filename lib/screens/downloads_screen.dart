import 'package:flutter/material.dart';
import '../services/download_queue_service.dart';
import '../theme/app_theme.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Downloads',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          StreamBuilder<void>(
            stream: DownloadQueueService.stream,
            builder: (ctx, _) {
              final hasDone = DownloadQueueService.items
                  .any((i) => i.status == DlStatus.done || i.status == DlStatus.error);
              if (!hasDone) return const SizedBox.shrink();
              return TextButton(
                onPressed: DownloadQueueService.clear,
                child: const Text('Limpar',
                    style: TextStyle(color: AppTheme.primary)),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<void>(
        stream: DownloadQueueService.stream,
        builder: (ctx, _) {
          final items = DownloadQueueService.items;
          if (items.isEmpty) return const _EmptyState();

          final total = items.length;
          final done = DownloadQueueService.done;
          final inProgress = DownloadQueueService.active + DownloadQueueService.pending;

          return Column(
            children: [
              // Summary bar
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                color: AppTheme.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '$done de $total baixados',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                        ),
                        if (inProgress > 0)
                          Text(
                            '$inProgress restantes',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 13),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: total > 0 ? done / total : 0,
                        backgroundColor: Colors.white12,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(AppTheme.primary),
                        minHeight: 5,
                      ),
                    ),
                  ],
                ),
              ),
              // Items list
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (ctx, i) => _DlTile(item: items[i]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.photo_library_rounded,
                  size: 64, color: AppTheme.primary),
            ),
            const SizedBox(height: 24),
            const Text(
              'Mídia salva na galeria',
              style: TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Fotos e vídeos baixados ficam no álbum "AbobiGram" da galeria do Android.',
                style: TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Voltar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ),
      );
}

class _DlTile extends StatelessWidget {
  const _DlTile({required this.item});
  final DlItem item;

  @override
  Widget build(BuildContext context) {
    final (statusColor, statusIcon) = switch (item.status) {
      DlStatus.pending     => (Colors.white38, Icons.schedule_rounded),
      DlStatus.downloading => (AppTheme.primary, Icons.download_rounded),
      DlStatus.done        => (const Color(0xFF4CAF50), Icons.check_circle_rounded),
      DlStatus.error       => (AppTheme.secondary, Icons.error_rounded),
    };

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            item.media.isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
            color: item.media.isVideo ? AppTheme.secondary : AppTheme.tertiary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.media.isVideo ? 'Vídeo' : 'Foto',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                ),
                if (item.media.quality.isNotEmpty && item.media.quality != 'dom')
                  Text(item.media.quality,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
                if (item.status == DlStatus.downloading) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: item.progress > 0 ? item.progress : null,
                      backgroundColor: Colors.white12,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(AppTheme.primary),
                      minHeight: 3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Icon(statusIcon, color: statusColor, size: 22),
        ],
      ),
    );
  }
}
