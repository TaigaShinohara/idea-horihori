# オンデバイスAI PoC（v0.3.0、2026-11-22）

本人の指示「デフォルトではオンデバイスのAIを使って深掘りをするようにしてみたい」で開始したPoCの記録。

## 実装した形

- 優先順：**オンデバイス（Gemini Nano / ML Kit GenAI Prompt API、flutter_device_ai ^0.3.0）→ Gemini API（キーがある場合）→ 定型**
- `lib/on_device_backend.dart`：OnDeviceBackend（AiBackend 実装）。クライアントは抽象化し、単体テストではFakeに差し替え可能（profileMaker PoC と同じ分離）
- profileMaker PoC の教訓を最初から適用：
  - 全呼び出しにタイムアウト（状態確認15秒／ダウンロード120秒／生成60秒）。実機で応答が返らず固まる事象への対策で、固まったら例外にして次候補へ倒す
  - パース失敗時のみ1回再試行
  - ダウンロードが必要な端末は初回だけ待つ
- ResilientBackend：候補チェーン化し、直近の応答元（onDevice／remote／local）と失敗フラグを保持
- モード表示：バッジに「オンデバイスで深掘り中」を追加。オンデバイス→次候補への切替はセッション1回だけ通知
- キー未設定時の初回案内は、定型に実際に落ちた時だけ出すよう変更

## ビルド時の注意（発生した問題と対策）

- minSdk を 24 → **26** に引き上げ（ML Kit GenAI の要件。Android 8.0未満は対象外になる）
- APK容量：全ABI版 262MB → arm64版 **124.7MB**。大半はオンデバイスAI（LiteRT）のネイティブライブラリで、profileMaker でも同じ傾向（約117MB）。ストア提出時は AAB の分割配信で端末ごとの容量は下がる見込みだが、軽量化は既定化の判断材料の1つ
- Gradle直叩きビルドでは android/local.properties のバージョンが自動更新されず、古い versionName が混入した → build.sh に pubspec からの自動同期を追加して再発防止

## コード側の検証（済み）

- flutter analyze：クリーン
- テスト：76件全合格（既存66＋新規10：質問／まとめのパース、再試行、ダウンロード先行、利用不可、生成タイムアウト、チェーンの優先順とモード判定）

## 合否ゲート（実機でしか測れないもの＝未確認）

| # | 項目 | 見ること |
|---|---|---|
| 1 | 質問の自然さ | 日本語の質問＋3択がそのまま使えるか |
| 2 | まとめの形式成功率 | 5欄メモのJSONが崩れず返る割合 |
| 3 | 速度 | 1問あたり何秒かかるか |
| 4 | 固まらないか | タイムアウト→定型への切替が実際に働くか |

実機（Pixel 10 Pro）での推論は未確認。PoC APK を入れた最初の深掘り1回で 1〜4 が一通り測れる。それまでは「既定化の合否は未判定」として扱い、実機待ち行列に置く。

## 既定化の判断材料（PoC時点で分かっていること）

- 対応端末が限られる（AICore／Gemini Nano 対応機のみ）。非対応では自動で次候補へ落ちるので、既定化しても壊れない設計にはなっている
- BYOKキーは「品質の逃げ道」として設定に残置（削除はしていない）

## 実機結果（2026-11-23、Pixel 10 Pro）

- 本人から「オンデバイスAIは使えないというエラーが出た」と報告。フォールバック（定型への切替）は設計どおり動作
- 理由は v0.3.0 では表示していなかったため、v0.3.1 で設定画面に診断（状態＋端末が返した理由メッセージ）を追加
- 同端末では ProfileMaker でも「Could not query AICore: null」の前歴あり。AICore 側の事情の可能性が高いが、確定は v0.3.1 の診断表示待ち

## Pixel 10 Proでの推論確認（2026-11-23）

