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
                onScroll: { steps in ble.sendScroll(v: Int8(steps), h: 0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Text("トラックパッド")
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            )

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
            HStack(spacing: 10) {
                HoldButton(label: "L") { down in ble.sendButton(0, down: down) }
                HoldButton(label: "R") { down in ble.sendButton(1, down: down) }
                Button {
                    keyboardOpen.toggle()
                } label: {
                    Label(keyboardOpen ? "キーボードを閉じる" : "キーボード",
                          systemImage: keyboardOpen ? "keyboard.chevron.compact.down" : "keyboard")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }

            if !lastTyped.isEmpty {
                Text("送信済み: \(lastTyped.suffix(30))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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

/// 押している間だけマウスボタンを down にするボタン（ドラッグ用）
private struct HoldButton: View {
    var label: String
    var onPressChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Text(label)
            .frame(width: 64)
            .padding(.vertical, 10)
            .background(pressed ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPressChange(true)
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onPressChange(false)
                    }
            )
    }
}
