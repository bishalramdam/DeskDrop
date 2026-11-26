import CoreLocation
import CoreWLAN
import Foundation
import Network

@MainActor
final class WiFiMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var currentSSID: String?
    @Published private(set) var isOnWiFi: Bool = true
    @Published private(set) var locationAuthorized: Bool = false

    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.bishal.DeskDrop.wifiMonitor")
    var onNetworkChange: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        updateAuthorizationState()
        refreshSSID()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifiUp = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnWiFi = wifiUp
                self.refreshSSID()
                self.onNetworkChange?()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func requestLocationAccessIfNeeded() {
        updateAuthorizationState()
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func refreshSSID() {
        updateAuthorizationState()
        currentSSID = CWWiFiClient.shared().interface()?.ssid()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.refreshSSID()
            self?.onNetworkChange?()
        }
    }

    private func updateAuthorizationState() {
        let status = locationManager.authorizationStatus
        locationAuthorized = (status == .authorizedAlways || status == .authorized)
    }
}
