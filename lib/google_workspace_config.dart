/// Google Workspace 連携（v0.5.0）の設定。
///
/// OAuth クライアント ID はコードに直書きせず、ビルド時の dart-define で
/// 差し込む（クライアント ID 自体は秘密情報ではないが、環境ごとに違うため
/// 設定として分離する）。渡し方は2通り:
///
/// - 通常の Flutter ビルド: `--dart-define=GOOGLE_WEB_CLIENT_ID=...` 等
/// - この VM の ./build.sh: `.local/dart-defines.env` に KEY=VALUE で書くと
///   build.sh が自動で -Pdart-defines に変換して渡す
///
/// どちらも未指定のビルドでは [isConfigured] が false になり、連携カードは
/// 「未設定（セットアップ待ち）」と表示するだけで、アプリは通常どおり動く。
/// セットアップ手順は docs/GOOGLE_WORKSPACE_SETUP.md。
class GoogleWorkspaceConfig {
  /// iOS 用 OAuth クライアント ID（iOS では initialize に必須）。
  final String iosClientId;

  /// Web 用 OAuth クライアント ID。Android では認可そのものには不要
  /// （パッケージ名＋署名 SHA-1 で照合される）が、セットアップ完了の
  /// 判定とサーバー認可用に使う。
  final String webClientId;

  const GoogleWorkspaceConfig({this.iosClientId = '', this.webClientId = ''});

  /// dart-define から読んだ実環境設定。
  static const GoogleWorkspaceConfig fromEnvironment = GoogleWorkspaceConfig(
    iosClientId: String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'),
    webClientId: String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
  );

  /// Cloud コンソール側のセットアップが済んだビルドかどうか。
  /// Android は Web クライアント ID、iOS は iOS クライアント ID が目印。
  bool get isConfigured => iosClientId.isNotEmpty || webClientId.isNotEmpty;

  /// 要求スコープは drive.file のみ: このアプリが作ったファイルにだけ
  /// アクセスでき、ドライブ内の他のファイルは見えない（本人の決定）。
  static const String driveFileScope =
      'https://www.googleapis.com/auth/drive.file';
  static const List<String> scopes = [driveFileScope];
}
