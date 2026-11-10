import CoreBluetooth
import Foundation

/// BLE ペリフェラル。カスタム GATT サービスでマウス/テキスト入力を notify 送信する。
/// プロトコルは README.md を参照。
final class BLEPeripheral: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-4789-ABCD-000000000001")
    static let mouseUUID = CBUUID(string: "A1B2C3D4-E5F6-4789-ABCD-000000000002")
    static let textUUID = CBUUID(string: "A1B2C3D4-E5F6-4789-ABCD-000000000003")

    @Published var bluetoothReady = false
    @Published var isAdvertising = false
    @Published var isConnected = false

    private var manager: CBPeripheralManager!
    private var mouseChar: CBMutableCharacteristic!
    private var textChar: CBMutableCharacteristic!
    private var serviceAdded = false
    private var subscribedMouse = false
    private var subscribedText = false

    // テキストとマウスのボタン/スクロールは送信キューを積んで取りこぼさない。
    // マウス move は合体（coalesce）して間引くが、端数は蓄積して捨てない。
    private var textQueue: [Data] = []
    private var mouseQueue: [Data] = []
    private var pendingDX: Double = 0
    private var pendingDY: Double = 0
    private var flushTimer: Timer?
    private var drainTimer: Timer?

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
        // タッチ操作中（トラッキングモード）でも止まらないよう common モードで回す。
        // default モードだけだとドラッグ中にタイマーが止まり、移動が固まって届く。
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            self?.flushMove()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
        // 送信キューが IsReady コールバック頼みで詰まらないよう、定期的にも流す（保険）
        let drain = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.drainTextQueue()
            self?.drainMouseQueue()
        }
        RunLoop.main.add(drain, forMode: .common)
        drainTimer = drain
    }

    // MARK: - Advertising

    func startAdvertising() {
        guard bluetoothReady else { return }
        if !serviceAdded {
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            mouseChar = CBMutableCharacteristic(
                type: Self.mouseUUID,
                properties: [.notify],
                value: nil,
                permissions: [.readable]
            )
            textChar = CBMutableCharacteristic(
                type: Self.textUUID,
                properties: [.notify],
                value: nil,
                permissions: [.readable]
            )
            service.characteristics = [mouseChar, textChar]
            manager.add(service) // didAdd で広告開始
            serviceAdded = true
        } else {
            beginAdvertise()
        }
    }

    func stopAdvertising() {
        manager.stopAdvertising()
        isAdvertising = false
    }

    private func beginAdvertise() {
        guard !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "PhonePad",
        ])
        isAdvertising = true
    }

    // MARK: - Mouse API

    /// 相対移動。次の flush (8ms 周期) でまとめて送る。端数は次回に持ち越す。
    func sendMove(dx: Double, dy: Double) {
        pendingDX += dx
        pendingDY += dy
    }

    private func flushMove() {
        guard subscribedMouse else { return }
        let sendX = Int(pendingDX) // 0方向への切り捨て。余りは次回に残る
        let sendY = Int(pendingDY)
        guard sendX != 0 || sendY != 0 else { return }
        pendingDX -= Double(sendX)
        pendingDY -= Double(sendY)
        let dx = Int16(max(Int(Int16.min), min(Int(Int16.max), sendX)))
        let dy = Int16(max(Int(Int16.min), min(Int(Int16.max), sendY)))
        var data = Data([0x01])
        withUnsafeBytes(of: dx.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: dy.littleEndian) { data.append(contentsOf: $0) }
        if !manager.updateValue(data, for: mouseChar, onSubscribedCentrals: nil) {
            // 送信キュー満杯で落ちた分は次回に回す（ボタン系と違い move は合体できる）
            pendingDX += Double(dx)
            pendingDY += Double(dy)
        }
    }

    /// button: 0=左, 1=右, 2=中。ボタンとスクロールは確実に届ける（キュー＋再送）。
    func sendButton(_ button: UInt8, down: Bool) {
        enqueueMouse(Data([0x02, button, down ? 1 : 0]))
    }

    /// タップ相当のクリック。down と up の間に少し間を空け、受け手が取りこぼさないようにする。
    func sendClick(_ button: UInt8) {
        sendButton(button, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendButton(button, down: false)
        }
    }

    /// v: 正=上方向, h: 正=右方向
    func sendScroll(v: Int8, h: Int8) {
        enqueueMouse(Data([0x03, UInt8(bitPattern: v), UInt8(bitPattern: h)]))
    }

    private func enqueueMouse(_ data: Data) {
        mouseQueue.append(data)
        drainMouseQueue()
    }

    private func drainMouseQueue() {
        guard subscribedMouse else { return }
        while let head = mouseQueue.first {
            if manager.updateValue(head, for: mouseChar, onSubscribedCentrals: nil) {
                mouseQueue.removeFirst()
            } else {
                break // キュー満杯。peripheralManagerIsReady で再開する
            }
        }
    }

    // MARK: - Text API

    /// 確定済みテキストを打つ。マルチバイト文字の途中で割らないよう文字単位でチャンクする。
    /// チャンクは BLE の最小 MTU(23) でも確実に載る 20 バイト以下にする。
    /// 大きな値は updateValue が受け付けず、テキストだけ黙って届かない事故になる。
    func sendType(_ string: String) {
        guard !string.isEmpty else { return }
        var chunk = ""
        var chunkBytes = 0
        for ch in string {
            let b = String(ch).utf8.count
            if chunkBytes + b > 20, !chunk.isEmpty {
                enqueueText(Data([0x01]) + Data(chunk.utf8))
                chunk = ""
                chunkBytes = 0
            }
            chunk.append(ch)
            chunkBytes += b
        }
        if !chunk.isEmpty {
            enqueueText(Data([0x01]) + Data(chunk.utf8))
        }
    }

    func sendBackspaces(_ count: Int) {
        var n = count
        while n > 0 {
            let c = min(n, 255)
            enqueueText(Data([0x02, UInt8(c)]))
            n -= c
        }
    }

    func sendEnter() {
        enqueueText(Data([0x03]))
    }

    /// key: 0=Esc, 1=Tab, 2=←, 3=→, 4=↑, 5=↓
    func sendSpecialKey(_ key: UInt8) {
        enqueueText(Data([0x04, key]))
    }

    private func enqueueText(_ data: Data) {
        textQueue.append(data)
        drainTextQueue()
    }

    private func drainTextQueue() {
        guard subscribedText else { return }
        while let head = textQueue.first {
            if manager.updateValue(head, for: textChar, onSubscribedCentrals: nil) {
                textQueue.removeFirst()
            } else {
                break // キュー満杯。peripheralManagerIsReady で再開する
            }
        }
    }

    private func refreshConnectionState() {
        isConnected = subscribedMouse || subscribedText
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEPeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        bluetoothReady = peripheral.state == .poweredOn
        if bluetoothReady, isAdvertising, !peripheral.isAdvertising {
            beginAdvertise()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if error == nil {
            beginAdvertise()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.mouseUUID {
            subscribedMouse = true
            drainMouseQueue()
        }
        if characteristic.uuid == Self.textUUID {
            subscribedText = true
            drainTextQueue()
        }
        refreshConnectionState()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.mouseUUID { subscribedMouse = false }
        if characteristic.uuid == Self.textUUID { subscribedText = false }
        refreshConnectionState()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainTextQueue()
        drainMouseQueue()
    }
}
