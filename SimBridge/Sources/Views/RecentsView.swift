import SwiftUI
import UIKit

struct RecentsView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @ObservedObject private var router = AppRouter.shared
    @AppStorage("simbridge.preferredSimSlot") private var selectedSimSlot: Int = 0

    @State private var mode: Int = 0
    @State private var recentsFilter: Int = 0 // 0 = Tümü, 1 = Cevapsız
    @State private var search: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ConnectionStatusPill()
                SimSelectorBar(selectedSimSlot: $selectedSimSlot)

                Picker("Görünüm", selection: $mode) {
                    Text("Son Aramalar").tag(0)
                    Text("Rehber").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if mode == 0 {
                    Picker("Filtre", selection: $recentsFilter) {
                        Text("Tümü").tag(0)
                        Text("Cevapsız").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if filteredRecents.isEmpty {
                        emptyRecentsView
                    } else {
                        List(filteredRecents) { rec in
                            recentRow(rec)
                        }
                        .listStyle(.plain)
                        .refreshable {
                            bridge.sendCommand(BridgeWsMessage(type: "sync_request"))
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                } else {
                    contactsBody
                }
            }
            .searchable(text: $search, prompt: "Ad veya numara ara")
            .navigationTitle(mode == 0 ? "Son Aramalar" : "Rehber")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        SimHaptics.tap(.light)
                        if mode == 0 {
                            bridge.sendCommand(BridgeWsMessage(type: "sync_request"))
                        } else {
                            contacts.refreshAuthorizationStatus(forceReload: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ rec: RecentCallDto) -> some View {
        let resolvedName = contacts.resolveName(for: rec.number) ?? rec.contactName
        let displayTitle = resolvedName ?? rec.number

        Button {
            SimHaptics.tap(.medium)
            CallKitManager.shared.startOutgoingCall(
                number: rec.number,
                contactName: resolvedName,
                simSlot: bridge.validatedSimSlot(selectedSimSlot)
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(rec.type))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(rec.type == "missed" ? .red : (rec.type == "outgoing" ? .blue : .green))
                    .frame(width: 28, height: 28)
                    .background((rec.type == "missed" ? Color.red : (rec.type == "outgoing" ? Color.blue : Color.green)).opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(rec.type == "missed" ? .red : .primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if displayTitle != rec.number {
                            Text(rec.number)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(callTypeLabel(rec.type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if bridge.availableSims.count > 1 {
                            Text("SIM \(rec.simSlot + 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(BridgeFormatters.recentCallDate(ms: rec.timestampMs))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if rec.durationSec > 0 {
                        Text(BridgeFormatters.callDuration(seconds: rec.durationSec))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                SimHaptics.tap(.light)
                router.openSmsConversation(address: rec.number, title: resolvedName)
            } label: {
                Label("SMS", systemImage: "message.fill")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                CallKitManager.shared.startOutgoingCall(
                    number: rec.number,
                    contactName: resolvedName,
                    simSlot: bridge.validatedSimSlot(selectedSimSlot)
                )
            } label: {
                Label("Ara", systemImage: "phone.fill")
            }
            Button {
                router.openSmsConversation(address: rec.number, title: resolvedName)
            } label: {
                Label("SMS Gönder", systemImage: "message.fill")
            }
            Button {
                UIPasteboard.general.string = rec.number
            } label: {
                Label("Numarayı Kopyala", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private var contactsBody: some View {
        if !contacts.authorized {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Rehber İzni Gerekli")
                    .font(.headline)
                Text("iPhone rehberindeki kişileri aramak, mesajlaşmak ve arayan adlarını görmek için izin verin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if contacts.authorizationStatus == .denied || contacts.authorizationStatus == .restricted {
                    Button("iOS Ayarlarından İzin Ver") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Rehbere İzin Ver") {
                        contacts.requestAccessAndLoad()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        } else if filteredContacts.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "person.2.slash")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(search.isEmpty ? "Kişi Bulunamadı" : "Eşleşen Kişi Yok")
                    .font(.headline)
                Spacer()
            }
        } else {
            List(filteredContacts) { c in
                if c.numbers.count == 1, let singleNumber = c.numbers.first {
                    HStack(spacing: 12) {
                        Button {
                            SimHaptics.tap(.medium)
                            CallKitManager.shared.startOutgoingCall(
                                number: singleNumber,
                                contactName: c.name,
                                simSlot: bridge.validatedSimSlot(selectedSimSlot)
                            )
                        } label: {
                            HStack(spacing: 12) {
                                AvatarCircle(title: c.name, size: 38, tint: .green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(singleNumber)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            SimHaptics.tap(.light)
                            router.openSmsConversation(address: singleNumber, title: c.name)
                        } label: {
                            Image(systemName: "message.fill")
                                .foregroundStyle(.blue)
                                .padding(8)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button {
                            CallKitManager.shared.startOutgoingCall(
                                number: singleNumber,
                                contactName: c.name,
                                simSlot: bridge.validatedSimSlot(selectedSimSlot)
                            )
                        } label: {
                            Label("Ara", systemImage: "phone.fill")
                        }
                        Button {
                            router.openSmsConversation(address: singleNumber, title: c.name)
                        } label: {
                            Label("SMS Gönder", systemImage: "message.fill")
                        }
                        Button {
                            UIPasteboard.general.string = singleNumber
                        } label: {
                            Label("Numarayı Kopyala", systemImage: "doc.on.doc")
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            AvatarCircle(title: c.name, size: 34, tint: .green)
                            Text(c.name)
                                .font(.headline)
                        }
                        ForEach(c.numbers, id: \.self) { num in
                            HStack {
                                Button {
                                    SimHaptics.tap(.medium)
                                    CallKitManager.shared.startOutgoingCall(
                                        number: num,
                                        contactName: c.name,
                                        simSlot: bridge.validatedSimSlot(selectedSimSlot)
                                    )
                                } label: {
                                    HStack {
                                        Image(systemName: "phone.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                        Text(num)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    SimHaptics.tap(.light)
                                    router.openSmsConversation(address: num, title: c.name)
                                } label: {
                                    Image(systemName: "message.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 6)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyRecentsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: recentsFilter == 1 ? "phone.down" : "clock")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(
                !search.isEmpty ? "Arama Kaydı Bulunamadı"
                    : (!bridge.isPaired ? "Önce Android ile Eşleştirin"
                        : (recentsFilter == 1 ? "Cevapsız Arama Yok" : "Henüz Arama Kaydı Yok"))
            )
            .font(.headline)
            if bridge.isPaired && bridge.recentCalls.isEmpty {
                Button("Kayıtları Yenile") {
                    bridge.sendCommand(BridgeWsMessage(type: "sync_request"))
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding()
    }

    private var filteredRecents: [RecentCallDto] {
        let base = recentsFilter == 1
            ? bridge.recentCalls.filter { $0.type == "missed" }
            : bridge.recentCalls
        guard !search.isEmpty else { return base }
        return base.filter {
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

    private func callTypeLabel(_ type: String) -> String {
        switch type {
        case "outgoing": return "Giden arama"
        case "missed": return "Cevapsız"
        default: return "Gelen arama"
        }
    }
}
