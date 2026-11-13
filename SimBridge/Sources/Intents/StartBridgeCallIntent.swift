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
        if let resolved = ContactsHelper.shared.resolveTarget(for: target) {
            CallKitManager.shared.startOutgoingCall(number: resolved.number, contactName: resolved.name)
        } else {
            CallKitManager.shared.startOutgoingCall(
                number: target,
                contactName: ContactsHelper.shared.resolveName(for: target)
            )
        }
        return .result()
    }
}
#endif
