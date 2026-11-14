import Foundation

enum AppTab: Int, Hashable {
    case dialer = 0
    case recents = 1
    case sms = 2
    case settings = 3
}

struct SmsConversationTarget: Identifiable, Hashable {
    let address: String
    let title: String

    var id: String {
        let norm = ContactsHelper.normalizeAddressKey(address)
        return norm.isEmpty ? address : norm
    }
}

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var selectedTab: AppTab = .dialer {
        didSet {
            syncActiveViewingNotificationFilter()
        }
    }
    @Published var smsTargetToOpen: SmsConversationTarget? = nil
    @Published var activeCallSheetPresented: Bool = false
    private(set) var openConversationKey: String? = nil

    private init() {}

    func setActiveConversation(address: String) {
        let key = ContactsHelper.normalizeAddressKey(address)
        openConversationKey = key.isEmpty ? nil : key
        syncActiveViewingNotificationFilter()
    }

    func clearActiveConversation(address: String) {
        let key = ContactsHelper.normalizeAddressKey(address)
        if openConversationKey == key {
            openConversationKey = nil
            syncActiveViewingNotificationFilter()
        }
    }

    private func syncActiveViewingNotificationFilter() {
        let effectiveKey = (selectedTab == .sms) ? openConversationKey : nil
        NotificationManager.shared.setActivelyViewingConversationKey(effectiveKey)
    }

    func openSmsConversation(address: String, title: String? = nil) {
        let cleanAddr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAddr.isEmpty else { return }
        let resolvedTitle = (title?.isEmpty == false ? title : nil)
            ?? ContactsHelper.shared.resolveName(for: cleanAddr)
            ?? cleanAddr
        selectedTab = .sms
        smsTargetToOpen = SmsConversationTarget(address: cleanAddr, title: resolvedTitle)
    }
}
