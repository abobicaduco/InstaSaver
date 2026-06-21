import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class DownloadService {
  static const _channel = MethodChannel('com.abobi.instasaver/files');

  static final _dio = Dio(BaseOptions(
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
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

  // Salva em Download/AbobiGram/fotos/ ou Download/AbobiGram/videos/
  static Future<void> download({
    required String url,
    required bool isVideo,
    void Function(double progress)? onProgress,
  }) async {
    // Permissão necessária apenas no Android < 10
    await Permission.storage.request();

    final tempDir = await getTemporaryDirectory();
    final ext = isVideo ? 'mp4' : 'jpg';
    final filename = 'IG_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final tempPath = '${tempDir.path}/$filename';

    await _dio.download(
      url,
      tempPath,
      onReceiveProgress: (recv, total) {
        if (total > 0 && onProgress != null) onProgress(recv / total);
      },
      options: Options(responseType: ResponseType.bytes),
    );

    final file = File(tempPath);
    if (!await file.exists()) throw Exception('Arquivo não encontrado após download');

    await _channel.invokeMethod<String>('saveFile', {
      'tempPath': tempPath,
      'filename': filename,
      'isVideo': isVideo,
    });
  }
}
