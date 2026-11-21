import CoreLocation
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @ObservedObject private var audio = AudioEngineManager.shared
    @ObservedObject private var notifications = NotificationManager.shared
    @ObservedObject private var locationKeepAlive = LocationKeepAliveManager.shared
    @ObservedObject private var voipPush = VoipPushManager.shared

    @State private var showingScanner = false
    @State private var copiedAudioLog = false
    @State private var showFullLogs = false
    @State private var confirmUnpair = false

    private var appVersionLabel: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(ver) (\(build))"
    }

    private var backgroundRefreshLabel: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "Açık ✓"
        case .denied:
            return "Kapalı (Ayarlardan Açın)"
        case .restricted:
            return "Kısıtlı"
        @unknown default:
            return "Bilinmiyor"
        }
    }

    private var locationStatusLabel: String {
        if locationKeepAlive.mode == .apnsBatterySaver {
            return "Pil Dostu (APNs + Anlamlı Konum)"
        }
        if locationKeepAlive.isPausedForLowPower {
            return "Düşük Güç Nedeniyle Duraklatıldı"
        }
        switch locationKeepAlive.authorizationStatus {
        case .authorizedAlways:
            return "Her Zaman Aktif ✓ (Mavi Bar Yok)"
        case .authorizedWhenInUse:
            return "Kullanırken (Mavi Bar Çıkabilir)"
        case .notDetermined:
            return "İzin Bekleniyor"
        case .denied, .restricted:
            return "İzin Kapalı"
        @unknown default:
            return "İzin Bekleniyor"
        }
    }

    private var locationStatusColor: Color {
        if locationKeepAlive.mode == .apnsBatterySaver {
            return .green
        }
        if locationKeepAlive.isPausedForLowPower {
            return .orange
        }
        switch locationKeepAlive.authorizationStatus {
        case .authorizedAlways:
            return .green
        case .authorizedWhenInUse:
            return .orange
        case .denied, .restricted:
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Köprü Bağlantısı") {
                    LabeledContent("Durum", value: bridge.statusBanner)
                    if let rtt = bridge.pingLatencyMs, bridge.isConnected {
                        LabeledContent("Gecikme (Ping)", value: "\(rtt) ms")
                    }
                    if let lastSync = bridge.lastSyncAt {
                        LabeledContent("Son Senkronizasyon") {
                            Text(lastSync, style: .time)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if bridge.isPaired {
                        LabeledContent("Eşleşen Cihaz", value: bridge.pairingDeviceName)
                        Button {
                            SimHaptics.tap(.light)
                            bridge.connectNow(force: true, sweepSubnet: true)
                        } label: {
                            Label("Şimdi Yeniden Bağlan (LAN Taraması)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            SimHaptics.tap(.medium)
                            bridge.resetConnectionCleanly()
                        } label: {
                            Label("Bağlantıyı Sıfırla (Tam Yenileme)", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    Button {
                        showingScanner = true
                    } label: {
                        Label("QR Kod ile Eşleştir / Güncelle", systemImage: "qrcode.viewfinder")
                    }
                }

                if let st = bridge.deviceStatus {
                    Section("Android Gateway Sağlığı") {
                        LabeledContent("Cihaz", value: st.deviceName)
                        LabeledContent("Pil") {
                            Text("\(st.batteryPct)% \(st.isCharging ? "⚡" : "")")
                                .foregroundStyle(
                                    st.isCharging ? .green : (st.batteryPct <= 15 ? .red : (st.batteryPct <= 25 ? .orange : .secondary))
                                )
                        }
                        if st.powerSaveMode == true {
                            LabeledContent("Android Pil Tasarrufu") {
                                Label("Açık (Uyku etkileyebilir)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let apnsSummary = st.lastApnsSummary, !apnsSummary.isEmpty {
                            LabeledContent("Son APNs Push", value: apnsSummary)
                        }
                        LabeledContent("Priv-App Ses Yetkisi", value: st.isPrivileged ? "Aktif ✓" : "Eksik ✕")
                        LabeledContent("InCallService", value: st.inCallServiceBound ? "Bağlı ✓" : "Arama Bekleniyor")
                        LabeledContent("Ses Profili", value: st.audioProfile)
                        LabeledContent("Yerel IP'ler", value: st.localIps.joined(separator: ", "))
                        LabeledContent("Android Ses TX/RX/PLC", value: "\(st.udpTxPackets) / \(st.udpRxPackets) / \(st.plcFrames)")
                        ForEach(st.sims) { sim in
                            let valueText = (sim.phoneNumber?.isEmpty == false)
                                ? "\(sim.carrierName) (\(sim.phoneNumber!))"
                                : sim.carrierName
                            LabeledContent("SIM \(sim.simSlot + 1)", value: valueText)
                        }
                    }
                }

                Section("Push Tokenları & İzinler") {
                    LabeledContent(
                        "VoIP PushKit",
                        value: voipPush.currentVoipTokenHex.isEmpty ? "Bekleniyor" : "Hazır ✓"
                    )
                    LabeledContent(
                        "SMS Alert APNs",
                        value: notifications.currentAlertTokenHex.isEmpty ? "Bekleniyor" : "Hazır ✓"
                    )
                    if notifications.authorizationStatus == .denied {
                        Button("Bildirim İzni Kapalı — Ayarları Aç") {
                            openSystemSettings()
                        }
                        .foregroundStyle(.orange)
                    }

                    if contacts.authorized {
                        LabeledContent("Rehber", value: "\(contacts.contacts.count) kişi yüklendi ✓")
                    } else if contacts.authorizationStatus == .denied || contacts.authorizationStatus == .restricted {
                        Button("Rehber İzni Kapalı — Ayarları Aç") {
                            openSystemSettings()
                        }
                        .foregroundStyle(.orange)
                    } else {
                        Button("iPhone Rehberine İzin Ver") {
                            contacts.requestAccessAndLoad()
                        }
                    }
                }

                Section {
                    Picker("Arka Plan Modu", selection: $locationKeepAlive.mode) {
                        ForEach(BackgroundKeepAliveMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: locationKeepAlive.mode) { newMode in
                        if newMode == .continuousLan {
                            locationKeepAlive.promptIfNotDetermined()
                        }
                    }

                    if locationKeepAlive.mode == .continuousLan {
                        Toggle("Düşük Güç Modu'nda Hafif Moda Geç", isOn: $locationKeepAlive.autoPauseInLowPowerMode)
                    }

                    LabeledContent("iPhone Düşük Güç Modu") {
                        Text(locationKeepAlive.isLowPowerModeEnabled ? "Açık" : "Kapalı")
                            .foregroundStyle(locationKeepAlive.isLowPowerModeEnabled ? .orange : .secondary)
                    }

                    LabeledContent("Konum Keep-Alive") {
                        Text(locationStatusLabel)
                            .foregroundStyle(locationStatusColor)
                    }

                    if locationKeepAlive.mode == .continuousLan && locationKeepAlive.authorizationStatus != .authorizedAlways {
                        Button("Konum İznini 'Her Zaman' Yap (Mavi Barı Gizle)") {
                            locationKeepAlive.requestAlwaysPermission()
                        }
                        .foregroundStyle(.orange)
                    }

                    if let wakeAt = locationKeepAlive.lastBackgroundWakeAt {
                        LabeledContent("Son Arka Plan Uyanışı") {
                            HStack(spacing: 4) {
                                if let src = locationKeepAlive.lastBackgroundWakeSource, !src.isEmpty {
                                    Text(src)
                                    Text("•")
                                }
                                Text(wakeAt, style: .time)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Redmi Düşük Pil Uyarısı (≤%15)", isOn: $notifications.lowBatteryAlertEnabled)
                    LabeledContent("Arka Planda Yenile", value: backgroundRefreshLabel)
                    if UIApplication.shared.backgroundRefreshStatus == .denied {
                        Button("Arka Planda Yenilemeyi Aç") {
                            openSystemSettings()
                        }
                        .foregroundStyle(.orange)
                    }
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "com.simbridge.ios")
                    LabeledContent("Varsayılan Arama", value: "Ayarlar > Uygulamalar > Saptanmış > Arama")
                    LabeledContent("CallKit & Kişiler", value: "Aktif (Ara'ya basılı tut → SimBridge)")
                    LabeledContent("Siri & tel:// Bağlantıları", value: "Destekleniyor ✓")
                } header: {
                    Text("iOS Entegrasyon & Arka Plan")
                } footer: {
                    Text("Pil Dostu (APNs) minimum pil tüketir; gelen aramalar VoIP PushKit, SMS'ler APNs ile uyanır. 7/24 Aktif LAN sürekli konum güncellemesiyle yerel soketi canlı tutar ancak iPhone pil tüketimini artırır.")
                }

                Section("Ses & Hoparlör") {
                    LabeledContent("Aktif Ses Rotası", value: audio.routeDescription)
                    let m = audio.callAudioMetrics
                    if m.txPackets > 0 || m.rxPackets > 0 {
                        LabeledContent(
                            "iOS Ses TX/RX/PLC",
                            value: "\(m.txPackets) / \(m.rxPackets) / \(m.plcFrames)"
                        )
                    }
                    Toggle(
                        "Ses İşleme (Yankı Engelleme / AEC)",
                        isOn: Binding(
                            get: { audio.voiceProcessingEnabled },
                            set: { audio.setVoiceProcessingPreference($0) }
                        )
                    )
                    Button(copiedAudioLog ? "Ses Tanı Logu Kopyalandı ✓" : "Ses Tanı Logunu Kopyala") {
                        UIPasteboard.general.string = audio.copyableDiagnosticsText()
                        SimHaptics.notify(.success)
                        copiedAudioLog = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            copiedAudioLog = false
                        }
                    }
                    if !audio.diagnosticLines.isEmpty {
                        DisclosureGroup("Son Ses Tanı Logları", isExpanded: $showFullLogs) {
                            Text(audio.diagnosticLines.suffix(15).joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                if bridge.isPaired {
                    Section {
                        Button("Eşleştirmeyi Kaldır", role: .destructive) {
                            confirmUnpair = true
                        }
                    }
                }

                Section {
                    LabeledContent("Sürüm", value: appVersionLabel)
                }
            }
            .navigationTitle("Ayarlar")
            .onAppear {
                notifications.refreshAuthorizationStatus()
                contacts.refreshAuthorizationStatus()
                locationKeepAlive.refreshAuthorizationState()
            }
            .confirmationDialog(
                "Android eşleştirmesi kaldırılsın mı?",
                isPresented: $confirmUnpair,
                titleVisibility: .visible
            ) {
                Button("Eşleştirmeyi Kaldır", role: .destructive) {
                    bridge.unpair()
                }
                Button("İptal", role: .cancel) {}
            } message: {
                Text("Anahtar ve yerel önbellek temizlenir. Yeniden kullanmak için QR kod okutmanız gerekir.")
            }
            .sheet(isPresented: $showingScanner) {
                QrScannerSheet { code in
                    bridge.applyQrPayload(code)
                }
            }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
