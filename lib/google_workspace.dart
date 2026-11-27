// ignore_for_file: prefer_initializing_formals
// （gateway / uploader / httpClient はテスト差し替え用の注入パラメータで、
//   初期化フォーマルでは既定値つき差し替えを表せないため意図的に通常代入を使う）
import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'google_workspace_config.dart';
import 'models.dart';
import 'plan_document.dart';

/// Google Workspace 連携で発生する、ユーザー向け例外。
/// メッセージにアクセストークン等の秘密情報は絶対に含めない。
class GoogleWorkspaceException implements Exception {
  final String message;

  const GoogleWorkspaceException(this.message);

  @override
  String toString() => message;
}

/// サインイン中の Google アカウントの最小情報。
class GoogleAccountInfo {
  final String id;
  final String email;
  final String? displayName;

  const GoogleAccountInfo({
    required this.id,
    required this.email,
    this.displayName,
  });
}

/// google_sign_in プラグインへの窓口。実機実装は [GoogleSignInGateway]、
/// テストではフェイクを差し替える。
abstract class GoogleAccountGateway {
  /// 前回のサインインを静かに復元する。未サインイン・失敗時は null。
  Future<GoogleAccountInfo?> restoreAccount();

  /// 対話的にサインインする。キャンセル・失敗は
  /// [GoogleWorkspaceException] を投げる。
  Future<GoogleAccountInfo> signIn();

  Future<void> signOut();

  /// drive.file スコープのアクセストークンを返す。
  /// まだ認可されておらず [interactive] が false の場合は null。
  /// 未サインインの場合も null。
  Future<String?> accessToken({required bool interactive});
}

/// google_sign_in 7.x による [GoogleAccountGateway] 実装。
///
/// 7.x の作法: シングルトン [GoogleSignIn.instance] を initialize してから、
/// authenticate() で認証、authorizationClient でスコープ認可を分けて行う。
class GoogleSignInGateway implements GoogleAccountGateway {
  final GoogleWorkspaceConfig config;

  GoogleSignInAccount? _account;
  Future<void>? _initFuture;

  GoogleSignInGateway(this.config);

  Future<void> _ensureInitialized() {
    return _initFuture ??= GoogleSignIn.instance.initialize(
      clientId: config.iosClientId.isEmpty ? null : config.iosClientId,
      serverClientId: config.webClientId.isEmpty ? null : config.webClientId,
    );
  }

  static GoogleAccountInfo _toInfo(GoogleSignInAccount account) =>
      GoogleAccountInfo(
        id: account.id,
        email: account.email,
        displayName: account.displayName,
      );

  static GoogleWorkspaceException _mapError(Object error) {
    if (error is GoogleSignInException) {
      return switch (error.code) {
        GoogleSignInExceptionCode.canceled => const GoogleWorkspaceException(
          'Google サインインがキャンセルされました。',
        ),
        GoogleSignInExceptionCode.clientConfigurationError =>
          const GoogleWorkspaceException(
            'Google 連携の設定に問題があります。セットアップ（パッケージ名と署名の登録）を確認してください。',
          ),
        _ => GoogleWorkspaceException(
          'Google サインインに失敗しました（${error.code.name}）。',
        ),
      };
    }
    return const GoogleWorkspaceException('Google サインインに失敗しました。');
  }

  @override
  Future<GoogleAccountInfo?> restoreAccount() async {
    try {
      await _ensureInitialized();
      final future = GoogleSignIn.instance.attemptLightweightAuthentication();
      if (future == null) return null;
      final account = await future;
      if (account == null) return null;
      _account = account;
      return _toInfo(account);
    } catch (_) {
      // 復元できない場合は未サインイン扱い（アプリは通常どおり動く）。
      return null;
    }
  }

  @override
  Future<GoogleAccountInfo> signIn() async {
    await _ensureInitialized();
    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw const GoogleWorkspaceException(
        'この端末では Google サインインを開始できませんでした。',
      );
    }
    try {
      final account = await GoogleSignIn.instance.authenticate();
      _account = account;
      return _toInfo(account);
    } on GoogleSignInException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> signOut() async {
    await _ensureInitialized();
    await GoogleSignIn.instance.signOut();
    _account = null;
  }

