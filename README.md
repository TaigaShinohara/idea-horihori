# アイデアホリホリ

アイデアを1行ストックして、AIの質問に答えながら企画メモに育てるアプリ。

- Flutter / Android・iOS（16.4以降）。アプリのバージョンは `pubspec.yaml` を参照。
- 対応するAndroid端末ではGemini Nanoを、iOS 26以降の対応端末ではApple Intelligenceを優先する。Androidのモデルは設定の「Nanoで質問を試す」から準備できる。iOSのモデルはOS側で準備される。
- クラウドのGemini APIは、APIキーを保存してクラウド送信を有効にした場合に利用できる。定型の質問と企画メモは端末だけで使える。
- [設計](docs/DESIGN.md) · [引き継ぎ](docs/HANDOVER.md) · [端末AIの動作確認](docs/ONDEVICE_POC.md)
