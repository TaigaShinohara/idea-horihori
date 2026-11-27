// ignore_for_file: prefer_initializing_formals
// （httpClient / store / urlLauncher はテスト差し替え用の注入パラメータで、
//   初期化フォーマルでは既定値つき差し替えを表せないため意図的に通常代入を使う）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// ChatGPT サインイン（OAuth 2.0 + PKCE）で発生する、ユーザー向け例外。
///
/// メッセージにトークン等の秘密情報は絶対に含めない。
class ChatGptAuthException implements Exception {
  final String message;

  const ChatGptAuthException(this.message);

  @override
  String toString() => message;
}

/// トークンの保存先の抽象化（実機: flutter_secure_storage / テスト: インメモリ）。
///
/// トークンは端末内のこの保存先にのみ置き、ログや外部送信には使わない。
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// flutter_secure_storage による [TokenStore] 実装。
class SecureTokenStore implements TokenStore {
  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );
  final FlutterSecureStorage _storage;

  const SecureTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? _defaultStorage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// トークン一式（値はログに出さないこと）。
class ChatGptTokens {
  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final String? accountId;
  final DateTime expiresAt;

  const ChatGptTokens({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    this.accountId,
    required this.expiresAt,
  });
}

/// 「Sign in with ChatGPT」: Codex の公開 OAuth クライアントを使い、
/// ユーザー本人の ChatGPT サブスクリプションのトークンを端末内に取得する。
///
/// フロー: PKCE を生成 → ローカル HTTP サーバ（localhost:1455）を先に立て →
/// ブラウザで認可ページを開く → /auth/callback へのリダイレクトを受けて
/// コードをトークンに交換する。ブラウザから localhost に届かない環境向けに、
/// コードの手貼り付け（[signInWithCode]）も用意する。
class ChatGptAuthService {
  static const String clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const String authorizeUrl = 'https://auth.openai.com/oauth/authorize';
  static const String tokenUrl = 'https://auth.openai.com/oauth/token';
  static const String redirectUri = 'http://localhost:1455/auth/callback';
  static const String scope = 'openid profile email offline_access';
  static const int callbackPort = 1455;
  static const Duration tokenTimeout = Duration(seconds: 15);

  static const String _keyAccessToken = 'chatgpt_access_token';
  static const String _keyRefreshToken = 'chatgpt_refresh_token';
  static const String _keyIdToken = 'chatgpt_id_token';
  static const String _keyAccountId = 'chatgpt_account_id';
  static const String _keyExpiresAt = 'chatgpt_expires_at';

  final http.Client? _httpClient;
  final TokenStore _store;
  final Future<bool> Function(Uri uri)? _urlLauncherOverride;
  final Duration signInTimeout;

  String? _pendingVerifier;

  ChatGptAuthService({
    http.Client? httpClient,
    TokenStore? store,
    Future<bool> Function(Uri uri)? urlLauncher,
    this.signInTimeout = const Duration(minutes: 5),
  }) : _httpClient = httpClient,
       _store = store ?? const SecureTokenStore(),
       _urlLauncherOverride = urlLauncher;


  // ---------------------------------------------------------------------------
  // PKCE（テスト可能な静的ヘルパー）
  // ---------------------------------------------------------------------------

  static const String _verifierAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// 暗号学的に安全な乱数から code_verifier を生成する（RFC 7636）。
  static String generateCodeVerifier({int length = 64, Random? random}) {
    final rng = random ?? Random.secure();
    return List.generate(
      length,
      (_) => _verifierAlphabet[rng.nextInt(_verifierAlphabet.length)],
    ).join();
  }

