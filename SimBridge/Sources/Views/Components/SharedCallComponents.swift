import SwiftUI
import UIKit

enum SimHaptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.impactOccurred()
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(type)
    }
}

struct AvatarCircle: View {
    let title: String
    var size: CGFloat = 42
    var tint: Color = .blue
    var imageData: Data? = nil

    var body: some View {
        if let imageData, let uiImg = UIImage(data: imageData) {
            Image(uiImage: uiImg)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: size, height: size)
                Text(BridgeFormatters.initials(for: title))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
    }
}

struct ConnectionStatusPill: View {
    @ObservedObject private var bridge = BridgeClient.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)

            Text(bridge.statusBanner)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            if bridge.isConnected, let rtt = bridge.pingLatencyMs {
                Text("\(rtt) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 4)

            if let st = bridge.deviceStatus {
                HStack(spacing: 3) {
                    Image(systemName: st.isCharging ? "battery.100.bolt" : "battery.75")
                        .font(.caption2)
                    Text("\(st.batteryPct)%")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            } else if bridge.isPaired && !bridge.isConnected {
                Button {
                    SimHaptics.tap(.light)
                    bridge.connectNow(force: true, sweepSubnet: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
        .padding(.horizontal)
    }

    private var dotColor: Color {
        if bridge.isConnected { return .green }
        if bridge.isPaired { return .orange }
        return .gray
    }
}

struct GlobalErrorBanner: View {
    @ObservedObject private var bridge = BridgeClient.shared

    var body: some View {
        if let err = bridge.lastCallError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(err)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.92))
            .clipShape(Capsule())
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct SimSelectorBar: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @Binding var selectedSimSlot: Int

    var body: some View {
        let sims = bridge.availableSims
        if sims.count > 1 {
            Picker("SIM Seçimi", selection: $selectedSimSlot) {
                ForEach(sims) { sim in
                    Text("SIM \(sim.simSlot + 1) • \(sim.carrierName)").tag(sim.simSlot)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .onAppear {
                let valid = bridge.validatedSimSlot(selectedSimSlot)
                if valid != selectedSimSlot { selectedSimSlot = valid }
            }
            .onChange(of: sims) { _ in
                let valid = bridge.validatedSimSlot(selectedSimSlot)
                if valid != selectedSimSlot { selectedSimSlot = valid }
            }
        }
    }
}

struct GlobalActiveCallBar: View {
    let call: CallStateDto
    @ObservedObject private var audio = AudioEngineManager.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @ObservedObject private var router = AppRouter.shared

    private var displayName: String {
        if let name = call.contactName, !name.isEmpty { return name }
        return contacts.resolveName(for: call.number) ?? call.number
    }

    private var isCallMuted: Bool {
        audio.isMuted || call.muted
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if isCallMuted {
                        Text("SESSİZ")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange)
                            .clipShape(Capsule())
                    }
                }

                TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                    HStack(spacing: 5) {
                        Text("SIM \(call.simSlot + 1)")
                            .font(.caption2.weight(.semibold))
                        Text("•")
                        Text(callStatusLabel(now: ctx.date))
                            .font(.caption2.monospacedDigit().weight(.medium))
                        Text("•")
                        Text(audio.routeDescription)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(stateColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                SimHaptics.tap(.light)
                router.activeCallSheetPresented = true
            }

            if call.state == "ringing" && call.direction == "incoming" {
                Button {
                    SimHaptics.tap(.medium)
                    CallKitManager.shared.answerCall(callId: call.callId)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.green)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    SimHaptics.tap(.medium)
                    CallKitManager.shared.endCall(callId: call.callId)
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    SimHaptics.tap(.light)
                    CallKitManager.shared.setMuted(callId: call.callId, muted: !isCallMuted)
                } label: {
                    Image(systemName: isCallMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCallMuted ? .white : .primary)
                        .frame(width: 36, height: 36)
                        .background(isCallMuted ? Color.orange : Color(.tertiarySystemFill))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCallMuted ? "Sesi Aç" : "Sessize Al")

                Button {
                    SimHaptics.tap(.light)
                    audio.setSpeakerEnabled(!audio.isSpeakerOn)
                } label: {
                    Image(systemName: audio.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(audio.isSpeakerOn ? .white : .primary)
                        .frame(width: 36, height: 36)
                        .background(audio.isSpeakerOn ? Color.blue : Color(.tertiarySystemFill))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(audio.isSpeakerOn ? "Ahizeye Geç" : "Hoparlörü Aç")

                Button {
                    SimHaptics.tap(.medium)
                    CallKitManager.shared.endCall(callId: call.callId)
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Aramayı Kapat")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(stateColor.opacity(0.13))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(stateColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private var stateColor: Color {
        switch call.state {
        case "holding": return .orange
        case "ringing", "dialing": return .blue
        default: return .green
        }
    }

    private func callStatusLabel(now: Date) -> String {
        switch call.state {
        case "active":
            let baseMs = call.connectedAtMs > 0 ? call.connectedAtMs : call.startedAtMs
            return BridgeFormatters.liveTimer(sinceMs: baseMs, now: now)
        case "ringing":
            return "Çalıyor..."
        case "dialing":
            return "Aranıyor..."
        case "holding":
            return "Beklemede"
        default:
            return call.state.capitalized
        }
    }
}

struct ActiveCallDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var audio = AudioEngineManager.shared
    @ObservedObject private var contacts = ContactsHelper.shared

    @State private var showDtmfPad = false
    @State private var dtmfInput = ""

    private let dtmfKeys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    var body: some View {
        NavigationStack {
            if let call = bridge.activeCalls.first {
                let name = (call.contactName?.isEmpty == false ? call.contactName : nil)
                    ?? contacts.resolveName(for: call.number)
                    ?? call.number
                let isMuted = audio.isMuted || call.muted
                let isHeld = call.onHold || call.state == "holding"
                let carrier = bridge.availableSims.first(where: { $0.simSlot == call.simSlot })?.carrierName

                VStack(spacing: 20) {
                    Spacer(minLength: 4)

                    VStack(spacing: 8) {
                        AvatarCircle(
                            title: name,
                            size: 72,
                            tint: isHeld ? .orange : .green,
                            imageData: contacts.thumbnailData(for: call.number)
                        )

                        Text(name)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)

                        if name != call.number {
                            Text(call.number)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                            let statusText: String = {
                                if isHeld { return "Beklemede" }
                                if call.state == "active" {
                                    let base = call.connectedAtMs > 0 ? call.connectedAtMs : call.startedAtMs
                                    return BridgeFormatters.liveTimer(sinceMs: base, now: ctx.date)
                                }
                                return call.state == "ringing" ? "Gelen Arama..." : "Aranıyor..."
                            }()

                            Text(statusText)
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(isHeld ? .orange : .green)
                        }

                        HStack(spacing: 8) {
                            Label(
                                carrier != nil ? "SIM \(call.simSlot + 1) • \(carrier!)" : "SIM \(call.simSlot + 1)",
                                systemImage: "simcard"
                            )
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Capsule())

                            Label(audio.routeDescription, systemImage: routeIconName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                    }

                    if showDtmfPad {
                        VStack(spacing: 10) {
                            if !dtmfInput.isEmpty {
                                Text(dtmfInput)
                                    .font(.title3.monospaced().weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal)
                            }
                            ForEach(0..<dtmfKeys.count, id: \.self) { row in
                                HStack(spacing: 18) {
                                    ForEach(dtmfKeys[row], id: \.0) { digit, sub in
                                        Button {
                                            SimHaptics.tap(.light)
                                            dtmfInput.append(digit)
                                            CallKitManager.shared.sendDtmf(callId: call.callId, digits: digit)
                                        } label: {
                                            VStack(spacing: 0) {
                                                Text(digit).font(.title3.weight(.medium))
                                                if !sub.isEmpty {
                                                    Text(sub).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                                                }
                                            }
                                            .frame(width: 62, height: 62)
                                            .background(Color(.secondarySystemBackground))
                                            .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        let m = audio.callAudioMetrics
                        if m.txPackets > 0 || m.rxPackets > 0 {
                            HStack(spacing: 12) {
                                Text("TX \(m.txPackets)")
                                Text("RX \(m.rxPackets)")
                                if m.plcFrames > 0 {
                                    Text("PLC \(m.plcFrames)")
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Capsule())
                        }
                    }

                    Spacer(minLength: 8)

                    if call.state == "ringing" && call.direction == "incoming" {
                        HStack(spacing: 48) {
                            callActionCircle(
                                icon: "phone.down.fill",
                                title: "Reddet",
                                active: true,
                                activeColor: .red
                            ) {
                                SimHaptics.tap(.heavy)
                                CallKitManager.shared.endCall(callId: call.callId)
                                dismiss()
                            }

                            callActionCircle(
                                icon: "phone.fill",
                                title: "Yanıtla",
                                active: true,
                                activeColor: .green
                            ) {
                                SimHaptics.tap(.heavy)
                                CallKitManager.shared.answerCall(callId: call.callId)
                            }
                        }
                    } else {
                        VStack(spacing: 18) {
                            HStack(spacing: 20) {
                                callActionCircle(
                                    icon: isMuted ? "mic.slash.fill" : "mic.fill",
                                    title: isMuted ? "Sesi Aç" : "Sessiz",
                                    active: isMuted,
                                    activeColor: .orange
                                ) {
                                    SimHaptics.tap(.light)
                                    CallKitManager.shared.setMuted(callId: call.callId, muted: !isMuted)
                                }

                                callActionCircle(
                                    icon: "circle.grid.3x3.fill",
                                    title: "Tuşlar",
                                    active: showDtmfPad,
                                    activeColor: .blue
                                ) {
                                    SimHaptics.tap(.light)
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showDtmfPad.toggle()
                                    }
                                }

                                callActionCircle(
                                    icon: routeIconName,
                                    title: "Hoparlör",
                                    active: audio.isSpeakerOn,
                                    activeColor: .blue
                                ) {
                                    SimHaptics.tap(.light)
                                    audio.setSpeakerEnabled(!audio.isSpeakerOn)
                                }

                                callActionCircle(
                                    icon: isHeld ? "play.fill" : "pause.fill",
                                    title: isHeld ? "Devam Et" : "Beklet",
                                    active: isHeld,
                                    activeColor: .orange
                                ) {
                                    SimHaptics.tap(.light)
                                    CallKitManager.shared.setHeld(callId: call.callId, held: !isHeld)
                                }
                            }

                            Button {
                                SimHaptics.tap(.heavy)
                                CallKitManager.shared.endCall(callId: call.callId)
                                dismiss()
                            } label: {
                                Label("Aramayı Bitir", systemImage: "phone.down.fill")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: 240)
                                    .padding(.vertical, 14)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    Spacer(minLength: 10)
                }
                .padding()
                .navigationTitle("Aktif Arama")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Kapat") { dismiss() }
                    }
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
    }

    private var routeIconName: String {
        if audio.routeDescription.hasPrefix("Bluetooth") { return "headphones" }
        if audio.isSpeakerOn { return "speaker.wave.3.fill" }
        return "speaker.wave.2.fill"
    }

    private func callActionCircle(
        icon: String,
        title: String,
        active: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(active ? .white : .primary)
                    .frame(width: 58, height: 58)
                    .background(active ? activeColor : Color(.secondarySystemBackground))
                    .clipShape(Circle())
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