- Android 17のPixel 10 Proで、別パッケージの検証版を使用。設定の「Nanoで質問を試す」で、端末内のGemini Nanoが日本語のサンプル質問を生成した。
- 本体アプリに保存済みのアイデアとは別にテスト用のアイデアを登録し、通常の深掘りでも日本語の質問と3択を生成した。APIキーは空、クラウド送信はオフ。質問の表示後に「オンデバイスで深掘り中」を確認した。
- 設定の「状態を確認する」はモデルの準備状況を確認する。「Nanoで質問を試す」は必要に応じてモデルを準備し、その後に実際の生成を試す。前回の利用不可の原因と、初回のモデル取得・他機種での実機動作は未確認。

## v0.3.2の動作

- モデルが未取得なら、設定の「Nanoで質問を試す」で取得と生成を行う。通常の深掘りはダウンロードを待たず、定型に進むか、同意のある場合にGemini APIを使う。生成中も「定型で続ける」を選べる。
- 端末AIの通常処理では状態確認に最大6秒、生成と形式エラー時の再試行を合わせて最大18秒を使う。Gemini APIの呼び出しは最大12秒。設定からのモデル取得は別に最大120秒。
- Gemini Nanoには、入力を短くしてからトークン数を確認して渡す。入力が上限に近い場合は、直近の質問・回答をさらに絞ってやり直す。端末内に保存済みの履歴はそのまま参照できる。
- 質問・企画メモ・名前候補には生成元を表示する。以前の保存データに生成元の記録がなければ表示を省略する。
- Gemini APIの既定は `gemini-3.5-flash-lite`。保存済みの廃止済みGemini 2.0モデルは読み込み時に移行する。設定の接続確認はモデルのメタデータを取得する。クラウドの生成には別途同意が必要で、同意撤回・画面退出時は処理を取り消す。

## 診断結果と原因の結論（2026-11-25、Pixel 10 Pro・v0.4.1）

本人が設定→詳細・動作確認の診断結果をスクショで報告:

- 端末AIカード: 「AICoreの状態を確認できませんでした。少し待って再確認してください。」
- 生の理由: 「Could not query AICore: null」

### コードとプラグイン実装から言えること（根拠つき）

- 「Could not query AICore: null」は flutter_device_ai 0.3.0 の Android 実装（FlutterDeviceAiPlugin.kt の availability()）が出す文面。AICore パッケージの存在確認は通過したうえで、ML Kit GenAI の `Generation.getClient().checkStatus()` が例外を投げ、その例外の `message` が null だった、という意味である。つまり「端末が非対応」という判定ではなく「状態クエリ自体の失敗」。
- 同プラグインの生成経路（createSession → generateContent）は checkStatus を経由しない。セッション生成も Android ではローカルオブジェクトの作成のみで、AICore 呼び出しは generateContent / countTokens の時点でのみ起きる。
- 実際、同じ Pixel 10 Pro で別パッケージの検証版では Gemini Nano の生成が成功した記録がある（本ドキュメント「Pixel 10 Proでの推論確認（2026-11-23）」）。「状態が取れない＝生成もできない」とは言えない。
- 一方、アプリ側は v0.4.1 まで checkStatus が available でなければ生成を試さない作り（_prepare が checkFailed で例外）だったため、状態クエリの失敗がそのまま「オンデバイスAIを使えない」に化けていた。これが本件の直接の原因（アプリ側の判定ロジック）であり、AICore 側で checkStatus が null メッセージ例外を返す理由そのものは端末側の事情で、アプリからは確定できない。

### 対処（v0.4.2）

- 生成系の呼び出し（質問・まとめ・名前候補・「質問を試す」）では、checkFailed でも生成を1回試し、結果で判定するフォールバックに変更（_prepare の probeOnCheckFailed）。生成が成功したら状態を「利用可」に昇格させてキャッシュする。生成も失敗したら従来どおり次候補（ChatGPT→Gemini→定型）へ落ちる。
- prepareModel（モデルの事前準備）は生成を伴わないため probe せず、「質問を試す」で実際に生成できるか確認するよう案内する文面に変更。
- 診断の表示文面も「状態を確認できませんでした（使えないと確定ではありません）。『質問を試す』で実際に生成できるか確かめられます。」に改善。
- 実機でしか確定できない残件: この Pixel 10 Pro 実機で、v0.4.2 の probe により実際に深掘りがオンデバイスで通るか（生成成功まで至るか）は未確認＝実機待ち。

