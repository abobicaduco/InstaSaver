import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/media_item.dart';
import '../services/download_queue_service.dart';

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

  // ── JavaScript injetado em cada página ──────────────────────────────────
  // Intercepta a API interna do Instagram para capturar URLs em qualidade
  // máxima (incluindo todos os slides de carrossel), depois injeta um botão
  // de download na barra de ações de cada post (ao lado do Like/Comentar).
  static const _js = r'''
(function() {
  if (window.__abobiOk) return;
  window.__abobiOk = true;

  // ── Comunicação com Flutter ───────────────────────────────────────────────
  function notify(type, data) {
    try { window.flutter_inappwebview.callHandler('onAbobi', JSON.stringify({type:type, data:data})); }
    catch(e) {}
  }

  // ── Dicionário: shortcode → lista de mídias capturadas da API ────────────
  var _cache = {};

  function storeMedia(o, d) {
    if (!o || typeof o !== 'object' || d > 14) return;
    if (Array.isArray(o)) { for (var i=0; i<Math.min(o.length,60); i++) storeMedia(o[i], d+1); return; }

    var code = o.code || o.shortcode || o.pk;
    if (code) {
      var media = [];
      // Carrossel (GraphQL web)
      if (o.edge_sidecar_to_children && o.edge_sidecar_to_children.edges) {
        o.edge_sidecar_to_children.edges.forEach(function(e) {
          var n = e&&e.node; if(!n) return;
          if (n.is_video && n.video_url) media.push({t:'video', url:n.video_url});
          else if (n.display_url) media.push({t:'photo', url:n.display_url});
        });
      }
      // Carrossel (API mobile)
      if (o.carousel_media && Array.isArray(o.carousel_media)) {
        o.carousel_media.forEach(function(m) {
          var c = m.image_versions2&&m.image_versions2.candidates&&m.image_versions2.candidates[0];
          if (c&&c.url) media.push({t:'photo', url:c.url});
          var v = m.video_versions&&m.video_versions[0];
          if (v&&v.url) media.push({t:'video', url:v.url});
        });
      }
      // Post único
      if (!media.length) {
        var res = o.display_resources;
        if (res&&res.length) { var b=res[res.length-1]; if(b&&b.src) media.push({t:'photo',url:b.src}); }
        else if (o.display_url) media.push({t:'photo', url:o.display_url});
        if (o.video_url) media.push({t:'video', url:o.video_url});
        var c2 = o.image_versions2&&o.image_versions2.candidates&&o.image_versions2.candidates[0];
        if (c2&&c2.url) media.push({t:'photo', url:c2.url});
        var v2 = o.video_versions&&o.video_versions[0];
        if (v2&&v2.url) media.push({t:'video', url:v2.url});
      }
      if (media.length && !_cache[code]) _cache[code] = media;
    }

    var keys = Object.keys(o);
    for (var j=0; j<Math.min(keys.length,40); j++) {
      var vv = o[keys[j]];
      if (vv && typeof vv === 'object') storeMedia(vv, d+1);
    }
  }

  function processJson(text) {
    try { storeMedia(JSON.parse(text), 0); } catch(e) {}
  }

  // ── Intercepta fetch ──────────────────────────────────────────────────────
  var _oFetch = window.fetch;
  window.fetch = function() {
    var args = arguments;
    var url = typeof args[0]==='string' ? args[0] : (args[0]&&args[0].url||'');
    return _oFetch.apply(this, args).then(function(res) {
      if (/graphql|api\/v1|timeline|media/.test(url))
        res.clone().text().then(processJson).catch(function(){});
      return res;
    });
  };

  // ── Intercepta XHR ────────────────────────────────────────────────────────
  var _oO=XMLHttpRequest.prototype.open, _oS=XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open=function(m,u){this.__u=u||'';return _oO.apply(this,arguments);};
  XMLHttpRequest.prototype.send=function(){
    if(/graphql|api\/v1|timeline|media/.test(this.__u||''))
      this.addEventListener('load',function(){processJson(this.responseText);});
    return _oS.apply(this,arguments);
  };

  // ── Extrai shortcode do article ───────────────────────────────────────────
  function getCode(article) {
    var a = article.querySelector('a[href*="/p/"],a[href*="/reel/"]');
    if (!a) return null;
    var m = a.href.match(/\/(p|reel)\/([^\/]+)\//);
    return m ? m[2] : null;
  }

  // ── Coleta mídias do article (API em cache > fallback DOM) ────────────────
  function collectMedia(article) {
    var code = getCode(article);
    if (code && _cache[code]) return _cache[code];
    var media = [];
    // fallback: img/video visíveis no DOM
    article.querySelectorAll('img[src]').forEach(function(img) {
      var s = img.src;
      if (s && (s.includes('cdninstagram')||s.includes('fbcdn')) &&
          !s.includes('150x150') && !s.includes('profile_pic') && !s.includes('s320x320'))
        media.push({t:'photo', url:s});
    });
    article.querySelectorAll('video[src]').forEach(function(v) {
      if (v.src && v.src.includes('.mp4')) media.push({t:'video', url:v.src});
    });
    return media;
  }

  // ── Ícone SVG de download (estilo dos ícones do Instagram) ───────────────
  var DL_SVG = '<svg aria-label="Baixar" height="24" role="img" viewBox="0 0 24 24" '
    + 'width="24" style="display:block"><path d="M12 15.5l-5-5h3V4h4v6.5h3l-5 5z" '
    + 'fill="currentColor"/><rect x="3" y="18" width="18" height="2" rx="1" fill="currentColor"/></svg>';
  var OK_SVG  = '<svg height="24" viewBox="0 0 24 24" width="24" style="display:block">'
    + '<polyline points="20 6 9 17 4 12" stroke="currentColor" stroke-width="2.5" '
    + 'fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  // ── Injeta botão de download no article ───────────────────────────────────
  function injectBtn(article) {
    if (article.querySelector('.__abobidl')) return;
    // Aguarda a section de ações renderizar
    var section = article.querySelector('section');
    if (!section) return;

    var btn = document.createElement('button');
    btn.className = '__abobidl';
    btn.title = 'Baixar';
    btn.setAttribute('type', 'button');
    btn.style.cssText = [
      'background:none', 'border:none', 'padding:8px', 'margin:0',
      'cursor:pointer', 'color:inherit', 'display:flex',
      'align-items:center', 'justify-content:center',
      'opacity:0.9', 'flex-shrink:0'
    ].join(';');
    btn.innerHTML = DL_SVG;

    btn.addEventListener('click', function(e) {
      e.preventDefault(); e.stopPropagation();
      var media = collectMedia(article);
      if (!media.length) {
        notify('noMedia', {});
        return;
      }
      notify('downloadRequest', media);
      btn.innerHTML = OK_SVG;
      btn.style.opacity = '0.5';
      btn.disabled = true;
    });

    // Insere antes do último elemento da section (botão Salvar/Bookmark)
    var last = section.lastElementChild;
    if (last) section.insertBefore(btn, last);
    else section.appendChild(btn);
  }

  // ── MutationObserver: detecta novos posts ─────────────────────────────────
  new MutationObserver(function() {
    document.querySelectorAll('article:not([data-abobi])').forEach(function(a) {
      a.setAttribute('data-abobi', '1');
      setTimeout(function(){ injectBtn(a); }, 300);
    });
  }).observe(document.body, {childList:true, subtree:true});

  // ── Varredura periódica (fallback para SPA navigation) ────────────────────
  setInterval(function() {
    document.querySelectorAll('article').forEach(injectBtn);
  }, 2000);
  setTimeout(function(){
    document.querySelectorAll('article').forEach(injectBtn);
  }, 1200);
})();
''';

  // ── Manipula mensagens do JS ─────────────────────────────────────────────
  void _onMsg(String raw) {
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final data = msg['data'];

      switch (type) {
        case 'downloadRequest':
          if (data is List) {
            final items = data
                .map((e) => MediaItem.fromMap(e as Map<String, dynamic>))
                .where((m) => m.url.isNotEmpty)
                .toList();
            if (items.isEmpty) return;
            DownloadQueueService.enqueue(items);
            _toast(items.length == 1
                ? (items.first.isVideo ? 'Baixando vídeo...' : 'Baixando foto...')
                : 'Baixando ${items.length} itens...');
          }
        case 'noMedia':
          _toast('Mídia ainda carregando, tente novamente.');
      }
    } catch (_) {}
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
        backgroundColor: const Color(0xFF1C1C2E),
      ));
  }

  @override
  void initState() {
    super.initState();
    // Tela cheia — só a barra de status aparece
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
    ));
    _dlSub = DownloadQueueService.stream.listen((_) {
      if (!mounted) return;
      final done = DownloadQueueService.done;
      final pending = DownloadQueueService.pending + DownloadQueueService.active;
      if (done > 0 && pending == 0) {
        _toast('Salvo na galeria! ($done itens)');
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
        // Fundo branco = cor do Instagram enquanto carrega
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
            // WebView usa todo o espaço incluindo atrás da barra de sistema
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
            await Future.delayed(const Duration(milliseconds: 200));
            c.evaluateJavascript(source: _js);
          },
          onLoadStop: (c, url) async {
            await c.evaluateJavascript(source: _js);
          },
        ),
      ),
    );
  }
}