  @override
  Future<String?> accessToken({required bool interactive}) async {
    await _ensureInitialized();
    var account = _account;
    if (account == null) {
      final restored = await restoreAccount();
      if (restored == null) return null;
      account = _account;
      if (account == null) return null;
    }
    final client = account.authorizationClient;
    try {
      final existing = await client.authorizationForScopes(
        GoogleWorkspaceConfig.scopes,
      );
      if (existing != null) return existing.accessToken;
      if (!interactive) return null;
      final granted = await client.authorizeScopes(
        GoogleWorkspaceConfig.scopes,
      );
      return granted.accessToken;
    } on GoogleSignInException catch (e) {
      throw _mapError(e);
    }
  }
}

/// ドライブへ作成されたドキュメント。
class UploadedGoogleDoc {
  final String id;
  final String name;
  final String? webViewLink;

  const UploadedGoogleDoc({
    required this.id,
    required this.name,
    this.webViewLink,
  });
}

/// Google Drive API v3 へのアップロード（multipart/related）。
/// mimeType に Google ドキュメントを指定すると、テキストが
/// Google ドキュメントへ変換されて保存される。
class GoogleDriveUploader {
  static const String uploadEndpoint =
      'https://www.googleapis.com/upload/drive/v3/files';
  static const String googleDocMimeType =
      'application/vnd.google-apps.document';
  static const Duration uploadTimeout = Duration(seconds: 20);

  final http.Client? _httpClient;

  GoogleDriveUploader({http.Client? httpClient}) : _httpClient = httpClient;

  /// multipart 境界を暗号学的に安全な乱数で生成する。
  static String generateBoundary({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    return 'horihori-drive-$token';
  }

  /// multipart/related のボディを組み立てる（テスト可能な静的ヘルパー）。
  static String buildMultipartBody({
    required String name,
    required String content,
    String? boundary,
  }) {
    final resolvedBoundary = boundary ?? generateBoundary();
    final metadata = jsonEncode({'name': name, 'mimeType': googleDocMimeType});
    final buf = StringBuffer()
      ..write('--$resolvedBoundary\r\n')
      ..write('Content-Type: application/json; charset=UTF-8\r\n\r\n')
      ..write('$metadata\r\n')
      ..write('--$resolvedBoundary\r\n')
      ..write('Content-Type: text/plain; charset=UTF-8\r\n\r\n')
      ..write(content)
      ..write('\r\n--$resolvedBoundary--\r\n');
    return buf.toString();
  }

  static UploadedGoogleDoc parseUploadResponse(String body) {
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const GoogleWorkspaceException(
        'ドライブへの送信に失敗しました（応答形式が不正です）。',
      );
    }
    final id = decoded['id'];
    final name = decoded['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      throw const GoogleWorkspaceException(
        'ドライブへの送信に失敗しました（応答にドキュメント情報がありません）。',
      );
    }
    final link = decoded['webViewLink'];
    return UploadedGoogleDoc(
      id: id,
      name: name,
      webViewLink: link is String && link.isNotEmpty ? link : null,
    );
  }

  Future<UploadedGoogleDoc> uploadAsGoogleDoc({
    required String accessToken,
    required String name,
    required String content,
  }) async {
    final uri = Uri.parse(uploadEndpoint).replace(
      queryParameters: {
        'uploadType': 'multipart',
        'fields': 'id,name,webViewLink',
      },
    );
    final boundary = generateBoundary();
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
      ..bodyBytes = utf8.encode(
        buildMultipartBody(name: name, content: content, boundary: boundary),
      );
    final ownedClient = _httpClient == null ? http.Client() : null;
    final client = _httpClient ?? ownedClient!;
    try {
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(uploadTimeout);
      if (response.statusCode != 200) {
        throw GoogleWorkspaceException(
          'ドライブへの送信に失敗しました (Status: ${response.statusCode})',
        );
      }
      return parseUploadResponse(utf8.decode(response.bodyBytes));
    } on GoogleWorkspaceException {
      rethrow;
    } on TimeoutException {
      throw const GoogleWorkspaceException(
        'ドライブへの送信がタイムアウトしました。通信状況を確認してもう一度お試しください。',
      );
    } on http.ClientException {
      throw const GoogleWorkspaceException(
        'ドライブに接続できませんでした。通信状況を確認してください。',
      );
    } on SocketException {
      throw const GoogleWorkspaceException(
        'ドライブに接続できませんでした。通信状況を確認してください。',
      );
    } on FormatException {
      throw const GoogleWorkspaceException(
        'ドライブへの送信に失敗しました（応答形式が不正です）。',
      );
    } finally {
      ownedClient?.close();
    }
  }
}