  /// code_challenge = BASE64URL(SHA256(verifier))（パディングなし）。
  static String computeCodeChallenge(String codeVerifier) {
    final digest = sha256.convert(utf8.encode(codeVerifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  static String generateState({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ---------------------------------------------------------------------------
  // JWT（署名検証なし。端末内でアカウント ID を読むためだけに使う）
  // ---------------------------------------------------------------------------

  /// id_token のペイロードをデコードしてクレーム Map を返す。
  static Map<String, dynamic>? decodeJwtPayload(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = json.decode(utf8.decode(base64Url.decode(normalized)));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// id_token から ChatGPT アカウント ID を取り出す。
  static String? extractAccountId(String? idToken) {
    if (idToken == null || idToken.isEmpty) return null;
    final claims = decodeJwtPayload(idToken);
    if (claims == null) return null;
    final authClaim = claims['https://api.openai.com/auth'];
    if (authClaim is Map) {
      final id = authClaim['chatgpt_account_id'];
      if (id is String && id.isNotEmpty) return id;
    }
    final direct = claims['chatgpt_account_id'];
    if (direct is String && direct.isNotEmpty) return direct;
    return null;
  }

  // ---------------------------------------------------------------------------
  // トークンレスポンスのパース（テスト可能な静的ヘルパー）
  // ---------------------------------------------------------------------------

  static ChatGptTokens parseTokenResponse(
    Map<String, dynamic> jsonBody, {
    DateTime? now,
  }) {
    final accessToken = jsonBody['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const ChatGptAuthException('トークンの取得に失敗しました（応答にアクセストークンがありません）。');
    }
    final expiresIn = jsonBody['expires_in'];
    final lifetime = expiresIn is num
        ? Duration(seconds: expiresIn.toInt())
        : const Duration(hours: 1);
    final idToken = jsonBody['id_token'] as String?;
    return ChatGptTokens(
      accessToken: accessToken,
      refreshToken: jsonBody['refresh_token'] as String?,
      idToken: idToken,
      accountId: extractAccountId(idToken),
      expiresAt: (now ?? DateTime.now()).add(lifetime),
    );
  }

  // ---------------------------------------------------------------------------
  // サインイン
  // ---------------------------------------------------------------------------

  Uri buildAuthorizeUri({
    required String codeChallenge,
    required String state,
  }) {
    return Uri.parse(authorizeUrl).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': scope,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'state': state,
        'id_token_add_organizations': 'true',
        'codex_cli_simplified_flow': 'true',
      },
    );
  }

  Future<bool> _launch(Uri uri) async {
    if (_urlLauncherOverride != null) return _urlLauncherOverride(uri);
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// ブラウザで認可ページを開き、localhost コールバックでコードを受け取る。
  Future<void> signIn() async {
    final verifier = generateCodeVerifier();
    final state = generateState();
    _pendingVerifier = verifier;

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        callbackPort,
      );
    } catch (_) {
      _pendingVerifier = null;
      throw const ChatGptAuthException(
        'サインイン用の待ち受けを開始できませんでした。しばらくしてから再試行してください。',
      );
    }

    try {
      final uri = buildAuthorizeUri(
        codeChallenge: computeCodeChallenge(verifier),
        state: state,
      );
      final launched = await _launch(uri);
      if (!launched) {
        throw const ChatGptAuthException('ブラウザを開けませんでした。');
      }

      final request = await _waitForCallback(server);

      final params = request.uri.queryParameters;
      final error = params['error'];
      if (error != null) {
        await _respond(
          request,
          HttpStatus.badRequest,
          'サインインがキャンセルされました。この画面を閉じてアプリに戻ってください。',
        );
        throw const ChatGptAuthException('ChatGPT のサインインがキャンセルされました。');
      }
      if (params['state'] != state) {
        await _respond(
          request,
          HttpStatus.badRequest,
          'サインインの検証に失敗しました。この画面を閉じてアプリに戻ってください。',
        );
        throw const ChatGptAuthException('サインインの検証に失敗しました（state 不一致）。');
      }
      final code = params['code'];
      if (code == null || code.isEmpty) {
        await _respond(
          request,
          HttpStatus.badRequest,
          '認可コードを受け取れませんでした。この画面を閉じてアプリに戻ってください。',
        );
        throw const ChatGptAuthException('認可コードを受け取れませんでした。');
      }

      await _respond(
        request,
        HttpStatus.ok,
        'サインインが完了しました。この画面を閉じてアプリに戻ってください。',
      );
      await exchangeCodeForTokens(code, verifier);
    } catch (_) {
      _pendingVerifier = null;
      rethrow;
    } finally {
      await server.close(force: true);
    }
  }

  Future<HttpRequest> _waitForCallback(HttpServer server) async {
    final deadline = DateTime.now().add(signInTimeout);
    final iterator = StreamIterator<HttpRequest>(server);
    try {
      while (true) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw const ChatGptAuthException(
            'サインインがタイムアウトしました。もう一度お試しください。',
          );
        }
        final hasNext = await iterator.moveNext().timeout(
          remaining,
          onTimeout: () => throw const ChatGptAuthException(
            'サインインがタイムアウトしました。もう一度お試しください。',
          ),
        );
        if (!hasNext) {
          throw const ChatGptAuthException(
            'サインイン用の待ち受けが終了しました。もう一度お試しください。',
          );
        }
        final request = iterator.current;
        if (request.uri.path != '/auth/callback') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        return request;
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> _respond(HttpRequest request, int status, String message) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..write(
        '<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">'
        '<title>アイデアホリホリ</title></head><body>'
        '<p>$message</p></body></html>',
      );
    await request.response.close();
  }

  /// ブラウザから localhost に届かなかった場合の手動フロー:
  /// 認可コードを貼り付けてもらい、保留中の verifier で交換する。
  Future<void> signInWithCode(String pastedCode, {String? codeVerifier}) async {
    final verifier = codeVerifier ?? _pendingVerifier;
    if (verifier == null) {
      throw const ChatGptAuthException(
        '先に「ChatGPTでサインイン」を開始してからコードを貼り付けてください。',
      );
    }
    final code = pastedCode.trim();
    if (code.isEmpty) {
      throw const ChatGptAuthException('認可コードが入力されていません。');
    }
    await exchangeCodeForTokens(code, verifier);
  }

  /// 認可コードをトークンへ交換して保存する。
  Future<ChatGptTokens> exchangeCodeForTokens(
    String code,
    String codeVerifier,
  ) async {
    final response = await _postToken({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'client_id': clientId,
      'code_verifier': codeVerifier,
    });
    final tokens = parseTokenResponse(response);
    await _persist(tokens);
    _pendingVerifier = null;
    return tokens;
  }

  Future<Map<String, dynamic>> _postToken(Map<String, String> body) async {
    final request = http.Request('POST', Uri.parse(tokenUrl))
      ..followRedirects = false
      ..bodyFields = body;
    final ownedClient = _httpClient == null ? http.Client() : null;
    final client = _httpClient ?? ownedClient!;
    try {
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(tokenTimeout);
      if (response.statusCode != 200) {
        throw ChatGptAuthException(
          'トークンの取得に失敗しました (Status: ${response.statusCode})',
        );
      }
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const ChatGptAuthException('トークンの取得に失敗しました（応答形式が不正です）。');
      }
      return decoded;
    } on ChatGptAuthException {
      rethrow;
    } on TimeoutException {
      throw const ChatGptAuthException(
        'トークンの取得がタイムアウトしました。通信状況を確認してもう一度お試しください。',
      );
    } on http.ClientException {
      throw const ChatGptAuthException(
        '認証サーバーに接続できませんでした。通信状況を確認してください。',
      );
    } on SocketException {
      throw const ChatGptAuthException(
        '認証サーバーに接続できませんでした。通信状況を確認してください。',
      );
    } on FormatException {
      throw const ChatGptAuthException('トークンの取得に失敗しました（応答形式が不正です）。');
    } finally {
      ownedClient?.close();
    }
  }

  Future<void> _persist(ChatGptTokens tokens) async {
    await _store.write(_keyAccessToken, tokens.accessToken);
    if (tokens.refreshToken != null) {
      await _store.write(_keyRefreshToken, tokens.refreshToken!);
    }
    if (tokens.idToken != null) {
      await _store.write(_keyIdToken, tokens.idToken!);
    }
    if (tokens.accountId != null) {
      await _store.write(_keyAccountId, tokens.accountId!);
    }
    await _store.write(_keyExpiresAt, tokens.expiresAt.toIso8601String());
  }

  // ---------------------------------------------------------------------------
  // 保存済みトークンの利用
  // ---------------------------------------------------------------------------

  Future<bool> get isSignedIn async {
    try {
      final token = await _store.read(_keyAccessToken);
      return token != null && token.isNotEmpty;
    } catch (_) {
      // テスト環境などセキュアストレージが無い場合は未サインイン扱い
      return false;
    }
  }

  Future<String?> getAccountId() async {
    try {
      return await _store.read(_keyAccountId);
    } catch (_) {
      return null;
    }
  }

  /// 有効なアクセストークンを返す。期限が近い（60秒以内）場合は
  /// リフレッシュトークンで更新し、ローテーションされたトークンを保存する。
  /// 未サインイン・更新失敗時は null。
  Future<String?> getValidAccessToken() async {
    String? accessToken;
    String? expiresAtRaw;
    String? refreshToken;
    try {
      accessToken = await _store.read(_keyAccessToken);
      expiresAtRaw = await _store.read(_keyExpiresAt);
      refreshToken = await _store.read(_keyRefreshToken);
    } catch (_) {
      return null;
    }
    if (accessToken == null || accessToken.isEmpty) return null;

    final expiresAt = expiresAtRaw != null
        ? DateTime.tryParse(expiresAtRaw)
        : null;
    final expiringSoon =
        expiresAt == null ||
        expiresAt.isBefore(DateTime.now().add(const Duration(seconds: 60)));
    if (!expiringSoon) return accessToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;

    try {
      final response = await _postToken({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      });
      final tokens = parseTokenResponse(response);
      // ローテーションされない場合は既存のリフレッシュトークンを保持する
      await _persist(
        ChatGptTokens(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken ?? refreshToken,
          idToken: tokens.idToken,
          accountId: tokens.accountId ?? await getAccountId(),
          expiresAt: tokens.expiresAt,
        ),
      );
      return tokens.accessToken;
    } catch (e) {
      return null;
    }
  }

  Future<void> signOut() async {
    _pendingVerifier = null;
    Object? failure;
    for (final key in const [
      _keyAccessToken,
      _keyRefreshToken,
      _keyIdToken,
      _keyAccountId,
      _keyExpiresAt,
    ]) {
      try {
        await _store.delete(key);
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) {
      throw const ChatGptAuthException(
        'サインアウトの保存削除に失敗しました。もう一度お試しください。',
      );
    }
    try {
      final remaining = await _store.read(_keyAccessToken);
      if (remaining != null && remaining.isNotEmpty) {
        throw const ChatGptAuthException(
          'サインアウトの確認に失敗しました。もう一度お試しください。',
        );
      }
    } on ChatGptAuthException {
      rethrow;
    } catch (_) {
      throw const ChatGptAuthException(
        'サインアウトの確認に失敗しました。もう一度お試しください。',
      );
    }
  }
}
