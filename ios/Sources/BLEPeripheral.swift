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

    // テキストは送信キューを積んで取りこぼさない。マウス move は合体（coalesce）して間引く。
    private var textQueue: [Data] = []
    private var pendingDX: Int = 0
    private var pendingDY: Int = 0
    private var flushTimer: Timer?

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { [weak self] _ in
            self?.flushMove()
        }
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

    /// 相対移動。次の flush (8ms 周期) でまとめて送る。
    func sendMove(dx: Double, dy: Double) {
        pendingDX += Int(dx.rounded())
        pendingDY += Int(dy.rounded())
    }

    private func flushMove() {
        guard subscribedMouse, pendingDX != 0 || pendingDY != 0 else { return }
        let dx = max(Int16.min, min(Int16.max, Int16(pendingDX)))
        let dy = max(Int16.min, min(Int16.max, Int16(pendingDY)))
        pendingDX = 0
        pendingDY = 0
        var data = Data([0x01])
        withUnsafeBytes(of: dx.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: dy.littleEndian) { data.append(contentsOf: $0) }
        _ = manager.updateValue(data, for: mouseChar, onSubscribedCentrals: nil)
    }

    /// button: 0=左, 1=右, 2=中
    func sendButton(_ button: UInt8, down: Bool) {
        guard subscribedMouse else { return }
        let data = Data([0x02, button, down ? 1 : 0])
        _ = manager.updateValue(data, for: mouseChar, onSubscribedCentrals: nil)
    }

    /// v: 正=上方向, h: 正=右方向
    func sendScroll(v: Int8, h: Int8) {
        guard subscribedMouse else { return }
        let data = Data([0x03, UInt8(bitPattern: v), UInt8(bitPattern: h)])
        _ = manager.updateValue(data, for: mouseChar, onSubscribedCentrals: nil)
    }

    // MARK: - Text API

    /// 確定済みテキストを打つ。マルチバイト文字の途中で割らないよう文字単位でチャンクする。
    func sendType(_ string: String) {
        guard !string.isEmpty else { return }
        var chunk = ""
        var chunkBytes = 0
        for ch in string {
            let b = String(ch).utf8.count
            if chunkBytes + b > 160, !chunk.isEmpty {
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
        if characteristic.uuid == Self.mouseUUID { subscribedMouse = true }
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
    }
}
