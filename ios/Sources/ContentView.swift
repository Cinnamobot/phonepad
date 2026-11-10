import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLEPeripheral
    @State private var keyboardOpen = false
    @State private var lastTyped = ""

    var body: some View {
        VStack(spacing: 14) {
            // 状態表示
            HStack {
                Circle()
                    .fill(ble.isConnected ? Color.green : (ble.isAdvertising ? Color.orange : Color.gray))
                    .frame(width: 10, height: 10)
                Text(ble.isConnected ? "接続中" : (ble.isAdvertising ? "待ち受け中…" : "停止中"))
                    .font(.subheadline)
                Spacer()
                Button(ble.isAdvertising ? "待ち受け停止" : "待ち受け開始") {
                    ble.isAdvertising ? ble.stopAdvertising() : ble.startAdvertising()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!ble.bluetoothReady)
            }

            // トラックパッド面
            TrackpadView(
                onMove: { dx, dy in ble.sendMove(dx: dx, dy: dy) },
                onTap: { fingers in
                    ble.sendClick(fingers == 1 ? 0 : 1)
                },
                onScroll: { steps in ble.sendScroll(v: Int8(steps), h: 0) },
                onHoldChange: { down in ble.sendButton(0, down: down) },
                onThreeFinger: { gesture in
                    // Windowsタッチパッド標準の割り当て
                    switch gesture {
                    case .tap: ble.sendShortcut(4)       // Win+S（検索）
                    case .swipeUp: ble.sendShortcut(0)   // Win+Tab（タスクビュー）
                    case .swipeDown: ble.sendShortcut(1) // Win+D（デスクトップ表示）
                    case .swipeRight: ble.sendShortcut(2) // Alt+Tab（次のアプリ）
                    case .swipeLeft: ble.sendShortcut(3)  // Alt+Shift+Tab（前のアプリ）
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Text("トラックパッド")
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            )

            Text("タップ=クリック　トン、ツーと続けて動かす=ドラッグ　2本指タップ=右クリック　2本指上下=スクロール　3本指タップ=検索　3本指スワイプ=タスクビュー/アプリ切替")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // 特殊キー（キーボード表示中のみ）
            if keyboardOpen {
                HStack(spacing: 8) {
                    specialKey("esc", label: "Esc") { ble.sendSpecialKey(0) }
                    specialKey("tab", label: "Tab") { ble.sendSpecialKey(1) }
                    specialKey("arrow.left", label: "←") { ble.sendSpecialKey(2) }
                    specialKey("arrow.right", label: "→") { ble.sendSpecialKey(3) }
                    specialKey("arrow.up", label: "↑") { ble.sendSpecialKey(4) }
                    specialKey("arrow.down", label: "↓") { ble.sendSpecialKey(5) }
                }
            }

            // ボタン行
            Button {
                keyboardOpen.toggle()
            } label: {
                Label(keyboardOpen ? "キーボードを閉じる" : "キーボード",
                      systemImage: keyboardOpen ? "keyboard.chevron.compact.down" : "keyboard")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)

            if !lastTyped.isEmpty {
                Text("送信済み: \(lastTyped.suffix(30))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // テキスト送信の切り分け用（購読・パケット上限・成功/失敗数）
            Text("text診断: 購読\(ble.textSubscribed ? "OK" : "なし") / 上限\(ble.textPayloadLimit)B / 送信\(ble.textPacketsSent) / 失敗\(ble.textSendFailures)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 隠しテキストフィールド（キーボードの受け口）
            KeyboardBridge(
                isOpen: $keyboardOpen,
                onCommit: { backspaces, text in
                    if backspaces > 0 { ble.sendBackspaces(backspaces) }
                    if !text.isEmpty {
                        ble.sendType(text)
                        lastTyped += text
                    }
                    if backspaces > 0 {
                        lastTyped = String(lastTyped.dropLast(min(backspaces, lastTyped.count)))
                    }
                },
                onEnter: {
                    ble.sendEnter()
                    lastTyped = ""
                }
            )
            .frame(width: 10, height: 1)
        }
        .padding()
        .onAppear {
            if ble.bluetoothReady { ble.startAdvertising() }
        }
        .onChange(of: ble.bluetoothReady) { _, ready in
            if ready { ble.startAdvertising() }
        }
    }

    private func specialKey(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