## APKサイズ最適化（2026-11-25、v0.4.2）

- 本人指摘「アプリが重たい」を受けて内訳を実測: APK 120MB の大半は flutter_device_ai が依存として引き込む llamadart 系のネイティブライブラリだった（libggml-vulkan.so 26MB / libLiteRtLm.so 26MB / LiteRt サンプラー・アクセラレータ群 約17MB / libwebgpu_dawn.so 5.7MB / libGemmaModelConstraintProvider.so 4.8MB / libllama*.so 約8MB / ggml-cpu 各種 約11MB など、非圧縮合計 約100MB）。
- これらは「OS のモデルが使えない端末で GGUF ローカルモデルを llama.cpp / LiteRT-LM で動かす」フォールバック用。本アプリは FlutterDeviceAi.withFallback() にアダプタを渡しておらず、この経路を使っていない。Android の Gemini Nano は AICore のシステムプロセスで実行され、ML Kit GenAI 側にこれらの .so は不要。
- 対処: android/app/build.gradle.kts の packaging.jniLibs.excludes で該当 .so（libLiteRt* / libGemmaModelConstraintProvider / libggml* / libllama* / libmtmd / libwebgpu_dawn）を除外。サイズ実測: 除外前 125,250,388 バイト（約120MB）→ 除外後 20,276,253 バイト（約20MB）、−84%。署名・版数（0.4.2+12）も apksigner で確認済み。
- リスクと残件: 除外した .so が実機でロードされないことの最終確認は実機待ち（ロードされるのは AICore 経路と無関係な初期化が無いことまでをコードで確認済み）。ローカルLLM経路を使う改修時は除外を外すこと（build.gradle.kts にコメント明記）。
- 起動まわり: main() は store.load() を非同期に流しており、起動時の同期的な重い処理はコード上見当たらなかったため、今回はサイズ削減のみ。

## 実機報告: probe は通ったが生成自体が失敗（2026-11-27、Pixel 10 Pro・v0.5.1）

本人が v0.5.1 を Pixel 10 Pro で起動し、端末AI生成を試したところ「Gemini Nanoから応答を取得できませんでした」と表示され使えなかった、と報告。なお iPhone 16 では Apple Intelligence での生成は成功している（経路が別なので矛盾なし）。

### 確定していること（コード・プラグイン実物確認済み）

- v0.4.2 の probe（状態不明でも生成を試す）は動作しており、今回は **generateContent 自体が GenAiException で失敗** している。checkStatus が例外（message null）を投げ続ける件とは別の段階の失敗。
- 失敗の理由は特定できていない。アプリの `_describeAiError`（lib/on_device_backend.dart）が `OnDeviceAiGenerationException` を固定文「応答を取得できませんでした」に置換し、**ネイティブ例外の message（"GenAI error <code>" 等）を捨てていた** ため、理由が追えなかった。これが今回の最大の問題（アプリ側の情報保全の欠落）。
- Android では `_usesNativeSchemas=false`（テキストモード生成）なので、JSON スキーマ起因ではない。
- 2026-11-23 には同じ Pixel 10 Pro で別パッケージ検証版の生成成功記録がある（本ドキュメント「Pixel 10 Proでの推論確認」）。端末が完全非対応ではない。

### 対処（v0.5.2）

