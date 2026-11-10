import CoreBluetooth
import Foundation

/// 実験実装: 標準の BLE HID マウス（HOGP, サービス 0x1812）として振る舞い、
/// レシーバプログラムなしで PC に直接ペアリングさせる。
/// レポート特性は暗号化必須にしてあり、接続時にペアリング（ボンディング）が走る。
/// まずはマウスのみ。キーボードは PC 側 IME との絡みがあるため別フェーズ。
final class HIDPeripheral: NSObject, ObservableObject {
    @Published var bluetoothReady = false
    @Published var isAdvertising = false
    @Published var isConnected = false

    private var manager: CBPeripheralManager!
    private var reportChar: CBMutableCharacteristic!
    private var servicesAdded = false
    private var addedCount = 0
    private var subscribed = false
    private var buttons: UInt8 = 0
    private var pendingDX = 0.0
    private var pendingDY = 0.0
    private var flushTimer: Timer?

    /// HID レポートマップ: マウス（ボタン3 + X/Y/ホイール相対 int8）, Report ID 1
    private static let reportMap: [UInt8] = [
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x02, // Usage (Mouse)
        0xA1, 0x01, // Collection (Application)
        0x85, 0x01, //   Report ID (1)
        0x09, 0x01, //   Usage (Pointer)
        0xA1, 0x00, //   Collection (Physical)
        0x05, 0x09, //     Usage Page (Button)
        0x19, 0x01, //     Usage Minimum (1)
        0x29, 0x03, //     Usage Maximum (3)
        0x15, 0x00, //     Logical Minimum (0)
        0x25, 0x01, //     Logical Maximum (1)
        0x95, 0x03, //     Report Count (3)
        0x75, 0x01, //     Report Size (1)
        0x81, 0x02, //     Input (Data, Var, Abs)
        0x95, 0x01, //     Report Count (1)
        0x75, 0x05, //     Report Size (5)
        0x81, 0x03, //     Input (Cnst, Var, Abs)
        0x05, 0x01, //     Usage Page (Generic Desktop)
        0x09, 0x30, //     Usage (X)
        0x09, 0x31, //     Usage (Y)
        0x09, 0x38, //     Usage (Wheel)
        0x15, 0x81, //     Logical Minimum (-127)
        0x25, 0x7F, //     Logical Maximum (127)
        0x75, 0x08, //     Report Size (8)
        0x95, 0x03, //     Report Count (3)
        0x81, 0x06, //     Input (Data, Var, Rel)
        0xC0,       //   End Collection
        0xC0,       // End Collection
    ]

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    // MARK: - Services / Advertising

    func startAdvertising() {
        guard bluetoothReady else { return }
        if servicesAdded {
            beginAdvertise()
            return
        }
        servicesAdded = true
        addedCount = 0

        // Device Information
        let dis = CBMutableService(type: CBUUID(string: "180A"), primary: true)
        let pnp = CBMutableCharacteristic(
            type: CBUUID(string: "2A50"), properties: [.read],
            value: Data([0x02, 0x34, 0x12, 0x78, 0x56, 0x01, 0x00]), // PnP: USB-IF, VID 0x1234, PID 0x5678, ver 1.0
            permissions: [.readable])
        let mfr = CBMutableCharacteristic(
            type: CBUUID(string: "2A29"), properties: [.read],
            value: Data("shafuneko".utf8), permissions: [.readable])
        dis.characteristics = [pnp, mfr]

        // Battery（HID デバイスの作法として用意。中身はダミー100%）
        let bas = CBMutableService(type: CBUUID(string: "180F"), primary: true)
        let level = CBMutableCharacteristic(
            type: CBUUID(string: "2A19"), properties: [.read, .notify],
            value: nil, permissions: [.readable])
        bas.characteristics = [level]

        // HID
        let hid = CBMutableService(type: CBUUID(string: "1812"), primary: true)
        let info = CBMutableCharacteristic(
            type: CBUUID(string: "2A4A"), properties: [.read],
            value: Data([0x11, 0x01, 0x00, 0x03]), // bcdHID 1.11, 国コード 0, リモートウェイク+通常接続可
            permissions: [.readable])
        let map = CBMutableCharacteristic(
            type: CBUUID(string: "2A4B"), properties: [.read],
            value: Data(Self.reportMap), permissions: [.readable])
        let ctrl = CBMutableCharacteristic(
            type: CBUUID(string: "2A4C"), properties: [.writeWithoutResponse],
            value: nil, permissions: [.writeable])
        let proto = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
            value: nil, permissions: [.readable, .writeable])
        reportChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A4D"),
            properties: [.read, .notify, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readable, .readEncryptionRequired])
        reportChar.descriptors = [
            CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([0x01, 0x01]) as NSData) // Report ID 1, Input
        ]
        hid.characteristics = [info, map, ctrl, proto, reportChar]

        manager.add(dis)
        manager.add(bas)
        manager.add(hid)
    }

    func stopAdvertising() {
        manager.stopAdvertising()
        isAdvertising = false
    }

    private func beginAdvertise() {
        guard !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
            CBAdvertisementDataLocalNameKey: "PhonePad",
        ])
        isAdvertising = true
    }

    // MARK: - Mouse API

    func sendMove(dx: Double, dy: Double) {
        pendingDX += dx
        pendingDY += dy
    }

    private func flush() {
        guard subscribed else { return }
        let sendX = Int(pendingDX)
        let sendY = Int(pendingDY)
        guard sendX != 0 || sendY != 0 else { return }
        pendingDX -= Double(sendX)
        pendingDY -= Double(sendY)
        // HID レポートの X/Y は int8。大きい分は次のフラッシュに残す
        let cx = max(-127, min(127, sendX))
        let cy = max(-127, min(127, sendY))
        pendingDX += Double(sendX - cx)
        pendingDY += Double(sendY - cy)
        sendReport(dx: Int8(cx), dy: Int8(cy), wheel: 0)
    }

    func sendButton(_ button: UInt8, down: Bool) {
        if down {
            buttons |= (1 << button)
        } else {
            buttons &= ~(1 << button)
        }
        sendReport(dx: 0, dy: 0, wheel: 0)
    }

    func sendClick(_ button: UInt8) {
        sendButton(button, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendButton(button, down: false)
        }
    }

    /// v: 正 = 上方向
    func sendScroll(v: Int8) {
        sendReport(dx: 0, dy: 0, wheel: v)
    }

    private func sendReport(dx: Int8, dy: Int8, wheel: Int8) {
        guard subscribed, let reportChar else { return }
        let data = Data([
            buttons,
            UInt8(bitPattern: dx),
            UInt8(bitPattern: dy),
            UInt8(bitPattern: wheel),
        ])
        _ = manager.updateValue(data, for: reportChar, onSubscribedCentrals: nil)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension HIDPeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        bluetoothReady = peripheral.state == .poweredOn
        if bluetoothReady, isAdvertising, !peripheral.isAdvertising {
            beginAdvertise()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if error == nil {
            addedCount += 1
            if addedCount >= 3 {
                beginAdvertise()
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == reportChar.uuid {
            subscribed = true
            isConnected = true
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == reportChar.uuid {
            subscribed = false
            isConnected = false
        }
    }
}
