#if canImport(AppIntents)
import AppIntents
import Foundation

@available(iOS 16.0, *)
struct StartBridgeCallIntent: AppIntent {
    static var title: LocalizedStringResource = "SimBridge ile Ara"
    static var description = IntentDescription("Belirtilen kişiyi veya numarayı SimBridge üzerinden Android hattınızla arar.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Kişi veya Numara")
    var target: String

    @MainActor
    func perform() async throws -> some IntentResult {
        BridgeClient.shared.handleAppBecameActive()
        let simSlot = BridgeClient.shared.validatedSimSlot(
            UserDefaults.standard.integer(forKey: "simbridge.preferredSimSlot")
        )
        if let resolved = ContactsHelper.shared.resolveTarget(for: target) {
            CallKitManager.shared.startOutgoingCall(
                number: resolved.number,
                contactName: resolved.name,
                simSlot: simSlot
            )
        } else {
            CallKitManager.shared.startOutgoingCall(
                number: target,
                contactName: ContactsHelper.shared.resolveName(for: target),
                simSlot: simSlot
            )
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct SimBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartBridgeCallIntent(),
            phrases: [
                "\(.applicationName) ile ara",
                "\(.applicationName) arama yap"
            ],
            shortTitle: "SimBridge ile Ara",
            systemImageName: "phone.fill"
        )
    }
}
#endif
