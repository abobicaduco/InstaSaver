import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/media_item.dart';
import '../services/download_queue_service.dart';
import '../services/update_service.dart';
import '../widgets/update_dialog.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? _ctrl;
  StreamSubscription<void>? _dlSub;

  static const _loginUrl = 'https://www.instagram.com/accounts/login/';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36 '
      'Instagram/275.0.0.27.98';

  // ── JavaScript injetado ─────────────────────────────────────────────────
  //
  // 1. Intercepta fetch/XHR para capturar URLs em qualidade máxima da API
  //    interna do Instagram (suporta posts únicos e carrosséis completos).
  //
  // 2. Detecta o clique no botão ⋯ (mais opções) de cada post.
  //    Previne o menu nativo do Instagram e chama o Flutter com as mídias
  //    do post. O Flutter mostra o BottomSheet com as opções de download.
  //    Um botão "Ver opções do Instagram" reabre o menu nativo se necessário.
  static const _js = r'''
(function() {
  if (window.__abobiOk) return;
  window.__abobiOk = true;

  // ── Flutter channel ────────────────────────────────────────────────────
  function notify(type, data) {
    try { window.flutter_inappwebview.callHandler('onAbobi', JSON.stringify({type:type, data:data})); }
    catch(e) { console.warn('[abobi] notify failed:', e); }
  }

  // ── Cache: shortcode → mídias capturadas da API ────────────────────────
  var _cache = {};

  function storeMedia(o, d) {
    if (!o || typeof o !== 'object' || d > 14) return;
    if (Array.isArray(o)) {
      for (var i=0; i<Math.min(o.length,60); i++) storeMedia(o[i], d+1);
      return;
    }
    var code = o.code || o.shortcode || o.pk;
    if (code && String(code).length > 4) {
      var media = [];
      // Carrossel — GraphQL web
      if (o.edge_sidecar_to_children && o.edge_sidecar_to_children.edges) {
        o.edge_sidecar_to_children.edges.forEach(function(e) {
          var n=e&&e.node; if(!n) return;
          if(n.is_video && n.video_url) media.push({t:'video',url:n.video_url});
          else if(n.display_url) media.push({t:'photo',url:n.display_url});
        });
      }
      // Carrossel — API mobile
      if (o.carousel_media && Array.isArray(o.carousel_media)) {
        o.carousel_media.forEach(function(m) {
          var c=m.image_versions2&&m.image_versions2.candidates&&m.image_versions2.candidates[0];
          if(c&&c.url) media.push({t:'photo',url:c.url});
          var v=m.video_versions&&m.video_versions[0];
          if(v&&v.url) media.push({t:'video',url:v.url});
        });
      }
      // Post único
      if (!media.length) {
        var res=o.display_resources;
        if(res&&res.length){var b=res[res.length-1];if(b&&b.src)media.push({t:'photo',url:b.src});}
        else if(o.display_url) media.push({t:'photo',url:o.display_url});
        if(o.video_url) media.push({t:'video',url:o.video_url});
        var c2=o.image_versions2&&o.image_versions2.candidates&&o.image_versions2.candidates[0];
        if(c2&&c2.url) media.push({t:'photo',url:c2.url});
        var v2=o.video_versions&&o.video_versions[0];
        if(v2&&v2.url) media.push({t:'video',url:v2.url});
      }
      if (media.length && !_cache[code]) {
        _cache[code] = media;
        console.log('[abobi] cached', media.length, 'items for', code);
      }
    }
    var keys=Object.keys(o);
    for(var j=0;j<Math.min(keys.length,40);j++){
      var vv=o[keys[j]];
      if(vv&&typeof vv==='object') storeMedia(vv,d+1);
    }
  }

  function processJson(text) {
    try { storeMedia(JSON.parse(text),0); } catch(e) {}
  }

  // ── Intercepta fetch ───────────────────────────────────────────────────
  var _oFetch = window.fetch;
  window.fetch = function() {
    var args=arguments;
    var url=typeof args[0]==='string'?args[0]:(args[0]&&args[0].url||'');
    return _oFetch.apply(this,args).then(function(res){
      if(/graphql|api\/v1|timeline|media|posts/.test(url))
        res.clone().text().then(processJson).catch(function(){});
      return res;
    });
  };

  // ── Intercepta XHR ────────────────────────────────────────────────────
  var _oO=XMLHttpRequest.prototype.open, _oS=XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open=function(m,u){this.__u=u||'';return _oO.apply(this,arguments);};
  XMLHttpRequest.prototype.send=function(){
    if(/graphql|api\/v1|timeline|media|posts/.test(this.__u||''))
      this.addEventListener('load',function(){processJson(this.responseText);});
    return _oS.apply(this,arguments);
  };

  // ── Coleta mídias a partir de um nó raiz ─────────────────────────────
  function getShortcode(root) {
    var a=root.querySelector('a[href*="/p/"],a[href*="/reel/"]');
    if(!a) return null;
    var m=a.href.match(/\/(p|reel)\/([^/?#]+)/);
    return m?m[2]:null;
  }

  // Sobe N níveis a partir do botão até encontrar o container do post
  function findPostRoot(el) {
    var cur=el, depth=0;
    while(cur && depth<12) {
      // Para quando encontrar imagem/vídeo do Instagram no container
      if(cur.querySelector('img[src*="cdninstagram"],img[src*="fbcdn"],video[src*=".mp4"]'))
        return cur;
      cur=cur.parentElement; depth++;
    }
    return el.parentElement||document.body;
  }

  function collectMedia(root) {
    var sc=getShortcode(root);
    if(sc&&_cache[sc]) { console.log('[abobi] cache hit',_cache[sc].length,'for',sc); return _cache[sc]; }
    var media=[], seen={};
    root.querySelectorAll('img[src]').forEach(function(img){
      var s=img.src;
      if(s&&(s.includes('cdninstagram')||s.includes('fbcdn'))&&
        !s.includes('150x150')&&!s.includes('profile_pic')&&
        !s.includes('s320x320')&&!s.includes('s150x150')&&!seen[s]){
        seen[s]=1; media.push({t:'photo',url:s});
      }
    });
    root.querySelectorAll('video[src]').forEach(function(v){
      if(v.src&&v.src.includes('.mp4')&&!seen[v.src]){seen[v.src]=1;media.push({t:'video',url:v.src});}
    });
    console.log('[abobi] DOM fallback:',media.length,'items from',root.tagName);
    return media;
  }

  // ── Detecção do botão ⋯ (Mais opções / More options) ─────────────────
  //
  // Estratégia: usar aria-label como critério primário.
  // O Instagram define aria-label="Mais opções" (PT-BR) ou "More options" (EN)
  // nesse botão específico. Isso é mais confiável do que depender de tags HTML
  // como <article> ou <header>, que podem mudar a qualquer update do Instagram.

  // Variações de "More options" em idiomas comuns:
  var MORE_LABELS = [
    'mais opções','more options','más opciones','plus d\'options',
    'weitere optionen','meer opties','altre opzioni','diğer seçenekler',
    'daha fazla seçenek','その他のオプション','더 보기','更多选项'
  ];

  var _lastMoreBtn = null;
  var _allowNext   = false;

  // Flutter chama isso para abrir o menu nativo após fechar nosso sheet
  window.__abobiOpenNative = function() {
    if (_lastMoreBtn) { _allowNext=true; _lastMoreBtn.click(); }
  };

  document.addEventListener('click', function(e) {
    if (_allowNext) { _allowNext=false; return; }

    var el=e.target.closest('button,[role="button"]');
    if (!el) return;

    var label=(el.getAttribute('aria-label')||'').toLowerCase().trim();

    // Verificação primária: aria-label exato ou parcial de "mais opções"
    var isMore=MORE_LABELS.some(function(l){return label===l||label.includes(l);});

    // Fallback: qualquer botão com SVG que tenha "opç" ou "option" no label
    if(!isMore) isMore=(label.includes('opç')||label.includes('option'))&&!!el.querySelector('svg');

    if(!isMore) return;

    console.log('[abobi] ⋯ detectado, label="'+label+'"');
    e.stopPropagation();
    e.preventDefault();

    _lastMoreBtn=el;
    var root=el.closest('article')||findPostRoot(el);
    var media=collectMedia(root);
    notify('showMenu',{media:media,sc:getShortcode(root)||''});
  }, true);

  console.log('[abobi] script injetado OK');
})();
''';

  // ── Mensagens do JS ──────────────────────────────────────────────────
  void _onMsg(String raw) {
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final data = msg['data'];

      switch (type) {
        case 'showMenu':
          if (data is Map) {
            final rawList = data['media'];
            final items = rawList is List
                ? rawList
                    .map((e) => MediaItem.fromMap(e as Map<String, dynamic>))
                    .where((m) => m.url.isNotEmpty)
                    .toList()
                : <MediaItem>[];
            _showDownloadSheet(items);
          }
        case 'downloadRequest':
          if (data is List) {
            final items = data
                .map((e) => MediaItem.fromMap(e as Map<String, dynamic>))
                .where((m) => m.url.isNotEmpty)
                .toList();
            _startDownload(items);
          }
      }
    } catch (e) {
      debugPrint('[BrowserScreen] _onMsg error: $e');
    }
  }

  void _startDownload(List<MediaItem> items) {
    if (items.isEmpty) return;
    DownloadQueueService.enqueue(items);
    _toast(items.length == 1
        ? (items.first.isVideo ? 'Baixando vídeo...' : 'Baixando foto...')
        : 'Baixando ${items.length} itens...');
  }

  void _showDownloadSheet(List<MediaItem> media) {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _DownloadSheet(
        media: media,
        onDownload: (items) {
          Navigator.pop(context);
          _startDownload(items);
        },
        onNativeMenu: () {
          Navigator.pop(context);
          _ctrl?.evaluateJavascript(source: 'window.__abobiOpenNative && window.__abobiOpenNative()');
        },
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: const Color(0xFF262626),
      ));
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
    _dlSub = DownloadQueueService.stream.listen((_) {
      if (!mounted) return;
      final done = DownloadQueueService.done;
      if (done > 0 && (DownloadQueueService.pending + DownloadQueueService.active) == 0) {
        _toast('Salvo em Downloads/AbobiGram! ($done ${done == 1 ? "item" : "itens"})');
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(seconds: 3));
      if (!mounted) return;
      final info = await UpdateService.checkForUpdate();
      if (info != null && mounted) {
        showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) => UpdateDialog(info: info),
        );
      }
    });
  }

  @override
  void dispose() {
    _dlSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await (_ctrl?.canGoBack() ?? Future.value(false))) {
          _ctrl?.goBack();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            databaseEnabled: true,
            cacheEnabled: true,
            userAgent: _ua,
            useShouldOverrideUrlLoading: true,
            mediaPlaybackRequiresUserGesture: false,
            supportZoom: false,
            transparentBackground: false,
            safeBrowsingEnabled: false,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
            useHybridComposition: true,
            verticalScrollBarEnabled: false,
            horizontalScrollBarEnabled: false,
          ),
          onWebViewCreated: (c) {
            _ctrl = c;
            c.addJavaScriptHandler(
              handlerName: 'onAbobi',
              callback: (args) {
                if (args.isNotEmpty) _onMsg(args[0] as String);
              },
            );
          },
          shouldOverrideUrlLoading: (c, action) async {
            final uri = action.request.url;
            if (uri != null && uri.scheme != 'https' && uri.scheme != 'http') {
              return NavigationActionPolicy.CANCEL;
            }
            return NavigationActionPolicy.ALLOW;
          },
          onLoadStart: (c, url) async {
            await Future.delayed(const Duration(milliseconds: 150));
            c.evaluateJavascript(source: _js);
          },
          onLoadStop: (c, url) async {
            await c.evaluateJavascript(source: _js);
          },
          onConsoleMessage: (c, msg) {
            if (msg.message.startsWith('[abobi]')) {
              debugPrint('WebView: ${msg.message}');
            }
          },
        ),
      ),
    );
  }
}

