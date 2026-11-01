import AppKit
import CoreAudio
import OtowakeCore
import SwiftUI

private let accent = Color(red: 0.10, green: 0.49, blue: 0.47)

struct MixerView: View {
    @ObservedObject var model: AppModel
    var openWindow: () -> Void
    @State private var showHelp = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.preferences.enabled { welcome }
                    if let error = model.settingsError ?? model.snapshot.error { warning(error) }
                    if showHelp { help }
                    HStack {
                        Label("アプリケーション", systemImage: "square.stack.3d.up")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("すべて表示", isOn: Binding(get: { model.preferences.showAllApps }, set: { model.setShowAll($0) }))
                            .toggleStyle(.checkbox).font(.system(size: 11))
                    }
                    if model.preferences.showAllApps || !model.search.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("アプリを検索", text: $model.search).textFieldStyle(.plain)
                        }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if model.visibleApps.isEmpty { emptyState }
                    ForEach(model.visibleApps) { app in AppRow(model: model, app: app) }
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle")
                        Text("設定は自動で保存されます")
                    }.font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 3)
                }.padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 448, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path").font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white).frame(width: 43, height: 43)
                .background(accent.gradient, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("音分け").font(.system(size: 19, weight: .bold))
                Text(model.preferences.enabled ? "\(model.activeCount)個のアプリを個別にコントロール" : "アプリの音に、それぞれの行き先を。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Toggle("音声制御", isOn: Binding(get: { model.preferences.enabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden().help("アプリ別の音声制御を有効にする")
                .accessibilityLabel("音声制御を有効にする")
        }.padding(18)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("音の行き先を、自由に。").font(.system(size: 15, weight: .semibold))
            Text("アプリごとに出力先と音量を選べます。右上のスイッチで音声制御を有効にしてください。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("最初の設定時に、macOSの音声取得の許可が必要です。", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(accent)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "speaker.wave.2").font(.system(size: 30, weight: .light)).foregroundStyle(accent.opacity(0.7))
            Text(model.search.isEmpty ? "音声を再生してみましょう" : "一致するアプリはありません").font(.system(size: 14, weight: .medium))
            Text("音声を再生中のアプリがここに表示されます。\n「すべて表示」で、再生前にも設定できます。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("起動中のアプリを表示") { model.setShowAll(true) }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).padding(.vertical, 34)
    }
    private var help: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("はじめに").font(.system(size: 13, weight: .semibold))
            Text("1. 音声制御を有効にします。\n2. ChromeやChatGPTで音声を再生します。\n3. 各アプリの出力先・音量を設定します。\n4. macOSの確認画面で音声の取得を許可します。")
                .font(.system(size: 12)).lineSpacing(4)
            Text("音声はこのMacのメモリ内で処理され、録音ファイルの保存や送信は行いません。未接続の出力先は設定を保持し、通常のアプリ出力に戻します。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("録音の許可を確認") { model.openPrivacy() }
                Button("音声制御を再接続") { model.audio.retry() }
            }.font(.system(size: 11))
            Text("許可を変更した後は、必要に応じて音分けを再起動してください。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(13).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
    }
    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11))
            .foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private var footer: some View {
        HStack(spacing: 13) {
            Circle().fill(model.preferences.enabled ? accent : .secondary).frame(width: 6, height: 6)
            Text(model.preferences.enabled ? "音声制御 ON" : "音声制御 OFF").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }.help("使い方とアクセス許可")
            Menu {
                Button("ウインドウで開く", action: openWindow)
                Button("設定フォルダを開く") { model.openSettingsFolder() }
                Button("音声制御を再接続") { model.audio.retry() }
                Divider()
                Button("音分けを終了") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize().help("設定")
        }.buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 13)
    }
}

private struct AppRow: View {
    @ObservedObject var model: AppModel
    let app: AudioApplication
    private var rule: AppRule { model.rule(for: app) }
    private var status: RouteStatus { model.snapshot.statuses[app.id] ?? .native }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIcon(path: app.bundlePath)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        if app.isPlaying { Circle().fill(accent).frame(width: 4, height: 4) }
                        Text(status.text).font(.system(size: 10)).foregroundStyle(status.isWarning ? .orange : .secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Text(app.id)
                    Button("このアプリの設定をリセット") { model.reset(app) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 8) {
                Image(systemName: deviceSymbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                Picker("\(app.name)の出力先", selection: Binding(get: { rule.deviceUID ?? "" }, set: { model.setDevice($0, app: app) })) {
                    Text("システムの標準出力").tag("")
                    ForEach(model.snapshot.devices) { device in Text(device.name).tag(device.uid) }
                    if let uid = rule.deviceUID, !model.snapshot.devices.contains(where: { $0.uid == uid }) {
                        Text("\(rule.deviceName ?? uid)（未接続）").tag(uid)
                    }
                }.labelsHidden().controlSize(.small)
            }
            HStack(spacing: 9) {
                Button { model.toggleMute(app) } label: {
                    Image(systemName: rule.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(rule.muted ? .orange : .secondary).frame(width: 22, height: 24)
                }.buttonStyle(.plain).help(rule.muted ? "ミュート解除" : "ミュート")
                    .accessibilityLabel("\(app.name)を\(rule.muted ? "ミュート解除" : "ミュート")")
                Slider(value: Binding(get: { rule.volume }, set: { model.setVolume($0, app: app) }), in: 0...1)
                    .controlSize(.small).opacity(rule.muted ? 0.45 : 1)
                    .accessibilityLabel("\(app.name)の音量")
                    .accessibilityValue("\(Int(rule.volume * 100))パーセント")
                Text(rule.muted ? "消音" : "\(Int((rule.volume * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 37, alignment: .trailing)
            }
        }.padding(13)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.055), lineWidth: 1))
    }
    private var deviceSymbol: String {
        guard let device = model.snapshot.devices.first(where: { $0.uid == rule.deviceUID }) else { return "speaker.wave.2" }
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        default: return "speaker.wave.2"
        }
    }
}

private struct AppIcon: View {
    let path: String?
    var body: some View {
        Group {
            if let path { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable() }
            else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
        }.frame(width: 32, height: 32).accessibilityHidden(true)
    }
}
