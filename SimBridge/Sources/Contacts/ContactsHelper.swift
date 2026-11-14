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
    @Published private(set) var authorizationStatus: CNAuthorizationStatus = .notDetermined

    private let store = CNContactStore()
    private var suffixIndex: [String: String] = [:]
    private var hasLoadedOnce = false

    private init() {
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus(forceReload: Bool = false) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        authorizationStatus = status
        let isAuth = (status == .authorized)
        authorized = isAuth
        if isAuth && (!hasLoadedOnce || forceReload) {
            hasLoadedOnce = true
            loadContacts()
        }
    }

    func requestAccessAndLoad() {
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            Task { @MainActor in
                let status = CNContactStore.authorizationStatus(for: .contacts)
                self?.authorizationStatus = status
                self?.authorized = granted
                if granted {
                    self?.hasLoadedOnce = true
                    self?.loadContacts()
                }
            }
        }
    }

    func matchingContacts(for query: String, limit: Int = 5) -> [SimpleContact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let digitQuery = trimmed.filter { $0.isNumber }
        var hits: [SimpleContact] = []
        for contact in contacts {
            let nameMatch = contact.name.localizedCaseInsensitiveContains(trimmed)
            let numberMatch = contact.numbers.contains { num in
                if num.localizedCaseInsensitiveContains(trimmed) { return true }
                if digitQuery.count >= 3 {
                    return num.filter { $0.isNumber }.contains(digitQuery)
                }
                return false
            }
            if nameMatch || numberMatch {
                hits.append(contact)
                if hits.count >= limit { break }
            }
        }
        return hits
    }

    func resolveName(for number: String) -> String? {
        let suffix = Self.normalizeSuffix(number)
        guard suffix.count >= 7 else { return nil }
        return suffixIndex[suffix]
    }

    func resolveTarget(for query: String) -> (number: String, name: String?)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // If query matches a contact name (exact first, then substring), prefer their primary number.
        if let exact = contacts.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }),
           let num = exact.numbers.first {
            return (num, exact.name)
        }
        if let partial = contacts.first(where: { $0.name.localizedCaseInsensitiveContains(trimmed) }),
           let num = partial.numbers.first {
            return (num, partial.name)
        }

        let dialChars = trimmed.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        guard !dialChars.isEmpty else { return nil }
        return (dialChars, resolveName(for: dialChars))
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
