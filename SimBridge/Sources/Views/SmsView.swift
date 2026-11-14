import SwiftUI
import UIKit

struct SmsThreadSummary: Identifiable {
    let key: String
    let address: String
    let displayName: String
    let latestBody: String
    let latestTimestampMs: Int64
    let latestIsOutgoing: Bool
    let latestSimSlot: Int
    let latestOtpCode: String?
    let unreadCount: Int
    let hasFailedPending: Bool
    let messages: [SmsMessageDto]

    var id: String { key }
}

private enum ChatItemKind {
    case persisted(SmsMessageDto)
    case pending(PendingSmsMessage)

    var timestampMs: Int64 {
        switch self {
        case .persisted(let m): return m.timestampMs
        case .pending(let p): return p.timestampMs
        }
    }

    var uniqueId: String {
        switch self {
        case .persisted(let m): return "p_\(m.id)"
        case .pending(let p): return "q_\(p.id)"
        }
    }
}

private struct ChatDaySection: Identifiable {
    let dayStart: Date
    let headerTitle: String
    let items: [ChatItemKind]

    var id: Date { dayStart }
}

struct SmsView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @ObservedObject private var router = AppRouter.shared
    @AppStorage("simbridge.preferredSimSlot") private var selectedSimSlot: Int = 0

    @State private var searchText: String = ""
    @State private var showingCompose: Bool = false
    @State private var copiedOtpBanner: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                ConnectionStatusPill()

                if threads.isEmpty {
                    emptyThreadsView
                } else {
                    List(threads) { thread in
                        NavigationLink {
                            SmsConversationView(address: thread.address, title: thread.displayName)
                        } label: {
                            threadRow(thread)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                SimHaptics.tap(.medium)
                                CallKitManager.shared.startOutgoingCall(
                                    number: thread.address,
                                    contactName: thread.displayName == thread.address ? nil : thread.displayName,
                                    simSlot: bridge.validatedSimSlot(selectedSimSlot)
                                )
                            } label: {
                                Label("Ara", systemImage: "phone.fill")
                            }
                            .tint(.green)
                        }
                        .contextMenu {
                            Button {
                                router.openSmsConversation(address: thread.address, title: thread.displayName)
                            } label: {
                                Label("Sohbeti Aç", systemImage: "message")
                            }
                            Button {
                                CallKitManager.shared.startOutgoingCall(
                                    number: thread.address,
                                    contactName: thread.displayName == thread.address ? nil : thread.displayName,
                                    simSlot: bridge.validatedSimSlot(selectedSimSlot)
                                )
                            } label: {
                                Label("Ara", systemImage: "phone.fill")
                            }
                            if let otp = thread.latestOtpCode, !otp.isEmpty {
                                Button {
                                    UIPasteboard.general.string = otp
                                    copiedOtpBanner = otp
                                } label: {
                                    Label("OTP Kopyala (\(otp))", systemImage: "doc.on.doc")
                                }
                            }
                            Button {
                                UIPasteboard.general.string = thread.address
                            } label: {
                                Label("Numarayı Kopyala", systemImage: "phone.badge.plus")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        bridge.sendCommand(BridgeWsMessage(type: "sync_request"))
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Kişi, numara veya mesaj içeriği ara")
            .navigationTitle("Mesajlar")
            .navigationDestination(
                isPresented: Binding(
                    get: { router.smsTargetToOpen != nil },
                    set: { if !$0 { router.smsTargetToOpen = nil } }
                )
            ) {
                if let target = router.smsTargetToOpen {
                    SmsConversationView(address: target.address, title: target.title)
                }
            }
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
                        SimHaptics.tap(.light)
                        showingCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingCompose) {
                SmsComposeSheet(initialSimSlot: bridge.validatedSimSlot(selectedSimSlot)) { sentAddr, sentTitle in
                    showingCompose = false
                    router.openSmsConversation(address: sentAddr, title: sentTitle)
                }
            }
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: SmsThreadSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                AvatarCircle(
                    title: thread.displayName,
                    size: 44,
                    tint: thread.unreadCount > 0 ? .blue : .secondary
                )
                if thread.unreadCount > 0 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(thread.displayName)
                        .font(thread.unreadCount > 0 ? .headline.weight(.bold) : .headline.weight(.medium))
                        .lineLimit(1)
                    if bridge.availableSims.count > 1 {
                        Text("SIM \(thread.latestSimSlot + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(BridgeFormatters.threadTimestamp(ms: thread.latestTimestampMs))
                        .font(.caption)
                        .foregroundStyle(thread.unreadCount > 0 ? .blue : .secondary)
                }

                if thread.displayName != thread.address {
                    Text(thread.address)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    if thread.hasFailedPending {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if thread.latestIsOutgoing {
                        Text("Siz:")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(thread.latestBody)
                        .font(.subheadline)
                        .foregroundStyle(thread.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(2)
                }

                if let otp = thread.latestOtpCode, !otp.isEmpty {
                    Button {
                        SimHaptics.notify(.success)
                        UIPasteboard.general.string = otp
                        copiedOtpBanner = otp
                    } label: {
                        Label("Kodu Kopyala: \(otp)", systemImage: "doc.on.doc")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var emptyThreadsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "message")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(
                !searchText.isEmpty ? "Eşleşen Mesaj Bulunamadı"
                    : (!bridge.isPaired ? "Önce Android ile Eşleştirin" : "Henüz SMS Yok")
            )
            .font(.headline)
            if bridge.isPaired && bridge.smsMessages.isEmpty {
                Button("Mesajları Yenile") {
                    bridge.sendCommand(BridgeWsMessage(type: "sync_request"))
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding()
    }

    private var threads: [SmsThreadSummary] {
        var groupedMsgs: [String: [SmsMessageDto]] = [:]
        for msg in bridge.smsMessages {
            let norm = ContactsHelper.normalizeSuffix(msg.address)
            let key = norm.isEmpty ? msg.address : norm
            groupedMsgs[key, default: []].append(msg)
        }

        var groupedPending: [String: [PendingSmsMessage]] = [:]
        for p in bridge.pendingSms {
            let norm = ContactsHelper.normalizeSuffix(p.address)
            let key = norm.isEmpty ? p.address : norm
            groupedPending[key, default: []].append(p)
        }

        let allKeys = Set(groupedMsgs.keys).union(groupedPending.keys)
        var out: [SmsThreadSummary] = allKeys.compactMap { key in
            let sortedMsgs = (groupedMsgs[key] ?? []).sorted { $0.timestampMs < $1.timestampMs }
            let sortedPending = (groupedPending[key] ?? []).sorted { $0.timestampMs < $1.timestampMs }

            let latestMsg = sortedMsgs.last
            let latestPend = sortedPending.last

            let latestAddress: String
            let latestBody: String
            let latestTs: Int64
            let latestOut: Bool
            let latestSim: Int
            let latestContactName: String?
            let latestOtp: String?

            if let p = latestPend, p.timestampMs >= (latestMsg?.timestampMs ?? 0) {
                latestAddress = latestMsg?.address ?? p.address
                latestBody = p.body
                latestTs = p.timestampMs
                latestOut = true
                latestSim = p.simSlot
                latestContactName = latestMsg?.contactName
                latestOtp = latestMsg?.otpCode
            } else if let m = latestMsg {
                latestAddress = m.address
                latestBody = m.body
                latestTs = m.timestampMs
                latestOut = m.isOutgoing
                latestSim = m.simSlot
                latestContactName = m.contactName
                latestOtp = m.otpCode
            } else {
                return nil
            }

            let name = contacts.resolveName(for: latestAddress) ?? latestContactName ?? latestAddress
            let unread = sortedMsgs.filter { !$0.isOutgoing && !$0.isRead }.count
            let hasFailed = sortedPending.contains {
                if case .failed = $0.status { return true }
                return false
            }

            return SmsThreadSummary(
                key: key,
                address: latestAddress,
                displayName: name,
                latestBody: latestBody,
                latestTimestampMs: latestTs,
                latestIsOutgoing: latestOut,
                latestSimSlot: latestSim,
                latestOtpCode: latestOtp,
                unreadCount: unread,
                hasFailedPending: hasFailed,
                messages: sortedMsgs
            )
        }

        out.sort { $0.latestTimestampMs > $1.latestTimestampMs }
        guard !searchText.isEmpty else { return out }
        return out.filter { thread in
            thread.displayName.localizedCaseInsensitiveContains(searchText) ||
            thread.address.localizedCaseInsensitiveContains(searchText) ||
            thread.latestBody.localizedCaseInsensitiveContains(searchText) ||
            thread.messages.contains { $0.body.localizedCaseInsensitiveContains(searchText) }
        }
    }
}

struct SmsConversationView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @AppStorage("simbridge.preferredSimSlot") private var preferredSimSlot: Int = 0

    let address: String
    let title: String

    @State private var draft: String = ""
    @State private var selectedSim: Int = 0
    @State private var didInitSim = false
    @State private var inspectedMessage: SmsMessageDto?
    @State private var copiedToast: String?

    private var resolvedTitle: String {
        if let name = contacts.resolveName(for: address), !name.isEmpty {
            return name
        }
        return title
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(daySections) { section in
                            Text(section.headerTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(Capsule())
                                .padding(.top, 6)

                            ForEach(section.items, id: \.uniqueId) { item in
                                switch item {
                                case .persisted(let m):
                                    persistedBubble(m)
                                        .id(item.uniqueId)
                                case .pending(let p):
                                    pendingBubble(p)
                                        .id(item.uniqueId)
                                }
                            }
                        }

                        Color.clear
                            .frame(height: 2)
                            .id("chat_bottom_anchor")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    if !didInitSim {
                        selectedSim = bridge.validatedSimSlot(preferredSimSlot)
                        didInitSim = true
                    }
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat_bottom_anchor", anchor: .bottom)
                    }
                }
                .onChange(of: totalItemCount) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("chat_bottom_anchor", anchor: .bottom)
                    }
                }
            }

            Divider()

            VStack(spacing: 4) {
                HStack(alignment: .bottom, spacing: 8) {
                    if bridge.availableSims.count > 1 {
                        Menu {
                            ForEach(bridge.availableSims) { sim in
                                Button {
                                    selectedSim = sim.simSlot
                                } label: {
                                    Text("SIM \(sim.simSlot + 1) • \(sim.carrierName)")
                                }
                            }
                        } label: {
                            Text("SIM \(selectedSim + 1)")
                                .font(.caption.bold())
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                    }

                    TextField("SMS yaz...", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)

                    Button {
                        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !body.isEmpty else { return }
                        SimHaptics.tap(.medium)
                        draft = ""
                        bridge.sendSms(address: address, body: body, simSlot: selectedSim)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !bridge.isConnected)
                }

                if draft.count >= 100 {
                    let segments = max(1, (draft.count + 152) / 153)
                    HStack {
                        Spacer()
                        Text("\(draft.count) karakter • \(segments) SMS")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(resolvedTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if resolvedTitle != address {
                        Text(address)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    SimHaptics.tap(.medium)
                    CallKitManager.shared.startOutgoingCall(
                        number: address,
                        contactName: resolvedTitle == address ? nil : resolvedTitle,
                        simSlot: selectedSim
                    )
                } label: {
                    Image(systemName: "phone.fill")
                }
                .disabled(!bridge.isPaired)
            }
        }
        .overlay(alignment: .top) {
            if let copiedToast {
                Text(copiedToast)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            self.copiedToast = nil
                        }
                    }
            }
        }
        .sheet(item: $inspectedMessage) { msg in
            SmsMessageDetailSheet(
                message: msg,
                displayName: resolvedTitle,
                carrierName: bridge.availableSims.first(where: { $0.simSlot == msg.simSlot })?.carrierName
            )
        }
    }

    @ViewBuilder
    private func persistedBubble(_ m: SmsMessageDto) -> some View {
        HStack {
            if m.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: m.isOutgoing ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.body)
                        .font(.body)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        if bridge.availableSims.count > 1 {
                            Text("SIM \(m.simSlot + 1)")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(BridgeFormatters.shortTime(ms: m.timestampMs))
                            .font(.caption2.monospacedDigit())
                        if m.isOutgoing {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(m.isOutgoing ? Color.white.opacity(0.82) : Color.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(m.isOutgoing ? Color.blue : Color(.secondarySystemBackground))
                .foregroundStyle(m.isOutgoing ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = m.body
                        copiedToast = "Mesaj kopyalandı"
                    } label: {
                        Label("Mesajı Kopyala", systemImage: "doc.on.doc")
                    }
                    if let otp = m.otpCode, !otp.isEmpty {
                        Button {
                            UIPasteboard.general.string = otp
                            copiedToast = "OTP Kopyalandı: \(otp)"
                        } label: {
                            Label("Kodu Kopyala (\(otp))", systemImage: "number")
                        }
                    }
                    Button {
                        inspectedMessage = m
                    } label: {
                        Label("Mesaj Detayları", systemImage: "info.circle")
                    }
                }
                .onTapGesture {
                    inspectedMessage = m
                }

                if let otp = m.otpCode, !otp.isEmpty {
                    Button {
                        SimHaptics.notify(.success)
                        UIPasteboard.general.string = otp
                        copiedToast = "OTP Kopyalandı: \(otp)"
                    } label: {
                        Label("OTP Kopyala: \(otp)", systemImage: "doc.on.doc")
                            .font(.caption2.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
                }
            }

            if !m.isOutgoing { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private func pendingBubble(_ p: PendingSmsMessage) -> some View {
        let isFailed: Bool = {
            if case .failed = p.status { return true }
            return false
        }()

        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.body)
                        .font(.body)
                    HStack(spacing: 6) {
                        if bridge.availableSims.count > 1 {
                            Text("SIM \(p.simSlot + 1)")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(BridgeFormatters.shortTime(ms: p.timestampMs))
                            .font(.caption2.monospacedDigit())
                        Text("• \(p.status.label)")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(Color.white.opacity(0.88))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isFailed ? Color.red.opacity(0.85) : Color.blue.opacity(0.75))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if case .failed(let err) = p.status {
                    HStack(spacing: 8) {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                        Button("Tekrar Dene") {
                            SimHaptics.tap(.medium)
                            bridge.retryPendingSms(id: p.id)
                        }
                        .font(.caption2.bold())
                        Button("Sil") {
                            bridge.dismissPendingSms(id: p.id)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var messages: [SmsMessageDto] {
        let key = ContactsHelper.normalizeSuffix(address)
        return bridge.smsMessages
            .filter {
                let mKey = ContactsHelper.normalizeSuffix($0.address)
                return (!key.isEmpty && mKey == key) || $0.address == address
            }
            .sorted { $0.timestampMs < $1.timestampMs }
    }

    private var pendingInThread: [PendingSmsMessage] {
        let key = ContactsHelper.normalizeSuffix(address)
        return bridge.pendingSms
            .filter {
                let pKey = ContactsHelper.normalizeSuffix($0.address)
                return (!key.isEmpty && pKey == key) || $0.address == address
            }
            .sorted { $0.timestampMs < $1.timestampMs }
    }

    private var totalItemCount: Int {
        messages.count + pendingInThread.count
    }

    private var daySections: [ChatDaySection] {
        let combined: [ChatItemKind] = (messages.map { ChatItemKind.persisted($0) } + pendingInThread.map { ChatItemKind.pending($0) })
            .sorted { $0.timestampMs < $1.timestampMs }

        var sections: [ChatDaySection] = []
        var currentDay: Date?
        var currentItems: [ChatItemKind] = []

        for item in combined {
            let day = BridgeFormatters.dayBucket(ms: item.timestampMs)
            if currentDay == day {
                currentItems.append(item)
            } else {
                if let prevDay = currentDay, !currentItems.isEmpty {
                    sections.append(ChatDaySection(
                        dayStart: prevDay,
                        headerTitle: BridgeFormatters.chatDayHeader(ms: currentItems[0].timestampMs),
                        items: currentItems
                    ))
                }
                currentDay = day
                currentItems = [item]
            }
        }
        if let prevDay = currentDay, !currentItems.isEmpty {
            sections.append(ChatDaySection(
                dayStart: prevDay,
                headerTitle: BridgeFormatters.chatDayHeader(ms: currentItems[0].timestampMs),
                items: currentItems
            ))
        }
        return sections
    }
}

struct SmsMessageDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: SmsMessageDto
    let displayName: String
    let carrierName: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Zaman & Yön") {
                    LabeledContent("Tam Tarih", value: BridgeFormatters.fullDateTime(ms: message.timestampMs))
                    LabeledContent("Yön", value: message.isOutgoing ? "Giden SMS" : "Gelen SMS")
                    LabeledContent("Durum", value: message.isOutgoing ? "Gönderildi" : (message.isRead ? "Okundu" : "Okunmadı"))
                }

                Section("Taraf & SIM") {
                    if displayName != message.address {
                        LabeledContent("Kişi", value: displayName)
                    }
                    LabeledContent("Numara", value: message.address)
                    LabeledContent(
                        "SIM Yuvası",
                        value: carrierName != nil ? "SIM \(message.simSlot + 1) • \(carrierName!)" : "SIM \(message.simSlot + 1)"
                    )
                }

                if let otp = message.otpCode, !otp.isEmpty {
                    Section("Tek Kullanımlık Kod (OTP)") {
                        HStack {
                            Text(otp)
                                .font(.title3.monospaced().bold())
                            Spacer()
                            Button("Kopyala") {
                                SimHaptics.notify(.success)
                                UIPasteboard.general.string = otp
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                }

                Section("Mesaj İçeriği") {
                    Text(message.body)
                        .textSelection(.enabled)
                    Button("Tüm Metni Kopyala") {
                        UIPasteboard.general.string = message.body
                    }
                }
            }
            .navigationTitle("Mesaj Detayları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SmsComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared

    let initialSimSlot: Int
    let onSent: (String, String) -> Void

    @State private var recipientQuery: String = ""
    @State private var selectedContactName: String?
    @State private var messageBody: String = ""
    @State private var selectedSim: Int = 0
    @State private var didInitSim = false

    private var suggestions: [SimpleContact] {
        guard contacts.authorized, !recipientQuery.isEmpty, selectedContactName == nil else { return [] }
        return contacts.matchingContacts(for: recipientQuery, limit: 6)
    }

    var body: some View {
        NavigationStack {
            Form {
                if bridge.availableSims.count > 1 {
                    Section("Gönderen SIM") {
                        Picker("SIM Seç", selection: $selectedSim) {
                            ForEach(bridge.availableSims) { sim in
                                Text("SIM \(sim.simSlot + 1) • \(sim.carrierName)").tag(sim.simSlot)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Alıcı") {
                    TextField("Ad veya numara (+905...)", text: $recipientQuery)
                        .keyboardType(.phonePad)
                        .onChange(of: recipientQuery) { _ in
                            if let selectedContactName, !recipientQuery.isEmpty {
                                // Clear matched contact badge if user manually edits the number.
                                let dialable = BridgeFormatters.filterDialable(recipientQuery)
                                if dialable != recipientQuery {
                                    self.selectedContactName = nil
                                }
                            }
                        }
                    if let selectedContactName {
                        HStack {
                            Image(systemName: "person.fill").foregroundStyle(.green)
                            Text(selectedContactName).font(.subheadline.weight(.medium))
                            Spacer()
                            Button("Değiştir") {
                                self.selectedContactName = nil
                            }
                            .font(.caption)
                        }
                    }

                    ForEach(suggestions) { c in
                        ForEach(c.numbers, id: \.self) { num in
                            Button {
                                recipientQuery = num
                                selectedContactName = c.name
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(c.name).font(.subheadline.weight(.semibold))
                                        Text(num).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("Mesajınızı yazın...", text: $messageBody, axis: .vertical)
                        .lineLimit(4...8)
                } header: {
                    Text("Mesaj")
                } footer: {
                    if !messageBody.isEmpty {
                        let segments = max(1, (messageBody.count + 152) / 153)
                        Text("\(messageBody.count) karakter • \(segments) SMS")
                    }
                }
            }
            .navigationTitle("Yeni SMS")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !didInitSim {
                    selectedSim = bridge.validatedSimSlot(initialSimSlot)
                    didInitSim = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gönder") {
                        let cleanAddr = recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanBody = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanAddr.isEmpty, !cleanBody.isEmpty else { return }
                        SimHaptics.tap(.medium)
                        bridge.sendSms(address: cleanAddr, body: cleanBody, simSlot: selectedSim)
                        let resolved = selectedContactName ?? contacts.resolveName(for: cleanAddr) ?? cleanAddr
                        onSent(cleanAddr, resolved)
                    }
                    .disabled(
                        recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !bridge.isConnected
                    )
                }
            }
        }
    }
}
