import SwiftUI

@main
struct PhonePadApp: App {
    @StateObject private var ble = BLEPeripheral()
    @StateObject private var hid = HIDPeripheral()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(hid)
        }
    }
}
