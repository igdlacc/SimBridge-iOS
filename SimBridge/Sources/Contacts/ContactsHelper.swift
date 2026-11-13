import Contacts
import Foundation

struct SimpleContact: Identifiable, Hashable {
    let id: String
    let name: String
    let numbers: [String]
}

@MainActor
final class ContactsHelper: ObservableObject {
    static let shared = ContactsHelper()

    @Published private(set) var contacts: [SimpleContact] = []
    @Published private(set) var authorized: Bool = false

    private let store = CNContactStore()
    private var suffixIndex: [String: String] = [:]

    private init() {
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        authorized = (status == .authorized)
        if authorized {
            loadContacts()
        }
    }

    func requestAccessAndLoad() {
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                if granted { self?.loadContacts() }
            }
        }
    }

    func resolveName(for number: String) -> String? {
        let suffix = Self.normalizeSuffix(number)
        guard suffix.count >= 7 else { return nil }
        return suffixIndex[suffix]
    }

    private func loadContacts() {
        Task.detached(priority: .utility) {
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
            var loaded: [SimpleContact] = []
            var idx: [String: String] = [:]
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: req) { c, _ in
                let fullName = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    .ifEmpty(c.organizationName)
                let nums = c.phoneNumbers.map { $0.value.stringValue }.filter { !$0.isEmpty }
                guard !fullName.isEmpty, !nums.isEmpty else { return }
                loaded.append(SimpleContact(id: c.identifier, name: fullName, numbers: nums))
                for n in nums {
                    let sfx = Self.normalizeSuffix(n)
                    if sfx.count >= 7 {
                        idx[sfx] = fullName
                    }
                }
            }
            loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run {
                self.contacts = loaded
                self.suffixIndex = idx
            }
        }
    }

    static func normalizeSuffix(_ number: String) -> String {
        let digits = number.filter { $0.isNumber }
        return String(digits.suffix(10))
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
