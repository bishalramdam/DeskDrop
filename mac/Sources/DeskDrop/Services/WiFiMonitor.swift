import CoreLocation
import CoreWLAN
import Foundation
import Network

@MainActor
final class WiFiMonitor: NSObject, ObservableObject, CLLocationManagerDelegate, CWEventDelegate {
    @Published private(set) var currentSSID: String?
    @Published private(set) var isOnWiFi: Bool = true
    @Published private(set) var locationAuthorized: Bool = false

    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient.shared()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.bishal.DeskDrop.wifiMonitor")
    private var retryTask: Task<Void, Never>?
    var onNetworkChange: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        wifiClient.delegate = self
        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .linkDidChange)

        updateAuthorizationState()
        refreshSSID()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifiUp = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnWiFi = wifiUp
                self.refreshSSID()
                self.onNetworkChange?()
                if wifiUp && self.currentSSID == nil {
                    self.scheduleSSIDRetry()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        pathMonitor.cancel()
        try? wifiClient.stopMonitoringAllEvents()
    }

    func requestLocationAccessIfNeeded() {
        updateAuthorizationState()
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func refreshSSID() {
        updateAuthorizationState()
        currentSSID = wifiClient.interface()?.ssid()
    }

    private func scheduleSSIDRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            for delaySec in [1, 2, 3] {
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshSSID()
                if self.currentSSID != nil {
                    self.onNetworkChange?()
                    return
                }
            }
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID()
            self?.onNetworkChange?()
        }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID()
            self?.onNetworkChange?()
        }
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
