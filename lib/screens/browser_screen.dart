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
  //
  // 1. Intercepta fetch/XHR para capturar URLs de máxima qualidade da API
  //    interna do Instagram (incluindo todos os slides de carrossel).
  //
  // 2. Monitora cliques no botão ⋯ (Mais opções) de cada post e, quando
  //    o menu nativo do Instagram abre, injeta nossas opções de download
  //    no topo da lista — o usuário mantém acesso às opções originais.
  static const _js = r'''
(function() {
  if (window.__abobiOk) return;
  window.__abobiOk = true;

  // ── Flutter handler ────────────────────────────────────────────────────
  function notify(type, data) {
    try { window.flutter_inappwebview.callHandler('onAbobi', JSON.stringify({type:type, data:data})); }
    catch(e) {}
  }

  // ── Cache: shortcode → mídias capturadas da API ────────────────────────
  var _cache = {};

  function storeMedia(o, d) {
    if (!o || typeof o !== 'object' || d > 14) return;
    if (Array.isArray(o)) { for (var i=0; i<Math.min(o.length,60); i++) storeMedia(o[i], d+1); return; }

    var code = o.code || o.shortcode || o.pk;
    if (code) {
      var media = [];
      // Carrossel — formato GraphQL web
      if (o.edge_sidecar_to_children && o.edge_sidecar_to_children.edges) {
        o.edge_sidecar_to_children.edges.forEach(function(e) {
          var n = e&&e.node; if(!n) return;
          if (n.is_video && n.video_url) media.push({t:'video', url:n.video_url});
          else if (n.display_url) media.push({t:'photo', url:n.display_url});
        });
      }
      // Carrossel — formato API mobile
      if (o.carousel_media) {
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

  function processJson(text) { try { storeMedia(JSON.parse(text), 0); } catch(e) {} }

  // ── Intercepção fetch ──────────────────────────────────────────────────
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

  // ── Intercepção XHR ────────────────────────────────────────────────────
  var _oO=XMLHttpRequest.prototype.open, _oS=XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open=function(m,u){this.__u=u||'';return _oO.apply(this,arguments);};
  XMLHttpRequest.prototype.send=function(){
    if(/graphql|api\/v1|timeline|media/.test(this.__u||''))
      this.addEventListener('load',function(){processJson(this.responseText);});
    return _oS.apply(this,arguments);
  };

  // ── Coleta mídias de um article (cache da API > fallback DOM) ──────────
  function getCode(article) {
    var a = article.querySelector('a[href*="/p/"],a[href*="/reel/"]');
    if (!a) return null;
    var m = a.href.match(/\/(p|reel)\/([^\/]+)\//);
    return m ? m[2] : null;
  }

  function collectMedia(article) {
    var code = getCode(article);
    if (code && _cache[code]) return _cache[code];
    var media = [];
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

  // ── Ícone SVG de download (inline, 18×18) ─────────────────────────────
  var DL_ICON = '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" style="flex-shrink:0">'
    + '<path d="M12 16l-6-6h4V3h4v7h4l-6 6z"/>'
    + '<rect x="3" y="18" width="18" height="2" rx="1"/></svg>';

  // ── Injeta nossas opções no topo do menu nativo do Instagram ───────────
  function injectIntoMenu(ul, article) {
    if (!ul || ul.querySelector('.__abobiOpt')) return;

    var media = collectMedia(article);
    var photos = media.filter(function(m){return m.t==='photo';});
    var videos = media.filter(function(m){return m.t==='video';});

    var opts = [];

    if (photos.length === 1) {
      opts.push({label:'Baixar foto', subset: photos});
    } else if (photos.length > 1) {
      opts.push({label:'Baixar 1ª foto', subset:[photos[0]]});
      opts.push({label:'Baixar todas as fotos ('+photos.length+')', subset:photos});
    }

    if (videos.length === 1) {
      opts.push({label:'Baixar vídeo', subset: videos});
    } else if (videos.length > 1) {
      opts.push({label:'Baixar 1º vídeo', subset:[videos[0]]});
      opts.push({label:'Baixar todos os vídeos ('+videos.length+')', subset:videos});
    }

    if (photos.length > 0 && videos.length > 0) {
      opts.push({label:'Baixar tudo ('+media.length+')', subset:media, accent:true});
    }

    if (opts.length === 0) {
      opts.push({label:'Mídia carregando, tente de novo', subset:[], disabled:true});
    }

    // Inserir separador e itens no topo da lista
    var frag = document.createDocumentFragment();

    opts.forEach(function(opt) {
      var li = document.createElement('li');
      li.className = '__abobiOpt';
      li.style.cssText = 'list-style:none';

      var btn = document.createElement('button');
      btn.type = 'button';
      btn.disabled = !!opt.disabled;
      btn.style.cssText = [
        'width:100%','background:none','border:none','cursor:pointer',
        'padding:14px 16px','text-align:left',
        'font-size:14px','font-family:inherit','font-weight:600',
        'color:'+(opt.accent ? '#0095f6' : (opt.disabled ? '#999' : '#262626')),
        'display:flex','align-items:center','gap:12px',
        'border-bottom:0.5px solid #dbdbdb'
      ].join(';');
      btn.innerHTML = DL_ICON + '<span>' + opt.label + '</span>';

      if (!opt.disabled) {
        btn.addEventListener('click', function(e) {
          e.stopPropagation();
          if (opt.subset.length) notify('downloadRequest', opt.subset);
          // Fecha o menu do Instagram
          document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
        });
      }

      li.appendChild(btn);
      frag.appendChild(li);
    });

    // Separador visual entre nossas opções e as nativas
    var sep = document.createElement('li');
    sep.className = '__abobiOpt';
    sep.style.cssText = 'list-style:none;height:6px;background:#fafafa;border-bottom:0.5px solid #dbdbdb';
    frag.appendChild(sep);

    ul.insertBefore(frag, ul.firstChild);
  }

  // ── Rastreia qual article teve o ⋯ clicado ────────────────────────────
  var _pendingArticle = null;
  var _pendingTimer = null;

  document.addEventListener('click', function(e) {
    var btn = e.target.closest('button');
    if (!btn || !btn.querySelector('svg')) return;

    var article = btn.closest('article');
    if (!article) return;

    // O botão ⋯ fica no <header> do article, não na <section> de ações
    var header  = article.querySelector('header');
    var section = article.querySelector('section');
    if (!header || !header.contains(btn)) return; // não é do cabeçalho
    if (section && section.contains(btn)) return;  // é da barra de ações

    // Ignora botão de seguir/deixar de seguir
    var label = (btn.getAttribute('aria-label') || '').toLowerCase();
    if (label.includes('follow') || label.includes('seguir') ||
        label.includes('unfollow') || label.includes('deixar')) return;

    // É o botão ⋯ — registra o article e aguarda o menu abrir
    _pendingArticle = article;
    if (_pendingTimer) clearTimeout(_pendingTimer);
    _pendingTimer = setTimeout(function(){ _pendingArticle = null; }, 3000);
  }, true);

  // ── MutationObserver: detecta menu nativo do Instagram abrindo ─────────
  new MutationObserver(function(mutations) {
    if (!_pendingArticle) return;
    mutations.forEach(function(m) {
      m.addedNodes.forEach(function(node) {
        if (node.nodeType !== 1) return;

        // Procura <ul> dentro de um contexto de diálogo/modal
        var candidates = node.tagName === 'UL' ? [node]
                       : Array.from(node.querySelectorAll('ul'));

        candidates.forEach(function(ul) {
          if (ul.children.length < 2) return;

          // Confirma que está num overlay/dialog (posição fixed ou role=dialog)
          var el = ul;
          for (var depth=0; depth<6 && el && el!==document.body; depth++, el=el.parentElement) {
            var role = el.getAttribute('role')||'';
            var pos  = window.getComputedStyle(el).position;
            if (role==='dialog' || role==='menu' || pos==='fixed' || pos==='absolute') {
              if (_pendingTimer) { clearTimeout(_pendingTimer); _pendingTimer=null; }
              injectIntoMenu(ul, _pendingArticle);
              _pendingArticle = null;
              return;
            }
          }
        });
      });
    });
  }).observe(document.body, {childList:true, subtree:true});

})();
''';

  // ── Manipula mensagens vindas do JS ───────────────────────────────────
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
