import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String notes;
  const UpdateInfo({required this.version, required this.downloadUrl, required this.notes});
}

class UpdateService {
  static const _owner = 'abobicaduco';
  static const _repo = 'InstaSaver';
  static const _current = '3.1.0';
  static const _prefsKey = 'update_last_check_ms';

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_prefsKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 4).inMilliseconds) return null;
      await prefs.setInt(_prefsKey, now);

      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$_owner/$_repo/releases/latest'),
      );
      req.headers.set('User-Agent', 'AboBI-App/1.0');
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      client.close();

      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (tag.isEmpty || !_isNewer(tag, _current)) return null;

      final assets = (json['assets'] as List<dynamic>);
      final arm64 = assets.where((a) => (a['name'] as String).contains('arm64')).toList();
      final apk = arm64.isNotEmpty ? arm64.first : (assets.isNotEmpty ? assets.first : null);
      final url = apk != null
          ? (apk['browser_download_url'] as String)
          : (json['html_url'] as String? ?? '');
      final notes = (json['body'] as String? ?? '').trim();
      return UpdateInfo(version: tag, downloadUrl: url, notes: notes);
    } catch (_) {
      return null;
    }
  }

  static bool _isNewer(String latest, String current) {
    List<int> parse(String v) =>
        v.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final l = parse(latest);
    final c = parse(current);
    for (var i = 0; i < 3; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return false;
  }
}
