class MediaItem {
  final String url;
  final bool isVideo;
  final String quality;

  const MediaItem({required this.url, required this.isVideo, this.quality = ''});

  factory MediaItem.fromMap(Map<String, dynamic> m) => MediaItem(
        url: m['url'] as String? ?? '',
        isVideo: (m['t'] as String?) == 'video',
        quality: m['q'] as String? ?? '',
      );
}
