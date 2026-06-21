import 'dart:io';
import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class DownloadService {
  static final _dio = Dio(BaseOptions(
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      'Referer': 'https://www.instagram.com/',
      'Accept': '*/*',
      'Accept-Language': 'pt-BR,pt;q=0.9,en;q=0.8',
      'Origin': 'https://www.instagram.com',
    },
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 120),
    followRedirects: true,
    maxRedirects: 5,
  ));

  static Future<void> download({
    required String url,
    required bool isVideo,
    void Function(double progress)? onProgress,
  }) async {
    await [Permission.storage, Permission.photos, Permission.videos].request();
    await Gal.requestAccess();

    final tempDir = await getTemporaryDirectory();
    final ext = isVideo ? 'mp4' : 'jpg';
    final filename = 'abobigram_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final savePath = '${tempDir.path}/$filename';

    await _dio.download(
      url,
      savePath,
      onReceiveProgress: (recv, total) {
        if (total > 0 && onProgress != null) onProgress(recv / total);
      },
      options: Options(responseType: ResponseType.bytes),
    );

    final file = File(savePath);
    if (!await file.exists()) throw Exception('Arquivo não encontrado após download');

    if (isVideo) {
      await Gal.putVideo(savePath, album: 'AbobiGram');
    } else {
      await Gal.putImage(savePath, album: 'AbobiGram');
    }

    await file.delete();
  }
}
