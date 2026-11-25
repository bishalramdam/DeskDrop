import CoreBluetooth
import Foundation

final class BLEBeacon: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "D35CD20F-0001-4000-8000-00805F9B34FB")

    private var peripheralManager: CBPeripheralManager?
    private var shouldAdvertise = false

    func start() {
        shouldAdvertise = true
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        } else {
            updateAdvertising()
        }
    }

    func stop() {
        shouldAdvertise = false
        peripheralManager?.stopAdvertising()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        updateAdvertising()
    }

    private func updateAdvertising() {
        guard let peripheral = peripheralManager else { return }
        if shouldAdvertise && peripheral.state == .poweredOn {
            if !peripheral.isAdvertising {
                let deviceName = Host.current().localizedName ?? "Mac"
                peripheral.startAdvertising([
                    CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                    CBAdvertisementDataLocalNameKey: "DeskDrop-\(deviceName)"
                ])
            }
        } else {
            peripheral.stopAdvertising()
        }
    }
}
