import SwiftUI
import UIKit

struct SmsThreadSummary: Identifiable {
    let key: String
    let address: String
    let displayName: String
    let latest: SmsMessageDto
    let messages: [SmsMessageDto]

    var id: String { key }
}

struct SmsView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @State private var searchText: String = ""
    @State private var showingCompose: Bool = false
    @State private var newAddress: String = ""
    @State private var newBody: String = ""
    @State private var copiedOtpBanner: String?

    var body: some View {
        NavigationStack {
            List(threads) { thread in
                NavigationLink {
                    SmsConversationView(address: thread.address, title: thread.displayName)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(thread.displayName)
                                .font(.headline)
                            Spacer()
                            Text(formatTime(thread.latest.timestampMs))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(thread.latest.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if let otp = thread.latest.otpCode, !otp.isEmpty {
                            Button {
                                UIPasteboard.general.string = otp
                                copiedOtpBanner = otp
                            } label: {
                                Label("Kodu Kopyala: \(otp)", systemImage: "doc.on.doc")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Mesajlarda ara")
            .navigationTitle("Mesajlar")
            .overlay(alignment: .bottom) {
                if let copiedOtpBanner {
                    Text("Kopyalandı: \(copiedOtpBanner)")
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 10)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.copiedOtpBanner = nil
                            }
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingCompose) {
                NavigationStack {
                    Form {
                        TextField("Alıcı numara (+905...)", text: $newAddress)
                            .keyboardType(.phonePad)
                        TextField("Mesaj", text: $newBody, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .navigationTitle("Yeni SMS")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("İptal") { showingCompose = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Gönder") {
                                bridge.sendCommand(
                                    BridgeWsMessage(
                                        type: "send_sms",
                                        simSlot: 0,
                                        clientMsgId: UUID().uuidString,
                                        address: newAddress,
                                        body: newBody
                                    )
                                )
                                newAddress = ""
                                newBody = ""
                                showingCompose = false
                            }
                            .disabled(newAddress.isEmpty || newBody.isEmpty || !bridge.isConnected)
                        }
                    }
                }
            }
        }
    }

    private var threads: [SmsThreadSummary] {
        var grouped: [String: [SmsMessageDto]] = [:]
        for msg in bridge.smsMessages {
            let norm = ContactsHelper.normalizeSuffix(msg.address)
            let key = norm.isEmpty ? msg.address : norm
            grouped[key, default: []].append(msg)
        }
        var out: [SmsThreadSummary] = grouped.compactMap { key, list in
            let sorted = list.sorted { $0.timestampMs < $1.timestampMs }
            guard let latest = sorted.last else { return nil }
            let name = contacts.resolveName(for: latest.address) ?? latest.contactName ?? latest.address
            return SmsThreadSummary(key: key, address: latest.address, displayName: name, latest: latest, messages: sorted)
        }
        out.sort { $0.latest.timestampMs > $1.latest.timestampMs }
        guard !searchText.isEmpty else { return out }
        return out.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.latest.body.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func formatTime(_ ms: Int64) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "tr_TR")
        df.doesRelativeDateFormatting = true
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}

struct SmsConversationView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    let address: String
    let title: String

    @State private var draft: String = ""
    @State private var selectedSim: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { m in
                            HStack {
                                if m.isOutgoing { Spacer(minLength: 48) }
                                VStack(alignment: m.isOutgoing ? .trailing : .leading, spacing: 4) {
                                    Text(m.body)
                                        .padding(10)
                                        .background(m.isOutgoing ? Color.blue : Color(.secondarySystemBackground))
                                        .foregroundStyle(m.isOutgoing ? .white : .primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    if let otp = m.otpCode, !otp.isEmpty {
                                        Button("OTP Kopyala: \(otp)") {
                                            UIPasteboard.general.string = otp
                                        }
                                        .font(.caption2.bold())
                                        .buttonStyle(.bordered)
                                    }
                                }
                                if !m.isOutgoing { Spacer(minLength: 48) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                if let sims = bridge.deviceStatus?.sims, sims.count > 1 {
                    Menu("S\(selectedSim + 1)") {
                        ForEach(sims) { sim in
                            Button("SIM \(sim.simSlot + 1): \(sim.carrierName)") {
                                selectedSim = sim.simSlot
                            }
                        }
                    }
                    .font(.caption.bold())
                }
                TextField("SMS yaz...", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button {
                    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { return }
                    draft = ""
                    bridge.sendCommand(
                        BridgeWsMessage(
                            type: "send_sms",
                            simSlot: selectedSim,
                            clientMsgId: UUID().uuidString,
                            address: address,
                            body: body
                        )
                    )
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !bridge.isConnected)
            }
            .padding(10)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var messages: [SmsMessageDto] {
        let key = ContactsHelper.normalizeSuffix(address)
        return bridge.smsMessages
            .filter { ContactsHelper.normalizeSuffix($0.address) == key || $0.address == address }
            .sorted { $0.timestampMs < $1.timestampMs }
    }
}
