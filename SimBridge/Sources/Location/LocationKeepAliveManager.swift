import CoreLocation
import Foundation
import UIKit

@MainActor
final class LocationKeepAliveManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationKeepAliveManager()

    private static let enabledKey = "simbridge.location.keepalive.enabled"
    private static let requestedAlwaysOnceKey = "simbridge.location.requestedAlwaysOnce"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            applyState()
        }
    }

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isRunning: Bool = false

    private let manager = CLLocationManager()

    private override init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            self.isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        // Strictly kCLDistanceFilterNone so iOS 16.4+ locationd never treats the background session as idle.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation
        authorizationStatus = manager.authorizationStatus
    }

    func startIfAuthorized() {
        authorizationStatus = manager.authorizationStatus
        applyState()
    }

    func refreshAuthorizationState() {
        authorizationStatus = manager.authorizationStatus
        applyState()
    }

    func requestAlwaysPermission() {
        let status = manager.authorizationStatus
        authorizationStatus = status
        switch status {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            if !UserDefaults.standard.bool(forKey: Self.requestedAlwaysOnceKey) {
                UserDefaults.standard.set(true, forKey: Self.requestedAlwaysOnceKey)
                manager.requestAlwaysAuthorization()
            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .authorizedAlways:
            applyState()
        @unknown default:
            manager.requestAlwaysAuthorization()
        }
    }

    private func applyState() {
        let authorized = (authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse)
        let hasLocationMode = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") == true

        if isEnabled && authorized {
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            manager.distanceFilter = kCLDistanceFilterNone
            manager.pausesLocationUpdatesAutomatically = false
            manager.activityType = .otherNavigation
            if hasLocationMode {
                manager.allowsBackgroundLocationUpdates = true
            }
            // With "Her Zaman" (Always), hides blue status pill / Dynamic Island indicator completely.
            manager.showsBackgroundLocationIndicator = false
            manager.startUpdatingLocation()
            if CLLocationManager.significantLocationChangeMonitoringAvailable() {
                manager.startMonitoringSignificantLocationChanges()
            }
            isRunning = true
        } else {
            manager.stopUpdatingLocation()
            if CLLocationManager.significantLocationChangeMonitoringAvailable() {
                manager.stopMonitoringSignificantLocationChanges()
            }
            isRunning = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            self.applyState()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if UIApplication.shared.applicationState != .active {
                BridgeClient.shared.onBackgroundLocationTick()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CLError.locationUnknown updates during cell/Wi-Fi triangulation.
        _ = error
    }
}
