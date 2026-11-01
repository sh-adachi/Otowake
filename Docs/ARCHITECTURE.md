# 技術調査と設計

## 採用した構成

UIはSwiftUI、メニューバー・ウインドウ・アプリのライフサイクルはAppKit、音声はCore AudioのProcess Tapとprivate aggregate deviceを使用します。追加ドライバ、カーネル拡張、管理者権限、BlackHoleなどのインストールは不要です。最低対応版はmacOS 14.4としました。

Appleの[Core Audio Tapsのサンプル](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)でプロセス音声の取得とミュート、aggregate deviceへの接続を確認しました。詳細はXcode 26.3付属macOS SDKの `CATapDescription.h`、`AudioHardwareTapping.h`、`AudioHardware.h` と照合しています。

選定の理由は、macOS標準の公開APIでプロセスごとの音声処理を実現でき、ドライバの署名・インストール・更新を持たずに済むためです。ElectronやWeb UIの常駐ランタイムも不要です。macOS標準の出力デバイス設定だけでは、他社アプリごとの音量処理まで提供できません。

## 音声経路

```text
Chromeの音声プロセス群 ─ 専用ステレオタップ ─ Cのゲイン処理 ─ モニター
ChatGPTの音声プロセス群 ─ 専用ステレオタップ ─ Cのゲイン処理 ─ イヤホン
```

アプリごとに独立したタップとprivate aggregate deviceを作成します。aggregateには出力先の実デバイスとステレオタップを含め、実デバイスのクロックを使用します。タップのドリフト補正を有効にし、HALの同じIOProcで入力を読み、出力へ書きます。アプリ独自のリングバッファやクロック同期スレッドを持ちません。

タップの `muteBehavior` は `.mutedWhenTapped` です。タップの読み取り中だけ元の音声を抑え、音分けが停止・終了すると通常の音声出力へ戻る設計です。作成途中で失敗した場合も、IOProc、aggregate、tapを逆順に解放します。

参考：[CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)、[CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)、[AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))。

## リアルタイム処理

`AudioRealtime.c` のC11コードのみをIOProc上で実行します。メモリ確保、ファイルI/O、ログ、Swiftオブジェクト、ミューテックスはありません。UIとのゲイン値・診断値の共有にはアトミック変数を使います。対象アーキテクチャの32/64ビットアトミックを使用します。

Float32 PCMの入力をステレオとして取り出し、0〜1のゲインを乗算します。ゲインは約5msで変化させ、クリックを抑えます。実デバイスの推奨ステレオ出力チャンネルを尊重し、モノ出力ではL/Rを平均します。余分な出力チャンネルはゼロにし、NaNや無限大を通しません。入力と出力のフォーマット・サンプルレートを開始前に検証し、非対応構成では音声制御を開始しません。

物理入力を持つ機器では、aggregateに含まれる物理入力ストリームを `kAudioDevicePropertyIOProcStreamUsage` で無効にします。コールバックはタップの開始チャンネルより前を読みません。マイク入力を音声転送に混ぜないための処理です。

参考：[AudioHardwareIOProcStreamUsage](https://developer.apple.com/documentation/coreaudio/audiohardwareioprocstreamusage)。

## 状態と再接続

HALの列挙・ルート作成・停止は専用の直列キューに閉じ込めています。メインスレッドはSwiftUIの状態管理のみです。約1.2秒ごとの軽い列挙により、デバイス・プロセス・標準出力・サンプルレートの変化を検出します。スライダー操作は既存ルートのアトミックゲインを即時更新し、一覧の再評価をまとめます。

Chromeのような入れ子のHelper.appは最も外側のアプリBundleに帰属させます。SafariのWebKit GPUのようにlaunchdを親に持つXPC音声サービスは、任意のlibSystem SPI `responsibility_get_pid_responsible_for_pid` を動的に解決して、OSが保持する所有元PIDに結び付けます。起動中の通常アプリと一致するPIDだけを採用し、WebKitを一律Safariにまとめません。SPIが利用できない場合は公開libproc APIで親PIDをたどり、それでも特定できなければ推測で別アプリの制御に含めません。この帰属情報の取得だけは非公開SPIへの任意依存であり、将来のmacOSでは再検証が必要です。署名・録音許可の回避には使用しません。関数の引数と戻り値は[Chromiumの呼び出し実装](https://chromium.googlesource.com/chromium/src/+/refs/tags/134.0.6998.28/base/process/process_info_mac.mm)でも確認しています。

文字列のBundle ID前方一致ではまとめません。保存時はBundle IDを使用し、音声タップには現在のAudioObjectID群を渡します。プロセス再起動時は新しいIDで作り直します。

デバイスが消えた場合は制御を解除し、保存したUIDは維持します。再接続を検知したら再適用します。API失敗時は15秒間隔で再試行します。不正なバッファや開始済みIOの停止が続く場合はタップを破棄し、警告と手動の再接続を提供します。正常な無音や開始前は待機として扱い、音声が届くまでルートを保持します。Macのスリープ時は停止し、復帰時に再作成します。

出力先の変更や手動の再接続では、旧タップを読み取り続けたまま新しいルートを作り、新ルートが開始してから旧ルートを停止します。ミュート中にルートを作り直す間、元のアプリ音声を不用意に復帰させないためです。新ルートを作れない場合は制御を解除し、失敗を表示します。

## 保存とセキュリティ

設定JSONはバージョンを持ち、音量値を検証し、atomic writeで保存します。読めない設定は上書きしません。保存の失敗も画面に表示します。

`NSAudioCaptureUsageDescription` をInfo.plistに含めています。システムオーディオ録音の許可はmacOSが管理します。非公開のTCC関数や許可データベースの書き換えは使用していません。許可がない場合はエラーや無音検出から案内します。音声をディスク・ネットワークへ出す機能はありません。

Core Audioが許可への応答を待つ間は「接続中」と表示します。無音・コールバック停止の監視時間は、許可待ちを含むオブジェクト生成時点からではなく、IOの開始成功後から計測します。アドホック署名では更新後のコードハッシュが変わるため、macOSが音声取得の許可を再確認する場合があります。

## 配布

SwiftPMでローカルビルドし、Info.plist・アイコンを含む.appを生成して署名します。アドホック署名での個人利用を既定とし、Developer ID／公証は一般配布時の別工程とします。バイナリはUniversal 2を生成可能です。Intel版のクロスビルドと実機での動作検証は区別します。
