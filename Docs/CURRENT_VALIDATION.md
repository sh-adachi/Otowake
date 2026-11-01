# 現在の環境での動作確認

実施日：2026年11月1日（日本時間）。修正版は `dist/Otowake.app` バージョン1.0.3です。

## 実機で確認した内容

- 通常起動した音分けに対し、利用者がmacOSのシステムオーディオ録音を許可。
- ChromeをAirPodsへ出力し、スライダー・ミュート・解除を操作。利用者から実際に音量が変わることを確認。
- Chromeを画面からDELLモニターへ切り替え、元の標準出力へ戻す操作を確認。
- 独立した2つの合成音源をDELLとAirPodsへ同時出力し、信号到達、ゲイン、ミュート、ミュート中の切り替え、タップ解放に成功。
- WebKit音声プロセスをSafariに帰属させる修正後、Safariの画面表示を確認。
- Safariからローカルの合成音声を実際に再生し、Safariとして検出され、DELLへの出力状態になること、個別ミュート・音量操作を確認。
- テスト用のSafariルールをリセットし、合成音を停止してテストタブを閉じた。Chromeは利用者が選んだ約13%・標準出力・ミュート解除を保持。
- 「すべて表示」をONにし、再生前でもSafariを選べる状態にした。
- 最終版1.0.3の通常起動でも許可後にChromeがAirPodsへの出力状態になり、Safari（音声オブジェクト152）を無音のまま90%に設定してもエラーにならず待機することを確認。その後Safariのテスト設定を再度リセットした。

Safariの確認は専用のローカル音声ページによるもので、利用者が開いたYouTube動画そのものを最終版で聴取した検証とは区別しています。Chromeには利用者の聴取確認があります。音圧・音質測定は実施していません。

## 見つかった問題と修正

1. **Safariが一覧に出ない**：WebKitの親がlaunchdであり、従来の親探索ではSafariに結び付かなかった。OSの所有元PIDを参照し、起動中アプリとの一致を確認するようにした。WebKitを一律Safariに割り当てない。
2. **録音許可待ちの表示が古い**：IOProc登録が許可待ちになる前に「接続中・音声取得許可を確認」と表示するようにした。
3. **許可直後の取得失敗**：許可待ちの時間がタイムアウトに入っていた。監視の起点をIO開始成功後へ移した。
4. **再生前の無音を失敗と誤認**：正常な無音や開始前は待機状態として保持し、信号が届いたら出力中にする。不正バッファや開始済みIOの停止は引き続き検出する。
5. **AirPodsの切り替えテストが早すぎる**：200msの固定待機では失敗していた。最大3秒の範囲で実際の信号到達を待ち、信号・無音出力・不正バッファなしを検証するように変更。変更後は全項目成功。

## テスト

自動テスト：**4スイート、24件成功**。Safariと別のWebKitアプリの区別、所有元が不明な場合の親探索、親情報の循環、3分の許可待ち、正常な無音待機、不正バッファ、停止したIOの回帰テストを含みます。

DELL＋AirPodsの実機ログ：

```text
PASS route 1: DELL S2725QC, callbacks=194, signal=168, output peak=0.0039558816
PASS route 2: AirPods Pro, callbacks=183, signal=168, output peak=0.003958272
PASS mute: all output buffers are silent
PASS device handover: replacement taps receive audio while muted
PASS gain/unmute: 25% output amplitude
PASS teardown: no remaining test taps; native playback restored
```

ログは `Artifacts/Logs/current-unit-tests.log`、`final-airpods-tests.log`、`current-inventory.log`、`current-release-build.log` に保存しています。最終版1.0.3のUniversal 2リリースビルド、署名検証、ZIP検証が成功しています。

## 制約

アドホック署名では更新でコードハッシュが変わるため、macOSが録音許可を再確認します。今回も実際に再確認がありました。TCCの設定や許可データベースはプログラムから変更していません。

XPC所有元の特定に、存在する場合だけ読み取り目的で使う非公開のlibSystem SPIを1つ使用します。将来のOSで利用できなくなった場合は親探索へ戻るため、Safariなどの帰属を再検証する必要があります。[設計資料](ARCHITECTURE.md)に記載しています。

旧macOS・Intel実機・DRM・特殊機器・ASanについては [初回検証記録](VALIDATION.md) の制限を参照してください。
