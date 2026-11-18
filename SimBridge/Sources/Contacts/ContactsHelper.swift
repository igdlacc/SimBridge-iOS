import Contacts
import Foundation

struct SimpleContact: Identifiable, Hashable {
    let id: String
    let name: String
    let numbers: [String]
    var thumbnailData: Data? = nil
}

@MainActor
final class ContactsHelper: ObservableObject {
    static let shared = ContactsHelper()

    @Published private(set) var contacts: [SimpleContact] = []
    @Published private(set) var authorized: Bool = false
    @Published private(set) var authorizationStatus: CNAuthorizationStatus = .notDetermined

    private let store = CNContactStore()
    private var suffixIndex: [String: String] = [:]
    private var thumbnailBySuffix: [String: Data] = [:]
    private var contactIdBySuffix: [String: String] = [:]
    private var hasLoadedOnce = false
    private var storeObserver: NSObjectProtocol?

    private init() {
        refreshAuthorizationStatus()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
                    self.refreshAuthorizationStatus(forceReload: true)
                }
            }
        }
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
        let pureDigits = (trimmed.count >= 2 && trimmed.allSatisfy(\.isNumber))
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
            let t9Match = pureDigits && Self.t9Signature(contact.name).contains(trimmed)
            if nameMatch || numberMatch || t9Match {
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

    func thumbnailData(for number: String) -> Data? {
        let suffix = Self.normalizeSuffix(number)
        guard suffix.count >= 7 else { return nil }
        return thumbnailBySuffix[suffix]
    }

    func contactIdentifier(for number: String) -> String? {
        let suffix = Self.normalizeSuffix(number)
        guard suffix.count >= 7 else { return nil }
        return contactIdBySuffix[suffix]
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
                CNContactMiddleNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor
            ]
            let (sortedContacts, finalIndex, finalThumbs, finalIds): ([SimpleContact], [String: String], [String: Data], [String: String]) = {
                var loaded: [SimpleContact] = []
                var idx: [String: String] = [:]
                var thumbs: [String: Data] = [:]
                var cids: [String: String] = [:]
                let req = CNContactFetchRequest(keysToFetch: keys)
                try? CNContactStore().enumerateContacts(with: req) { c, _ in
                    let fullName = [c.givenName, c.middleName, c.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                        .ifEmpty(c.organizationName)
                    let nums = c.phoneNumbers.map { $0.value.stringValue }.filter { !$0.isEmpty }
                    guard !fullName.isEmpty, !nums.isEmpty else { return }
                    let thumb = c.thumbnailImageData
                    loaded.append(SimpleContact(id: c.identifier, name: fullName, numbers: nums, thumbnailData: thumb))
                    for n in nums {
                        let sfx = Self.normalizeSuffix(n)
                        if sfx.count >= 7 {
                            idx[sfx] = fullName
                            cids[sfx] = c.identifier
                            if let thumb {
                                thumbs[sfx] = thumb
                            }
                        }
                    }
                }
                loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return (loaded, idx, thumbs, cids)
            }()
            await MainActor.run {
                self.contacts = sortedContacts
                self.suffixIndex = finalIndex
                self.thumbnailBySuffix = finalThumbs
                self.contactIdBySuffix = finalIds
            }
        }
    }

    nonisolated static func t9Signature(_ name: String) -> String {
        let lower = name.lowercased(with: Locale(identifier: "tr_TR"))
        var out = ""
        out.reserveCapacity(lower.count)
        for ch in lower {
            switch ch {
            case "a", "b", "c", "ç", "à", "á", "â", "ä":
                out.append("2")
            case "d", "e", "f", "è", "é", "ê", "ë":
                out.append("3")
            case "g", "ğ", "h", "i", "ı", "î", "ï", "í", "ì":
                out.append("4")
            case "j", "k", "l":
                out.append("5")
            case "m", "n", "o", "ö", "ñ", "ó", "ò", "ô":
                out.append("6")
            case "p", "q", "r", "s", "ş", "ß":
                out.append("7")
            case "t", "u", "ü", "v", "ú", "ù", "û":
                out.append("8")
            case "w", "x", "y", "z":
                out.append("9")
            case "0"..."9":
                out.append(ch)
            default:
                break
            }
        }
        return out
    }

    nonisolated static func normalizeSuffix(_ number: String) -> String {
        let digits = number.filter { $0.isNumber }
        return String(digits.suffix(10))
    }

    nonisolated static func normalizeAddressKey(_ address: String) -> String {
        let digits = address.filter { $0.isNumber }
        if digits.count >= 7 {
            return String(digits.suffix(10))
        }
        return address.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
