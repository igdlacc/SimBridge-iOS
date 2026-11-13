import SwiftUI

struct RecentsView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @State private var mode: Int = 0
    @State private var search: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Görünüm", selection: $mode) {
                    Text("Son Aramalar").tag(0)
                    Text("Rehber").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if mode == 0 {
                    List(filteredRecents) { rec in
                        Button {
                            let resolved = contacts.resolveName(for: rec.number) ?? rec.contactName
                            CallKitManager.shared.startOutgoingCall(number: rec.number, contactName: resolved)
                        } label: {
                            HStack {
                                Image(systemName: iconName(rec.type))
                                    .foregroundStyle(rec.type == "missed" ? .red : .green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contacts.resolveName(for: rec.number) ?? rec.contactName ?? rec.number)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(rec.type == "missed" ? .red : .primary)
                                    Text(rec.number)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatDate(rec.timestampMs))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if rec.durationSec > 0 {
                                        Text("\(rec.durationSec) sn")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                } else {
                    if !contacts.authorized {
                        VStack(spacing: 14) {
                            Spacer()
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Rehber İzni Gerekli")
                                .font(.headline)
                            Text("iPhone rehberindeki kişileri aramak ve arayan adlarını görmek için izin verin.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Button("Rehbere İzin Ver") {
                                contacts.requestAccessAndLoad()
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                        }
                    } else {
                        List(filteredContacts) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.name).font(.headline)
                                ForEach(c.numbers, id: \.self) { num in
                                    Button {
                                        CallKitManager.shared.startOutgoingCall(number: num, contactName: c.name)
                                    } label: {
                                        Label(num, systemImage: "phone.fill")
                                            .font(.subheadline)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .searchable(text: $search, prompt: "Ad veya numara ara")
            .navigationTitle(mode == 0 ? "Son Aramalar" : "Rehber")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bridge.sendCommand(BridgeWsMessage(type: "sync_request"))
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var filteredRecents: [RecentCallDto] {
        guard !search.isEmpty else { return bridge.recentCalls }
        return bridge.recentCalls.filter {
            $0.number.localizedCaseInsensitiveContains(search) ||
            ($0.contactName?.localizedCaseInsensitiveContains(search) == true) ||
            (contacts.resolveName(for: $0.number)?.localizedCaseInsensitiveContains(search) == true)
        }
    }

    private var filteredContacts: [SimpleContact] {
        guard !search.isEmpty else { return contacts.contacts }
        return contacts.contacts.filter { c in
            c.name.localizedCaseInsensitiveContains(search) ||
            c.numbers.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private func iconName(_ type: String) -> String {
        switch type {
        case "outgoing": return "phone.arrow.up.right"
        case "missed": return "phone.down"
        default: return "phone.arrow.down.left"
        }
    }

    private func formatDate(_ ms: Int64) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "tr_TR")
        df.doesRelativeDateFormatting = true
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}
