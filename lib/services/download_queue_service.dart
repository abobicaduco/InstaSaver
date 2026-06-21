import 'dart:async';
import '../models/media_item.dart';
import 'download_service.dart';

enum DlStatus { pending, downloading, done, error }

class DlItem {
  final MediaItem media;
  DlStatus status = DlStatus.pending;
  double progress = 0;
  DlItem(this.media);
}

class DownloadQueueService {
  static final List<DlItem> items = [];
  static bool _busy = false;
  static final _ctrl = StreamController<void>.broadcast();
  static Stream<void> get stream => _ctrl.stream;

  static int get pending => items.where((i) => i.status == DlStatus.pending).length;
  static int get active => items.where((i) => i.status == DlStatus.downloading).length;
  static int get done => items.where((i) => i.status == DlStatus.done).length;

  static Future<void> enqueue(List<MediaItem> media) async {
    items.addAll(media.map(DlItem.new));
    _notify();
    if (!_busy) _run();
  }

  static Future<void> _run() async {
    _busy = true;
    while (true) {
      final next = items.where((i) => i.status == DlStatus.pending).firstOrNull;
      if (next == null) break;
      next.status = DlStatus.downloading;
      _notify();
      try {
        await DownloadService.download(
          url: next.media.url,
          isVideo: next.media.isVideo,
          onProgress: (p) {
            next.progress = p;
            _notify();
          },
        );
        next.status = DlStatus.done;
      } catch (_) {
        next.status = DlStatus.error;
      }
      _notify();
    }
    _busy = false;
  }

  static void _notify() => _ctrl.add(null);

  static void clear() {
    items.removeWhere(
        (i) => i.status == DlStatus.done || i.status == DlStatus.error);
    _notify();
  }
}