// ── BottomSheet de download ──────────────────────────────────────────────
class _DownloadSheet extends StatelessWidget {
  const _DownloadSheet({
    required this.media,
    required this.onDownload,
    required this.onNativeMenu,
  });

  final List<MediaItem> media;
  final void Function(List<MediaItem>) onDownload;
  final VoidCallback onNativeMenu;

  List<MediaItem> get photos => media.where((m) => !m.isVideo).toList();
  List<MediaItem> get videos => media.where((m) => m.isVideo).toList();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Título
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  const Icon(Icons.download_rounded, size: 20, color: Color(0xFF262626)),
                  const SizedBox(width: 8),
                  Text(
                    'Download',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey[900],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            if (media.isEmpty) ...[
              Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    Icon(Icons.hourglass_empty_rounded, size: 32, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text(
                      'Mídia ainda carregando.\nRole o post um pouco e tente novamente.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // ── Opções de foto ──────────────────────────────────────
              if (photos.isNotEmpty) ...[
                if (photos.length == 1)
                  _Option(
                    icon: Icons.photo_outlined,
                    label: 'Baixar foto',
                    onTap: () => onDownload(photos),
                  )
                else ...[
                  _Option(
                    icon: Icons.photo_outlined,
                    label: 'Baixar 1ª foto',
                    onTap: () => onDownload([photos.first]),
                  ),
                  _Option(
                    icon: Icons.photo_library_outlined,
                    label: 'Baixar todas as fotos (${photos.length})',
                    onTap: () => onDownload(photos),
                  ),
                ],
              ],
              // ── Opções de vídeo ─────────────────────────────────────
              if (videos.isNotEmpty) ...[
                if (videos.length == 1)
                  _Option(
                    icon: Icons.videocam_outlined,
                    label: 'Baixar vídeo',
                    onTap: () => onDownload(videos),
                  )
                else ...[
                  _Option(
                    icon: Icons.videocam_outlined,
                    label: 'Baixar 1º vídeo',
                    onTap: () => onDownload([videos.first]),
                  ),
                  _Option(
                    icon: Icons.video_library_outlined,
                    label: 'Baixar todos os vídeos (${videos.length})',
                    onTap: () => onDownload(videos),
                  ),
                ],
              ],
              // ── Baixar tudo (se tem fotos E vídeos) ─────────────────
              if (photos.isNotEmpty && videos.isNotEmpty)
                _Option(
                  icon: Icons.download_for_offline_outlined,
                  label: 'Baixar tudo (${media.length} itens)',
                  onTap: () => onDownload(media),
                  accent: true,
                ),
            ],

            const Divider(height: 1),
            // ── Ver opções nativas do Instagram ──────────────────────
            _Option(
              icon: Icons.more_horiz_rounded,
              label: 'Ver opções do Instagram',
              onTap: onNativeMenu,
              secondary: true,
            ),
            // ── Cancelar ─────────────────────────────────────────────
            _Option(
              icon: Icons.close_rounded,
              label: 'Cancelar',
              onTap: () => Navigator.pop(context),
              isCancel: true,
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
    this.secondary = false,
    this.isCancel = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;
  final bool secondary;
  final bool isCancel;

  @override
  Widget build(BuildContext context) {
    final color = isCancel
        ? Colors.grey[500]!
        : secondary
            ? Colors.grey[700]!
            : accent
                ? const Color(0xFF0095F6)
                : const Color(0xFF262626);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: color,
                fontWeight: (accent || (!secondary && !isCancel))
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
