import SwiftUI
import UIKit

struct DialerView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @State private var numberText: String = ""
    @State private var selectedSimSlot: Int = 0

    private let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ConnectionStatusPill()

                if let err = bridge.lastCallError {
                    Text(err)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.9))
                        .clipShape(Capsule())
                        .padding(.horizontal)
                }

                if let active = bridge.activeCalls.first {
                    ActiveCallCard(call: active)
                }

                if let sims = bridge.deviceStatus?.sims, sims.count > 1 {
                    Picker("SIM Seçimi", selection: $selectedSimSlot) {
                        ForEach(sims) { sim in
                            Text("SIM \(sim.simSlot + 1) • \(sim.carrierName)").tag(sim.simSlot)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                Spacer()

                VStack(spacing: 4) {
                    Text(numberText.isEmpty ? "Numara Girin" : numberText)
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(numberText.isEmpty ? .secondary : .primary)
                        .padding(.horizontal)

                    if let name = contacts.resolveName(for: numberText), !numberText.isEmpty {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
                .onLongPressGesture {
                    if let clip = UIPasteboard.general.string {
                        numberText = clip.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
                    }
                }

                Spacer()

                VStack(spacing: 14) {
                    ForEach(0..<keys.count, id: \.self) { row in
                        HStack(spacing: 22) {
                            ForEach(keys[row], id: \.0) { digit, sub in
                                Button {
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
                                    .frame(width: 76, height: 76)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                        if digit == "0" {
                                            if numberText.hasSuffix("0") { numberText.removeLast() }
                                            numberText.append("+")
                                        }
                                    }
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 36) {
                    Color.clear.frame(width: 64, height: 64)

                    Button {
                        guard !numberText.isEmpty else { return }
                        let name = contacts.resolveName(for: numberText)
                        CallKitManager.shared.startOutgoingCall(
                            number: numberText,
                            contactName: name,
                            simSlot: selectedSimSlot
                        )
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(
                                !bridge.isPaired || numberText.isEmpty
                                    ? Color.gray
                                    : (bridge.isConnected ? Color.green : Color.orange)
                            )
                            .clipShape(Circle())
                    }
                    .disabled(!bridge.isPaired || numberText.isEmpty)

                    Button {
                        if !numberText.isEmpty { numberText.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title2)
                            .frame(width: 64, height: 64)
                    }
                    .disabled(numberText.isEmpty)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                            numberText = ""
                        }
                    )
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .navigationTitle("Tuşlar")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ActiveCallCard: View {
    let call: CallStateDto
    @ObservedObject private var audio = AudioEngineManager.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(call.contactName ?? call.number)
                    .font(.headline)
                Text("SIM \(call.simSlot + 1) • \(call.state.uppercased()) • \(audio.routeDescription)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button {
                audio.setSpeakerEnabled(!audio.isSpeakerOn)
            } label: {
                Label(
                    audio.isSpeakerOn ? "Ahize" : "Hoparlör",
                    systemImage: audio.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2"
                )
                .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(audio.isSpeakerOn ? .blue : .secondary)

            Button(role: .destructive) {
                CallKitManager.shared.endCall(callId: call.callId)
            } label: {
                Label("Kapat", systemImage: "phone.down.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(12)
        .background(Color.green.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

struct ConnectionStatusPill: View {
    @ObservedObject private var bridge = BridgeClient.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(bridge.isConnected ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text(bridge.statusBanner)
                .font(.caption.weight(.medium))
            Spacer()
            if let st = bridge.deviceStatus {
                Text("🔋 \(st.batteryPct)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
        .padding(.horizontal)
    }
}
