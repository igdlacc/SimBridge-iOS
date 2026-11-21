import CoreLocation
import Foundation
import UIKit

enum BackgroundKeepAliveMode: String, CaseIterable, Identifiable {
    case apnsBatterySaver
    case continuousLan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apnsBatterySaver:
            return "Pil Dostu (APNs)"
        case .continuousLan:
            return "7/24 Aktif LAN"
        }
    }
}

@MainActor
final class LocationKeepAliveManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationKeepAliveManager()

    private static let modeKey = "simbridge.location.keepalive.mode"
    private static let autoPauseLowPowerKey = "simbridge.location.keepalive.autoPauseLowPower"
    private static let lastWakeAtKey = "simbridge.location.keepalive.lastWakeAt"
    private static let lastWakeSourceKey = "simbridge.location.keepalive.lastWakeSource"
    private static let requestedAlwaysOnceKey = "simbridge.location.requestedAlwaysOnce"

    @Published var mode: BackgroundKeepAliveMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            applyState()
        }
    }

    @Published var autoPauseInLowPowerMode: Bool {
        didSet {
            UserDefaults.standard.set(autoPauseInLowPowerMode, forKey: Self.autoPauseLowPowerKey)
            applyState()
        }
    }

    @Published private(set) var isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var isPausedForLowPower: Bool = false
    @Published private(set) var lastBackgroundWakeAt: Date?
    @Published private(set) var lastBackgroundWakeSource: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isRunning: Bool = false

    var isEnabled: Bool {
        mode == .continuousLan
    }

    private let manager = CLLocationManager()
    private var backgroundTickTimer: DispatchSourceTimer?
    private var backgroundActivitySession: AnyObject?
    private var powerStateObserver: NSObjectProtocol?
    private var lastLocationRestartAt: Date = Date()

    private override init() {
        if let rawMode = UserDefaults.standard.string(forKey: Self.modeKey),
           let parsedMode = BackgroundKeepAliveMode(rawValue: rawMode) {
            self.mode = parsedMode
        } else {
            self.mode = .apnsBatterySaver
            UserDefaults.standard.set(BackgroundKeepAliveMode.apnsBatterySaver.rawValue, forKey: Self.modeKey)
        }

        if UserDefaults.standard.object(forKey: Self.autoPauseLowPowerKey) == nil {
            self.autoPauseInLowPowerMode = true
            UserDefaults.standard.set(true, forKey: Self.autoPauseLowPowerKey)
        } else {
            self.autoPauseInLowPowerMode = UserDefaults.standard.bool(forKey: Self.autoPauseLowPowerKey)
        }

        if let savedWakeTs = UserDefaults.standard.object(forKey: Self.lastWakeAtKey) as? TimeInterval,
           savedWakeTs > 0 {
            self.lastBackgroundWakeAt = Date(timeIntervalSince1970: savedWakeTs)
        } else {
            self.lastBackgroundWakeAt = nil
        }
        self.lastBackgroundWakeSource = UserDefaults.standard.string(forKey: Self.lastWakeSourceKey)

        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Strictly kCLDistanceFilterNone so iOS 16.4+ locationd never treats the background session as idle.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        authorizationStatus = manager.authorizationStatus
        isPausedForLowPower = (mode == .continuousLan) && autoPauseInLowPowerMode && isLowPowerModeEnabled

        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.applyState()
            }
        }
    }

    @MainActor
    func recordBackgroundWake(source: String) {
        let now = Date()
        lastBackgroundWakeAt = now
        lastBackgroundWakeSource = source
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastWakeAtKey)
        UserDefaults.standard.set(source, forKey: Self.lastWakeSourceKey)
    }

    func startIfAuthorized() {
        authorizationStatus = manager.authorizationStatus
        applyState()
    }

    func refreshAuthorizationState() {
        authorizationStatus = manager.authorizationStatus
        applyState()
    }

    func promptIfNotDetermined() {
        authorizationStatus = manager.authorizationStatus
        if mode == .continuousLan && authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func requestAlwaysPermission() {
        let status = manager.authorizationStatus
        authorizationStatus = status
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
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
            manager.requestWhenInUseAuthorization()
        }
    }

    private func applyState() {
        let authorized = (authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse)
        let hasLocationMode = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") == true
        let wantContinuous = (mode == .continuousLan) && !(autoPauseInLowPowerMode && isLowPowerModeEnabled)
        isPausedForLowPower = (mode == .continuousLan) && autoPauseInLowPowerMode && isLowPowerModeEnabled

        if wantContinuous && authorized {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone
            manager.pausesLocationUpdatesAutomatically = false
            manager.activityType = .other
            if hasLocationMode {
                manager.allowsBackgroundLocationUpdates = true
            }
            // With "Her Zaman" (Always), hides blue status pill / Dynamic Island indicator completely.
            manager.showsBackgroundLocationIndicator = false
            if #available(iOS 17.0, *) {
                if backgroundActivitySession == nil {
                    backgroundActivitySession = CLBackgroundActivitySession()
                }
            }
            lastLocationRestartAt = Date()
            manager.startUpdatingLocation()
            if CLLocationManager.significantLocationChangeMonitoringAvailable() {
                manager.startMonitoringSignificantLocationChanges()
            }
            startBackgroundTickTimer()
            isRunning = true
        } else {
            if #available(iOS 17.0, *) {
                (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
            }
            backgroundActivitySession = nil
            stopBackgroundTickTimer()
            manager.stopUpdatingLocation()
            if hasLocationMode {
                manager.allowsBackgroundLocationUpdates = false
            }
            if CLLocationManager.significantLocationChangeMonitoringAvailable() {
                if authorized {
                    manager.startMonitoringSignificantLocationChanges()
                } else {
                    manager.stopMonitoringSignificantLocationChanges()
                }
            }
            isRunning = false
        }
    }

    private func startBackgroundTickTimer() {
        guard backgroundTickTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if UIApplication.shared.applicationState != .active {
                    BridgeClient.shared.onBackgroundLocationTick()
                }
                if Date().timeIntervalSince(self.lastLocationRestartAt) > 600 {
                    self.lastLocationRestartAt = Date()
                    self.manager.startUpdatingLocation()
                }
            }
        }
        backgroundTickTimer = timer
        timer.resume()
    }

    private func stopBackgroundTickTimer() {
        backgroundTickTimer?.cancel()
        backgroundTickTimer = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            self.applyState()
            if status == .authorizedWhenInUse,
               self.mode == .continuousLan,
               !UserDefaults.standard.bool(forKey: Self.requestedAlwaysOnceKey) {
                UserDefaults.standard.set(true, forKey: Self.requestedAlwaysOnceKey)
                self.manager.requestAlwaysAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if UIApplication.shared.applicationState != .active {
                self.recordBackgroundWake(source: self.isRunning ? "Aktif Konum" : "Anlamlı Konum")
                BridgeClient.shared.onBackgroundLocationTick()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CLError.locationUnknown updates during cell/Wi-Fi triangulation.
        _ = error
    }
}
