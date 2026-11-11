import SwiftUI

@main
struct PhonePadApp: App {
    @StateObject private var ble = BLEPeripheral()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
        }
    }
}
