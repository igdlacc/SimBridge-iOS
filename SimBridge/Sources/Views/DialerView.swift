import SwiftUI
import UIKit

struct DialerView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @ObservedObject private var router = AppRouter.shared
    @AppStorage("simbridge.preferredSimSlot") private var selectedSimSlot: Int = 0

    @State private var numberText: String = ""
    @State private var copiedBanner: Bool = false

    private let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    private var matchingContacts: [SimpleContact] {
        guard numberText.count >= 2, contacts.authorized else { return [] }
        return contacts.matchingContacts(for: numberText, limit: 3)
    }

    private var exactContactName: String? {
        guard !numberText.isEmpty else { return nil }
        return contacts.resolveName(for: numberText)
    }

    private var clipboardDialableNumber: String? {
        guard numberText.isEmpty, let clip = UIPasteboard.general.string else { return nil }
        let filtered = BridgeFormatters.filterDialable(clip)
        return filtered.count >= 3 ? filtered : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                ConnectionStatusPill()
                SimSelectorBar(selectedSimSlot: $selectedSimSlot)

                Spacer(minLength: 4)

                VStack(spacing: 6) {
                    Text(numberText.isEmpty ? "Numara Girin" : numberText)
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .foregroundStyle(numberText.isEmpty ? .secondary : .primary)
                        .padding(.horizontal)
                        .contextMenu {
                            if !numberText.isEmpty {
                                Button {
                                    UIPasteboard.general.string = numberText
                                    copiedBanner = true
                                } label: {
                                    Label("Numarayı Kopyala", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    numberText = ""
                                } label: {
                                    Label("Temizle", systemImage: "trash")
                                }
                            }
                            if let clip = UIPasteboard.general.string {
                                let filtered = BridgeFormatters.filterDialable(clip)
                                if !filtered.isEmpty {
                                    Button {
                                        numberText = filtered
                                    } label: {
                                        Label("Yapıştır (\(filtered))", systemImage: "doc.on.clipboard")
                                    }
                                }
                            }
                        }

                    if let name = exactContactName {
                        Text(name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    } else if let clipNum = clipboardDialableNumber {
                        Button {
                            SimHaptics.tap(.light)
                            numberText = clipNum
                        } label: {
                            Label("Panodan Yapıştır: \(clipNum)", systemImage: "doc.on.clipboard")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if !matchingContacts.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(matchingContacts) { c in
                                    if let num = c.numbers.first {
                                        Button {
                                            SimHaptics.tap(.light)
                                            numberText = BridgeFormatters.filterDialable(num)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(c.name).font(.caption.weight(.semibold))
                                                Text(num).font(.caption2).foregroundStyle(.secondary)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color(.secondarySystemBackground))
                                            .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    } else {
                        Text(" ")
                            .font(.subheadline)
                            .hidden()
                    }
                }

                Spacer(minLength: 4)

                VStack(spacing: 12) {
                    ForEach(0..<keys.count, id: \.self) { row in
                        HStack(spacing: 20) {
                            ForEach(keys[row], id: \.0) { digit, sub in
                                Button {
                                    SimHaptics.tap(.light)
                                    numberText.append(digit)
                                    if let active = bridge.activeCalls.first(where: { $0.state == "active" }) {
                                        CallKitManager.shared.sendDtmf(callId: active.callId, digits: digit)
                                    }
                                } label: {
                                    VStack(spacing: 1) {
                                        Text(digit)
                                            .font(.system(size: 28, weight: .regular))
                                        if !sub.isEmpty {
                                            Text(sub)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                                        if digit == "0" {
                                            SimHaptics.tap(.medium)
                                            if numberText.hasSuffix("0") { numberText.removeLast() }
                                            numberText.append("+")
                                        }
                                    }
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 32) {
                    if !numberText.isEmpty && bridge.isPaired {
                        Button {
                            SimHaptics.tap(.light)
                            router.openSmsConversation(address: numberText, title: exactContactName)
                        } label: {
                            Image(systemName: "message.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 60, height: 60)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("SMS Gönder")
                    } else {
                        Color.clear.frame(width: 60, height: 60)
                    }

                    Button {
                        guard !numberText.isEmpty else { return }
                        SimHaptics.tap(.medium)
                        let validSim = bridge.validatedSimSlot(selectedSimSlot)
                        CallKitManager.shared.startOutgoingCall(
                            number: numberText,
                            contactName: exactContactName,
                            simSlot: validSim
                        )
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(callButtonColor)
                            .clipShape(Circle())
                    }
                    .disabled(!bridge.isPaired || numberText.isEmpty)

                    Button {
                        SimHaptics.tap(.light)
                        if !numberText.isEmpty { numberText.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                    }
                    .disabled(numberText.isEmpty)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            SimHaptics.tap(.medium)
                            numberText = ""
                        }
                    )
                }
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .navigationTitle("Tuşlar")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if copiedBanner {
                    Text("Numara kopyalandı")
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 16)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                copiedBanner = false
                            }
                        }
                }
            }
        }
    }

    private var callButtonColor: Color {
        if !bridge.isPaired || numberText.isEmpty { return .gray }
        return bridge.isConnected ? .green : .orange
    }
}
