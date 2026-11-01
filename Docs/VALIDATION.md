# 検証結果

実施日：2026年11月1日（日本時間）

以下は初回ビルド時の記録です。通常起動、Safariの修正、AirPods、最新24件のテストは [CURRENT_VALIDATION.md](CURRENT_VALIDATION.md) を参照してください。

## 環境と成果物

- 実機：Apple Silicon、macOS 26.6.2（25G83）
- ビルド：Xcode 26.3、Swift 6.2.4、macOS 26.2 SDK
- 最低対応OS：macOS 14.4
- リリース：`dist/Otowake.app`（約2.8MB）、`dist/Otowake-macOS.zip`
- Universal 2の `arm64`／`x86_64` 両スライスを `lipo -archs` で確認
- アドホック署名を `codesign --verify --strict` で確認
- Info.plistの構文と、配布ZIPの展開テストを確認

## 自動テスト

`Scripts/swift.sh test`：3スイート、18件成功。

| 分野 | 確認した内容 |
| --- | --- |
| 保存 | 新しいストアでの再読み込み、複数アプリの別デバイス・音量・ミュート保持 |
| 保存エラー | ファイルなし、壊れたJSONの保護、非対応バージョン、不正な音量値 |
| ルート選択 | ChromeとChatGPTの独立ルート、標準出力への追従、未接続と再接続 |
| ライフサイクル | 制御OFF、アプリ停止・新しいプロセスIDでの再開、既定状態ではタップ不要 |
| アプリ識別 | 入れ子のChrome Helper.appを外側のChrome.appに帰属 |
| 音声計算 | ステレオのゲイン、メーター、ミュート・解除とランプ |
| バッファ | interleaved／planar、物理入力のスキップ、推奨出力チャンネル、モノラル |
| 境界条件 | 不足したチャンネル、短い入力、NaN・無限大、余分な出力の無音化 |

ログ：`Artifacts/Logs/unit-tests.log`

## 実機の音声経路

実機のHAL診断で、DELL S2725QC、ZOWIE XL LCD、Mac内蔵スピーカー、AirPods Pro、外部ヘッドフォンの5出力を列挙できました。Chromeの3つの音声プロセス、およびChatGPTの2つの音声プロセスをそれぞれ元のアプリにまとめて検出できました。

`--smoke-test` により、2つの独立した `afplay` プロセスで44.1kHz／約-42dBFSの小さな合成音を生成し、48kHzのDELLモニターと外部ヘッドフォンへ同時転送しました。利用者の再生中アプリにはテストのタップを作成していません。

最終ビルドの実行結果：

```text
PASS route 1: DELL S2725QC, callbacks=194, signal=194, output peak=0.0039543677
PASS route 2: 外部ヘッドフォン, callbacks=179, signal=179, output peak=0.003958349
PASS mute: all output buffers are silent
PASS device handover: replacement taps receive audio while muted
PASS gain/unmute: 25% output amplitude
PASS teardown: no remaining test taps; native playback restored
```

両ルートで実際の入力信号と出力バッファを確認しました。ミュート時は出力がゼロになり、解除・25%への変更後は信号が戻ります。ミュートしたまま出力先を入れ替え、新しいタップが先に音声を受け取れることも確認しました。終了時にはテストで作成したタップが残っていません。

これはHALまでの信号転送・処理の確認です。耳での聞き分け、音圧、長時間のドリフト・音質測定、物理ループバックによる出力の測定は実施していません。

ログ：`Artifacts/Logs/hardware-tests.log`

## UIと設定復元

実際のネイティブ画面で以下を操作・確認しました。

- 初回の案内、制御OFF、再生中アプリの一覧
- 「すべて表示」、アプリ名検索、5つの出力先の選択肢
- ChatGPTの出力先を外部ヘッドフォンに変更
- 音量を90%に変更し、ミュートを保存
- アプリを終了・再起動し、外部ヘッドフォン／90%／ミュートが復元されることを確認
- アプリごとのリセットを実行し、標準出力／100%／ミュート解除に戻ることを確認
- メニューの終了操作と、日本語UIのスクリーンショットによるレイアウト確認

UIテストは制御OFFのまま行いました。終了時の利用設定は、制御OFF・保存ルールなし・「すべて表示」OFFに戻しています。

## 残る検証

- Intelはクロスビルド成功までで、Intel実機では未検証です。
- macOS 14.4〜15系の実機、スリープ復帰、物理的な抜き差し、Bluetoothのプロファイル変更、特殊なUSBマルチチャンネル機器は未検証です。状態遷移のルート判断は自動テストで確認しています。
- DRM音声、共有XPCサービス、独自の排他音声経路では取得・アプリ識別に制限があります。Chrome／ChatGPTそのものの音声内容を取得してのエンドツーエンド検証は行っていません。実機転送テストは専用の合成音源です。
- 新規ユーザーでのmacOS録音許可ダイアログと、許可拒否後の復旧操作は別途確認が必要です。TCC設定の変更・回避はしていません。
- Address Sanitizer付き検査はビルド成功後、テスト開始前のASan初期化で停止しました。プロセスのスタックを採取し、`__asan::InitializeShadowMemory` からmalloc初期化へ再入し `StaticSpinMutex::LockSlow` で待機する状態を確認しました。テスト本体は実行されていないため、ASan検査は未完了です。停止した検査プロセスは終了済みです。採取記録は `Artifacts/Logs/asan-startup-sample.txt` にあります。
- 一般配布用のDeveloper ID署名・公証・自動アップデートは含みません。