/// Google Workspace 連携の窓口（設定画面・詳細画面から使う）。
///
/// 未設定ビルドではプラグインに一切触れず、状態表示と例外メッセージだけで
/// 正直に「未設定」を伝える。設定済みビルドでは、サインイン状態の確認、
/// サインイン／サインアウト、企画メモのドキュメント化を提供する。
class GoogleWorkspaceService {
  static const Set<String> _allowedExternalHosts = {
    'docs.google.com',
    'drive.google.com',
  };

  /// 外部ブラウザで開くことを許可する Google ドキュメント／ドライブ URL か検証する。
  static bool isAllowedExternalUrl(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      _allowedExternalHosts.contains(uri.host.toLowerCase());
  final GoogleWorkspaceConfig config;
  final GoogleAccountGateway? _gatewayOverride;
  final GoogleDriveUploader _uploader;
  GoogleAccountGateway? _gateway;

  GoogleWorkspaceService({
    GoogleWorkspaceConfig? config,
    GoogleAccountGateway? gateway,
    GoogleDriveUploader? uploader,
    http.Client? httpClient,
  }) : config = config ?? GoogleWorkspaceConfig.fromEnvironment,
       _gatewayOverride = gateway,
       _uploader = uploader ?? GoogleDriveUploader(httpClient: httpClient);

  bool get isConfigured => config.isConfigured;

  GoogleAccountGateway get _accountGateway =>
      _gatewayOverride ?? (_gateway ??= GoogleSignInGateway(config));

  void _requireConfigured() {
    if (!isConfigured) {
      throw const GoogleWorkspaceException(
        'Google連携は未設定（セットアップ待ち）です。Google Cloud 側の設定が完了したビルドでお試しください。',
      );
    }
  }

  /// サインイン中のアカウント。未設定・未サインイン・失敗時は null。
  Future<GoogleAccountInfo?> currentAccount() async {
    if (!isConfigured) return null;
    try {
      return await _accountGateway.restoreAccount();
    } catch (_) {
      return null;
    }
  }

  Future<GoogleAccountInfo> signIn() async {
    _requireConfigured();
    return _accountGateway.signIn();
  }

  Future<void> signOut() async {
    if (!isConfigured) return;
    await _accountGateway.signOut();
  }

  /// 企画メモを Google ドキュメントとしてドライブへ送る。
  ///
  /// 認可済みトークンがあればそのまま送り、無ければサインイン→
  /// スコープ認可まで対話的に進める（ボタンのタップから呼ぶ前提）。
  Future<UploadedGoogleDoc> sendPlanToDrive(
    Idea idea, {
    PlanMemo? memo,
  }) async {
    _requireConfigured();
    final target = memo ?? (idea.memos.isEmpty ? null : idea.memos.last);
    if (target == null) {
      throw const GoogleWorkspaceException('企画メモがまだありません。');
    }
    var token = await _accountGateway.accessToken(interactive: false);
    if (token == null) {
      await _accountGateway.signIn();
      token = await _accountGateway.accessToken(interactive: true);
    }
    if (token == null) {
      throw const GoogleWorkspaceException(
        'ドライブへのアクセスが許可されませんでした。',
      );
    }
    return _uploader.uploadAsGoogleDoc(
      accessToken: token,
      name: planDocumentName(idea, memo: target),
      content: buildPlanDocument(idea, memo: target),
    );
  }
}
