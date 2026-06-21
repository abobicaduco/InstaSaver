# InstaSaver

Navegador do Instagram para Android com download de fotos e vídeos em qualidade máxima. Baixe mídias de publicações individuais, carrosséis completos ou o perfil inteiro de um usuário — sem precisar de API oficial.

---

## Funcionalidades

- **Navegação nativa** — Interface estilo Instagram (Home, Busca, Reels, Perfil) com o Instagram real em WebView
- **Download de post único** — Foto ou vídeo em resolução máxima detectada
- **Download de carrossel** — Todas as fotos e vídeos de uma publicação com múltiplas mídias, de uma vez
- **Download de perfil completo** — Rola o perfil automaticamente até o fim, captura todas as publicações e deixa você escolher:
  - Apenas fotos
  - Apenas vídeos
  - Tudo
- **Fila de downloads** — Progresso em tempo real de cada item, com barra global de conclusão
- **Salvo na galeria** — Mídia vai direto para o álbum `AbobiGram` no Android
- **Sem login próprio** — Usa a sessão do Instagram que já existe no WebView (cookies persistidos)

---

## Como usar

### 1. Instalar

Baixe o APK mais recente na seção [Releases](https://github.com/abobicaduco/InstaSaver/releases) e instale no Android.

> **Requisitos:** Android 6.0+ (API 23), arquitetura ARM64

### 2. Fazer login

Na primeira abertura o app abre direto na tela de login do Instagram. Faça login normalmente — a sessão fica salva nos cookies do WebView.

### 3. Baixar mídia

| Situação | O que fazer |
|----------|-------------|
| Post com 1 foto ou vídeo | Toque ⬇️ → "Baixar foto" ou "Baixar vídeo" |
| Carrossel (várias mídias) | Toque ⬇️ → "Baixar tudo (N itens)" |
| Perfil de um usuário | Abra o perfil → toque ⬇️ → "Carregar perfil completo" → aguarde o scroll automático → escolha o tipo |

A mídia é salva automaticamente no álbum **AbobiGram** da galeria do Android.

---

## Arquitetura

```
lib/
├── main.dart                        # Inicialização, permissões, orientação
├── app.dart                         # MaterialApp + rotas
├── theme/
│   └── app_theme.dart               # Paleta de cores (roxo, vermelho, azul)
├── models/
│   └── media_item.dart              # Modelo de mídia (url, tipo, qualidade)
├── services/
│   ├── download_service.dart        # Download individual via Dio → Gal
│   └── download_queue_service.dart  # Fila sequencial com progresso via Stream
└── screens/
    ├── browser_screen.dart          # WebView + nav bar + sheet de download
    └── downloads_screen.dart        # Tela de fila e histórico de downloads
```

### Como a detecção de mídia funciona

O app injeta JavaScript no WebView a cada carregamento de página. Esse script:

1. **Intercepta `fetch` e `XMLHttpRequest`** — toda resposta da API interna do Instagram (endpoints `/graphql/`, `/api/v1/`, `/feed/timeline/`, `/stories/` etc.) é parseada em busca de URLs de mídia
2. **Varre a árvore JSON recursivamente** — detecta formatos web GraphQL (`display_resources`, `display_url`, `video_url`, `edge_sidecar_to_children`) e formato mobile (`image_versions2`, `video_versions`, `carousel_media`)
3. **Scanner DOM como fallback** — procura `<video src>` e `<img src>` visíveis dentro de `<article>` e `div[role="presentation"]`
4. **Detecta o tipo de página** — por padrão de URL (`/p/` = post, `/username/` = perfil, `/reels/` = reels etc.) e notifica o Flutter via `callHandler` para adaptar as opções do sheet de download
5. **Esconde a nav bar do Instagram** — via CSS + detecção dinâmica de elementos com `position: fixed` no rodapé, evitando sobreposição com a nav do app

### Scraping de perfil

Quando o usuário toca em "Carregar perfil completo":

1. O Flutter injeta `window.__abobiScrapeProfile()` via `evaluateJavascript`
2. A função faz `scrollBy(0, 1400)` a cada 1,8 segundos
3. Conforme o Instagram carrega mais posts via API interna, o interceptor de `fetch` captura automaticamente as URLs das mídias e as envia ao Flutter
4. O Flutter exibe um indicador flutuante com a contagem crescente: `"Carregando perfil… 47 mídias encontradas"`
5. Ao detectar 3 ciclos sem variação de `scrollHeight`, o scroll para e o controle volta ao usuário

---

## Stack técnica

| Componente | Tecnologia |
|------------|-----------|
| Framework | Flutter 3.x (Dart 3.x) |
| WebView | `flutter_inappwebview` 6.1.5 — modo Hybrid Composition |
| Download HTTP | `dio` 5.x |
| Salvar na galeria | `gal` 1.x |
| Permissões Android | `permission_handler` 11.x |
| Build Android | AGP 9.0.1, Kotlin 2.3.20, compileSdk 36 |

---

## Compilar do zero

### Pré-requisitos

- Flutter SDK 3.22 ou superior
- Android SDK com `compileSdk 36`
- Java 17

### Passos

```bash
# Clonar o repositório
git clone https://github.com/abobicaduco/InstaSaver.git
cd InstaSaver

# Instalar dependências
flutter pub get

# Build para dispositivo ARM64 (Xiaomi, Samsung, etc.)
flutter build apk --target-platform android-arm64 --release
```

O APK gerado fica em:

```
build/app/outputs/flutter-apk/app-release.apk
```

### Build para emulador x86_64

```bash
flutter build apk --target-platform android-x64 --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## Segurança e privacidade

- O app **não coleta nem transmite** nenhum dado do usuário para servidores externos
- As credenciais do Instagram ficam **somente nos cookies do WebView**, armazenados localmente no dispositivo
- Nenhuma chave de API, token ou senha está embutida no código-fonte

### O que nunca deve ir para o repositório

O `.gitignore` já cobre os arquivos sensíveis mais comuns:

| Arquivo | Motivo |
|---------|--------|
| `*.keystore` / `*.jks` | Chave de assinatura do APK |
| `key.properties` | Senhas do keystore de release |
| `.env` / `.env.*` | Variáveis de ambiente com segredos |
| `google-services.json` | Chave do Firebase |
| `GoogleService-Info.plist` | Chave do Firebase (iOS) |
| `credentials.json` | Credenciais de serviços Google |

---

## Aviso legal

Este projeto é de uso **pessoal e educacional**. O download de conteúdo do Instagram pode violar os [Termos de Uso da plataforma](https://help.instagram.com/581066165581870). Use com responsabilidade e apenas para conteúdo ao qual você tem direito.

---

## Licença

MIT © 2026 Carlos Eduardo — veja [LICENSE](LICENSE)

---

## Outros projetos

| Projeto | Descrição |
|---------|-----------|
| [abobiferramentas.com](https://abobiferramentas.com) | Site de download de APKs — MODs e FOSS para Android |
| [abobireacao](https://github.com/abobicaduco/abobireacao) | App Android para reagir a vídeos com câmera |
| [abobiplayer](https://github.com/abobicaduco/abobiplayer) | Player de vídeo local para Android (Flutter) |
| [abobi-video-downloader](https://github.com/abobicaduco/abobi-video-downloader) | Baixador Android baseado em yt-dlp |
| [DownloadManager](https://github.com/abobicaduco/DownloadManager) | Fila de downloads web com aria2 — React + Express |
| [ServerCRON](https://github.com/abobicaduco/ServerCRON) | Portal Flask com agendador de scripts e histórico SQLite |
| [abobi-shorts-upload-pipeline](https://github.com/abobicaduco/abobi-shorts-upload-pipeline) | Automação de upload para YouTube Shorts e TikTok |

---

## Apoie o projeto

Se este projeto te ajudou e você quiser contribuir:

**Chave PIX:** `f74458dc-2a36-49bd-9250-1cef4365ebb8`

> Recebedor: Carlos Eduardo — qualquer valor é bem-vindo e ajuda a manter os projetos ativos.
