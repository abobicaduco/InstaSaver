import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/media_item.dart';
import '../services/download_queue_service.dart';
import '../theme/app_theme.dart';

enum _PageType { feed, post, profile, reels, explore, stories, accounts, other }

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? _ctrl;
  _PageType _pageType = _PageType.other;
  String? _profileUsername;
  final List<MediaItem> _media = [];
  final Set<String> _seenUrls = {};
  bool _scraping = false;
  bool _pageLoading = false;
  double _webProgress = 0;
  StreamSubscription<void>? _queueSub;
  int _queueCount = 0;

  static const _loginUrl = 'https://www.instagram.com/accounts/login/';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  // ── JavaScript injection ──────────────────────────────────────────────────
  static const _js = r'''
(function() {
  if (window.__abobiOk) return;
  window.__abobiOk = true;

  function notify(type, data) {
    try { window.flutter_inappwebview.callHandler('onAbobi', JSON.stringify({type:type,data:data})); }
    catch(e) {}
  }

  // ── JSON tree scanner for media URLs ─────────────────────────────────────
  function scanObj(o, d, out) {
    if (!o || typeof o !== 'object' || d > 14) return;
    if (Array.isArray(o)) {
      for (var i=0; i<Math.min(o.length,60); i++) scanObj(o[i], d+1, out);
      return;
    }
    // Carousel web GraphQL
    if (o.edge_sidecar_to_children && o.edge_sidecar_to_children.edges) {
      o.edge_sidecar_to_children.edges.forEach(function(e) {
        var n = e&&e.node; if(!n) return;
        if (n.is_video && n.video_url) out.push({t:'video',url:n.video_url,q:''});
        else if (n.display_url) out.push({t:'photo',url:n.display_url,q:''});
      });
    }
    // Carousel mobile API
    if (o.carousel_media && Array.isArray(o.carousel_media)) {
      o.carousel_media.forEach(function(m){ scanObj(m, d+1, out); });
    }
    // Web format — best resolution
    if (o.display_resources && o.display_resources.length) {
      var b = o.display_resources[o.display_resources.length-1];
      if (b&&b.src) out.push({t:'photo',url:b.src,q:(b.config_width||'')+'x'+(b.config_height||'')});
    }
    if (o.display_url && !o.edge_sidecar_to_children && !o.display_resources) {
      out.push({t:'photo',url:o.display_url,q:''});
    }
    if (o.video_url) out.push({t:'video',url:o.video_url,q:''});
    // Mobile API format
    if (o.image_versions2 && o.image_versions2.candidates && o.image_versions2.candidates.length) {
      var c = o.image_versions2.candidates[0];
      if (c&&c.url) out.push({t:'photo',url:c.url,q:(c.width||'')+'x'+(c.height||'')});
    }
    if (o.video_versions && o.video_versions.length) {
      var v = o.video_versions[0];
      if (v&&v.url) out.push({t:'video',url:v.url,q:(v.width||'')+'x'+(v.height||'')});
    }
    var keys = Object.keys(o);
    for (var j=0; j<Math.min(keys.length,40); j++) {
      var vv = o[keys[j]];
      if (vv && typeof vv === 'object') scanObj(vv, d+1, out);
    }
  }

  function processJson(text) {
    try {
      var raw = [];
      scanObj(JSON.parse(text), 0, raw);
      var clean = raw.filter(function(m) {
        return m.url && m.url.length > 20 &&
          !m.url.includes('150x150') && !m.url.includes('s320x320') &&
          !m.url.includes('profile_pic') && !m.url.includes('_s150');
      });
      if (clean.length) notify('media', clean);
    } catch(e) {}
  }

  // ── Intercept fetch ───────────────────────────────────────────────────────
  var _oFetch = window.fetch;
  window.fetch = function() {
    var args = arguments;
    var url = typeof args[0]==='string' ? args[0] : (args[0]&&args[0].url||'');
    return _oFetch.apply(this, args).then(function(res) {
      if (/graphql|api\/v1|timeline|media|stories/.test(url))
        res.clone().text().then(processJson).catch(function(){});
      return res;
    });
  };

  // ── Intercept XHR ────────────────────────────────────────────────────────
  var _oO = XMLHttpRequest.prototype.open, _oS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m,u){ this.__u=u||''; return _oO.apply(this,arguments); };
  XMLHttpRequest.prototype.send = function() {
    if (/graphql|api\/v1|timeline|media|stories/.test(this.__u||''))
      this.addEventListener('load', function(){ processJson(this.responseText); });
    return _oS.apply(this, arguments);
  };

  // ── DOM scanner (fallback) ────────────────────────────────────────────────
  function scanDOM() {
    var out = [];
    document.querySelectorAll('video[src]').forEach(function(v){
      if (v.src && v.src.includes('.mp4')) out.push({t:'video',url:v.src,q:'dom'});
    });
    document.querySelectorAll('article img[src], div[role="presentation"] img[src]').forEach(function(img){
      var s = img.src;
      if (s && !s.includes('150x150') && !s.includes('s320x320') && !s.includes('profile_pic') &&
          (s.includes('cdninstagram') || s.includes('fbcdn'))) {
        out.push({t:'photo',url:s,q:'dom'});
      }
    });
    if (out.length) notify('media', out);
  }

  // ── Hide Instagram's bottom nav ───────────────────────────────────────────
  function hideInstagramNav() {
    if (!document.getElementById('__abobiStyle')) {
      var st = document.createElement('style');
      st.id = '__abobiStyle';
      st.textContent = '[data-bloks-name*="app"]{display:none!important}';
      (document.head||document.documentElement).appendChild(st);
    }
    // Find bottom-fixed nav elements by computed position
    document.querySelectorAll('nav, footer, [role="navigation"], [role="tablist"]').forEach(function(el){
      try {
        var rect = el.getBoundingClientRect();
        if (rect.top > window.innerHeight * 0.7 && rect.height > 35 && rect.height < 140 && rect.width > 200) {
          el.style.setProperty('display', 'none', 'important');
          el.setAttribute('data-abobi-hidden', '1');
        }
      } catch(e) {}
    });
  }

  // ── Page type detector ────────────────────────────────────────────────────
  var _lastPath = '';
  function detectPage() {
    var path = location.pathname;
    if (path === _lastPath) return;
    _lastPath = path;
    var type = 'other', extra = {};
    if (path==='/' || path==='') type='feed';
    else if (/^\/p\/[^\/]+\/?$/.test(path))   { type='post'; extra.shortcode=path.split('/')[2]; }
    else if (/^\/reel\/[^\/]+\/?$/.test(path)) { type='post'; extra.shortcode=path.split('/')[2]; }
    else if (/^\/reels/.test(path))   type='reels';
    else if (/^\/explore/.test(path)) type='explore';
    else if (/^\/stories/.test(path)) type='stories';
    else if (/^\/accounts/.test(path)) type='accounts';
    else if (/^\/direct/.test(path))  type='direct';
    else if (/^\/[a-zA-Z0-9_.]+\/?$/.test(path)) { type='profile'; extra.username=path.split('/')[1]; }
    notify('page', {type:type, url:location.href, extra:extra});
  }

  // ── Profile scraper (auto-scroll) ─────────────────────────────────────────
  window.__abobiScrapeProfile = async function() {
    notify('scrapeStart', {});
    var prevH = 0, noChange = 0, rounds = 0;
    while (noChange < 3 && rounds < 80) {
      window.scrollBy(0, 1400);
      await new Promise(function(r){ setTimeout(r, 1800); });
      var h = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
      if (h === prevH) noChange++; else { noChange = 0; prevH = h; }
      rounds++;
    }
    window.scrollTo(0, 0);
    notify('scrapeDone', {});
  };

  // ── SPA navigation listener ───────────────────────────────────────────────
  var _oP = history.pushState, _oR = history.replaceState;
  history.pushState    = function(){ _oP.apply(this,arguments); setTimeout(detectPage, 600); };
  history.replaceState = function(){ _oR.apply(this,arguments); setTimeout(detectPage, 600); };
  window.addEventListener('popstate', function(){ setTimeout(detectPage, 600); });

  // ── Init ─────────────────────────────────────────────────────────────────
  setTimeout(function(){ hideInstagramNav(); detectPage(); scanDOM(); }, 1000);
  setInterval(function(){ hideInstagramNav(); detectPage(); scanDOM(); }, 3000);
  document.addEventListener('scroll', function(){ setTimeout(scanDOM, 700); }, {passive:true});
})();
''';

  @override
  void initState() {
    super.initState();
    _queueSub = DownloadQueueService.stream.listen((_) {
      if (mounted) {
        setState(() {
          _queueCount = DownloadQueueService.active + DownloadQueueService.pending;
        });
      }
    });
  }

  @override
  void dispose() {
    _queueSub?.cancel();
    super.dispose();
  }

  // ── JS message handler ────────────────────────────────────────────────────
  void _onAbobiMsg(String raw) {
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final data = msg['data'];
      switch (type) {
        case 'media':
          if (data is List) {
            var changed = false;
            for (final item in data) {
              final m = MediaItem.fromMap(item as Map<String, dynamic>);
              if (m.url.isNotEmpty && !_seenUrls.contains(m.url)) {
                _seenUrls.add(m.url);
                _media.add(m);
                changed = true;
              }
            }
            if (changed && mounted) setState(() {});
          }
        case 'page':
          _onPageChange(data as Map?);
        case 'scrapeStart':
          if (mounted) setState(() => _scraping = true);
        case 'scrapeDone':
          if (!mounted) return;
          setState(() => _scraping = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Perfil carregado: ${_media.length} mídias encontradas'),
            backgroundColor: AppTheme.primary,
          ));
      }
    } catch (_) {}
  }

  void _onPageChange(Map? data) {
    if (data == null || !mounted) return;
    final str = data['type'] as String? ?? 'other';
    final extra = (data['extra'] as Map?) ?? {};
    final pt = switch (str) {
      'feed'     => _PageType.feed,
      'post'     => _PageType.post,
      'profile'  => _PageType.profile,
      'reels'    => _PageType.reels,
      'explore'  => _PageType.explore,
      'stories'  => _PageType.stories,
      'accounts' => _PageType.accounts,
      _          => _PageType.other,
    };
    setState(() {
      _pageType = pt;
      _profileUsername = extra['username'] as String?;
    });
  }

  void _clearMedia() {
    _media.clear();
    _seenUrls.clear();
    _scraping = false;
  }

  void _navigate(String path) =>
      _ctrl?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.instagram.com$path')));

  void _openDownloadSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (_) => _DownloadSheet(
        pageType: _pageType,
        media: List.from(_media),
        profileUsername: _profileUsername,
        scraping: _scraping,
        onDownload: (items) {
          Navigator.pop(context);
          DownloadQueueService.enqueue(items);
          Navigator.pushNamed(context, '/downloads');
        },
        onScrapeProfile: () {
          Navigator.pop(context);
          setState(() { _media.clear(); _seenUrls.clear(); _scraping = true; });
          _ctrl?.evaluateJavascript(source: 'window.__abobiScrapeProfile()');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottomPad = mq.padding.bottom;
    const navH = 56.0;

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
        body: Stack(
          children: [
            // ── WebView ───────────────────────────────────────────────────
            Positioned.fill(
              bottom: navH + bottomPad,
              child: InAppWebView(
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
                ),
                onWebViewCreated: (c) {
                  _ctrl = c;
                  c.addJavaScriptHandler(
                    handlerName: 'onAbobi',
                    callback: (args) {
                      if (args.isNotEmpty) _onAbobiMsg(args[0] as String);
                    },
                  );
                },
                onProgressChanged: (c, p) => setState(() {
                  _webProgress = p / 100.0;
                  _pageLoading = p < 100;
                }),
                shouldOverrideUrlLoading: (c, action) async {
                  final uri = action.request.url;
                  if (uri != null && uri.scheme != 'https' && uri.scheme != 'http') {
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
                onLoadStart: (c, url) async {
                  setState(_clearMedia);
                  await Future.delayed(const Duration(milliseconds: 300));
                  c.evaluateJavascript(source: _js);
                },
                onLoadStop: (c, url) async {
                  await c.evaluateJavascript(source: _js);
                },
              ),
            ),

            // ── Page loading bar ──────────────────────────────────────────
            if (_pageLoading)
              Positioned(
                top: mq.padding.top, left: 0, right: 0,
                child: LinearProgressIndicator(
                  value: _webProgress,
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
                  minHeight: 3,
                ),
              ),

            // ── Profile scraping indicator ────────────────────────────────
            if (_scraping)
              Positioned(
                bottom: navH + bottomPad + 12,
                left: 16, right: 16,
                child: Material(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(14),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: AppTheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Carregando perfil… ${_media.length} mídias encontradas',
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── Instagram-style bottom nav ────────────────────────────────
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: _IgNavBar(
                bottomPad: bottomPad,
                pageType: _pageType,
                mediaCount: _media.length,
                queueCount: _queueCount,
                onHome: () => _navigate('/'),
                onSearch: () => _navigate('/explore/'),
                onDownload: _openDownloadSheet,
                onReels: () => _navigate('/reels/'),
                onProfile: () => _navigate('/accounts/edit/'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Instagram-style nav bar ───────────────────────────────────────────────────

class _IgNavBar extends StatelessWidget {
  const _IgNavBar({
    required this.bottomPad,
    required this.pageType,
    required this.mediaCount,
    required this.queueCount,
    required this.onHome,
    required this.onSearch,
    required this.onDownload,
    required this.onReels,
    required this.onProfile,
  });

  final double bottomPad;
  final _PageType pageType;
  final int mediaCount;
  final int queueCount;
  final VoidCallback onHome, onSearch, onDownload, onReels, onProfile;

  @override
  Widget build(BuildContext context) {
    final badgeN = queueCount > 0 ? queueCount : mediaCount;
    return Container(
      height: 56 + bottomPad,
      padding: EdgeInsets.only(bottom: bottomPad),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: Color(0xFF2A2A3E), width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Tab(Icons.home_outlined, Icons.home_rounded,
              pageType == _PageType.feed, onHome),
          _Tab(Icons.search_rounded, Icons.search_rounded,
              pageType == _PageType.explore, onSearch),

          // Center download button — gradient rounded square
          GestureDetector(
            onTap: onDownload,
            child: SizedBox(
              width: 48,
              height: 56,
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppTheme.primary, AppTheme.secondary],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(11),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primary.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.download_rounded,
                          color: Colors.white, size: 22),
                    ),
                    if (badgeN > 0)
                      Positioned(
                        top: -4, right: -6,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.tertiary,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '$badgeN',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          _Tab(Icons.slow_motion_video_rounded, Icons.slow_motion_video_rounded,
              pageType == _PageType.reels, onReels),
          _Tab(Icons.person_outline_rounded, Icons.person_rounded,
              pageType == _PageType.profile || pageType == _PageType.accounts,
              onProfile),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.icon, this.filledIcon, this.active, this.onTap);
  final IconData icon, filledIcon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            active ? filledIcon : icon,
            color: active ? AppTheme.primary : Colors.white70,
            size: 28,
          ),
        ),
      );
}

// ── Download bottom sheet ─────────────────────────────────────────────────────

class _DownloadSheet extends StatelessWidget {
  const _DownloadSheet({
    required this.pageType,
    required this.media,
    required this.profileUsername,
    required this.scraping,
    required this.onDownload,
    required this.onScrapeProfile,
  });

  final _PageType pageType;
  final List<MediaItem> media;
  final String? profileUsername;
  final bool scraping;
  final void Function(List<MediaItem>) onDownload;
  final VoidCallback onScrapeProfile;

  List<MediaItem> get photos => media.where((m) => !m.isVideo).toList();
  List<MediaItem> get videos => media.where((m) => m.isVideo).toList();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          ...(pageType == _PageType.profile
              ? _profileContent()
              : pageType == _PageType.post
                  ? _postContent()
                  : _generalContent()),
        ],
      ),
    );
  }

  List<Widget> _profileContent() => [
        // Header
        Row(children: [
          const Icon(Icons.person_rounded, color: AppTheme.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                profileUsername != null ? '@$profileUsername' : 'Perfil',
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
              ),
              Text(
                '${media.length} mídias detectadas${scraping ? ' (carregando…)' : ''}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ]),
          ),
          if (scraping)
            const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
            ),
        ]),
        const SizedBox(height: 16),
        // Load all button
        if (!scraping)
          _SheetBtn(
            icon: Icons.autorenew_rounded,
            label: 'Carregar perfil completo',
            subtitle: 'Rola até o fim para encontrar todas as publicações',
            color: AppTheme.primary,
            onTap: onScrapeProfile,
          ),
        if (!scraping && media.isNotEmpty) ...[
          const Divider(color: Colors.white10, height: 24),
          // Download options
          _SheetBtn(
            icon: Icons.photo_library_rounded,
            label: 'Fotos (${photos.length})',
            color: AppTheme.tertiary,
            onTap: photos.isEmpty ? null : () => onDownload(photos),
          ),
          const SizedBox(height: 8),
          _SheetBtn(
            icon: Icons.videocam_rounded,
            label: 'Vídeos (${videos.length})',
            color: AppTheme.secondary,
            onTap: videos.isEmpty ? null : () => onDownload(videos),
          ),
          const SizedBox(height: 8),
          _SheetBtn(
            icon: Icons.download_for_offline_rounded,
            label: 'Baixar tudo (${media.length})',
            color: AppTheme.primary,
            onTap: () => onDownload(media),
          ),
        ],
        if (!scraping && media.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              'Nenhuma mídia detectada ainda. Toque em "Carregar perfil completo" para buscar tudo.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
      ];

  List<Widget> _postContent() => [
        // Header
        Row(children: [
          const Icon(Icons.photo_library_rounded, color: AppTheme.primary, size: 20),
          const SizedBox(width: 8),
          Text(
            media.length == 1
                ? (media.first.isVideo ? 'Vídeo detectado' : 'Foto detectada')
                : '${media.length} mídias nesta publicação',
            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
          ),
        ]),
        const SizedBox(height: 16),
        if (media.length > 1) ...[
          _SheetBtn(
            icon: Icons.download_for_offline_rounded,
            label: 'Baixar tudo (${media.length} itens)',
            color: AppTheme.primary,
            onTap: () => onDownload(media),
          ),
          const SizedBox(height: 8),
        ],
        if (photos.isNotEmpty) ...[
          _SheetBtn(
            icon: Icons.photo_rounded,
            label: photos.length == 1 ? 'Baixar foto' : 'Fotos (${photos.length})',
            color: AppTheme.tertiary,
            onTap: () => onDownload(photos),
          ),
          const SizedBox(height: 8),
        ],
        if (videos.isNotEmpty)
          _SheetBtn(
            icon: Icons.videocam_rounded,
            label: videos.length == 1 ? 'Baixar vídeo' : 'Vídeos (${videos.length})',
            color: AppTheme.secondary,
            onTap: () => onDownload(videos),
          ),
        if (media.isEmpty)
          const Text(
            'Nenhuma mídia detectada. Aguarde a publicação carregar completamente e tente novamente.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
      ];

  List<Widget> _generalContent() => [
        const Text(
          'Baixar mídia',
          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          '${media.length} itens encontrados nesta página',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 16),
        if (photos.isNotEmpty) ...[
          _SheetBtn(
            icon: Icons.photo_rounded,
            label: 'Fotos (${photos.length})',
            color: AppTheme.tertiary,
            onTap: () => onDownload(photos),
          ),
          const SizedBox(height: 8),
        ],
        if (videos.isNotEmpty) ...[
          _SheetBtn(
            icon: Icons.videocam_rounded,
            label: 'Vídeos (${videos.length})',
            color: AppTheme.secondary,
            onTap: () => onDownload(videos),
          ),
          const SizedBox(height: 8),
        ],
        if (media.length > 1)
          _SheetBtn(
            icon: Icons.download_for_offline_rounded,
            label: 'Baixar tudo (${media.length})',
            color: AppTheme.primary,
            onTap: () => onDownload(media),
          ),
        if (media.isEmpty)
          const Text(
            'Nenhuma mídia detectada. Role a página para carregar conteúdo.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
      ];
}

class _SheetBtn extends StatelessWidget {
  const _SheetBtn({
    required this.icon,
    required this.label,
    required this.color,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled
          ? color.withValues(alpha: 0.13)
          : Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: enabled ? color : Colors.white24, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: enabled ? Colors.white : Colors.white38,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              if (enabled)
                Icon(Icons.chevron_right_rounded,
                    color: color.withValues(alpha: 0.6), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