- **エラー理由の保全**: バックエンドに `lastGenerationErrorDetail` を追加。ネイティブ例外（OnDeviceAiException）の code＋message を切り詰め（最大300字）て保持し、設定→詳細・動作確認の診断表示で見えるようにした。ユーザー向けの短い文面は従来どおり維持し、生メッセージはそちらには出さない。再試行で回復した一時的な失敗も記録する。
- **リトライ**: 生成が `OnDeviceAiGenerationException` で失敗したら、1秒待って1回だけ再試行する（AICore の初回初期化失敗は再試行で通ることが知られている）。再試行はパース再試行の枠を消費せず、生成呼び出しの上限は「パース再試行込み2周＋生成再試行1回＝最大3回」と明記した。キャンセル時は待機後に revision チェックで AiCancelled を伝播させる。

### 未確定事項（次回の実機診断待ち）

- **生成の実エラー理由（ネイティブのエラーコード）は未確定**。v0.5.2 を入れた実機で再度「質問を試す」を実行し、設定→詳細・動作確認に表示される「最後の生成エラーの詳細」（例: "GENERATION_FAILED: GenAI error <code>: ..."）を確認して初めて切り分けられる。憶測で原因は断定しない。
- v0.5.2 のリトライで実機生成が通るかも未確認（再試行が効くのは初回初期化失敗型の場合のみ）。

## 診断結果（2026-11-28、Pixel 10 Pro・v0.5.2）

本人が v0.5.2 で「Nanoで質問を試す」を実行し、設定→詳細・動作確認のスクショを報告:

- 状態確認: 「Could not query AICore: null」（継続）
- 最後の生成エラーの詳細: **GENERATION_FAILED: java.lang.NullPointerException**（メッセージなし）
- v0.5.2 の自動リトライ（1秒後1回）でも回復しなかった

### 切り分け（2026-11-28、コード＋ネット調査）

- 正常な AICore エラー（BUSY・容量不足・未対応など）は数字コード付き GenAiException になる。今回は checkStatus・countTokens 系・generateContent の全てが「メッセージなし例外」で落ちており、AICore 側がまともな応答を返さず ML Kit 内部で null を踏んでいるパターン。アプリ側の固定文ではなく実エラーが初めて見えた。
- アプリ側に NPE の原因は見当たらない: release に minify なし、flutter_device_ai は最新 0.3.0（genai-prompt 1.0.0-beta4）、同じ経路で 2026-11-23 に生成成功の記録あり。
- ネット上の同型事例: Pixel 9/10 で AICore が stub 版（versionName 0.stub…）のままだと ML Kit が AICore サービスにバインドできず全呼び出しが失敗する（creativeworkline の AICore Binding Failure 記事）。公式の 606（FEATURE_NOT_FOUND）説明でも「AICore が最新構成をダウンロードし終わるまで使えない。再起動で早まる」とある。
- 結論: 一時的な初期化失敗ではなく、端末側 AICore の状態（未更新・stub・構成未取得）が持続的に悪い可能性が高い。確定には端末側の確認が要る: ①Playストアで AICore の更新有無とバージョン（0.stub か）②再起動後の再試行 ③Gmail の「作成を手伝って」等、他の Nano 機能が動くか（動かなければ端末側で確定）。

### 端末確認の結果（2026-11-28 16:06）

本人が設定→アプリ→AICore のスクショを報告:

- バージョン: **26.10.15.11.release.prod_aicore_20261015.00_RC11**（APKMirror 掲載の最新 release と一致。**stub ではない**）
- ストレージ使用量: 4.42 GB（Nano モデルのデータは落ちている）
- Play ストアからインストール済み

→ 「AICore が stub 版」という仮説は棄却。AICore 本体は正常に入っている。それでも checkStatus／generateContent がメッセージなし例外で落ちる。プラグイン側の buildRequest は config を安全に読む実装で、NPE は ML Kit の generateContent 内部＝AICore とのやり取りの中で起きている。残る未実施の切り分け: ①再起動後の再試行（AICore サービスの状態リセット）②他の Nano 機能（Gmail の作成支援等）が動くか＝端末全体か／このアプリだけか ③別パッケージ検証版（2026-11-23 に成功した方式）を現行コードで作り直しての再現確認。
