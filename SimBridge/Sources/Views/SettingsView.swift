import SwiftUI

struct SettingsView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var contacts = ContactsHelper.shared
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Köprü Bağlantısı") {
                    LabeledContent("Durum", value: bridge.statusBanner)
                    if bridge.isPaired {
                        LabeledContent("Eşleşen Cihaz", value: bridge.pairingDeviceName)
                        Button("Şimdi Yeniden Bağlan") {
                            bridge.connectNow(force: true)
                        }
                    }
                    Button("QR Kod ile Eşleştir / Güncelle") {
                        showingScanner = true
                    }
                }

                if let st = bridge.deviceStatus {
                    Section("Android Gateway Sağlığı") {
                        LabeledContent("Cihaz", value: st.deviceName)
                        LabeledContent("Pil", value: "\(st.batteryPct)% \(st.isCharging ? "⚡" : "")")
                        LabeledContent("Priv-App Ses Yetkisi", value: st.isPrivileged ? "Aktif ✓" : "Eksik ✕")
                        LabeledContent("InCallService", value: st.inCallServiceBound ? "Bağlı ✓" : "Arama Bekleniyor")
                        LabeledContent("Yerel IP'ler", value: st.localIps.joined(separator: ", "))
                        LabeledContent("Ses TX/RX Paket", value: "\(st.udpTxPackets) / \(st.udpRxPackets)")
                        ForEach(st.sims) { sim in
                            LabeledContent("SIM \(sim.simSlot + 1)", value: sim.carrierName)
                        }
                    }
                }

                Section("Push Tokenları & İzinler") {
                    LabeledContent(
                        "VoIP PushKit",
                        value: VoipPushManager.shared.currentVoipTokenHex.isEmpty ? "Bekleniyor" : "Hazır ✓"
                    )
                    LabeledContent(
                        "SMS Alert APNs",
                        value: NotificationManager.shared.currentAlertTokenHex.isEmpty ? "İzin Bekliyor" : "Hazır ✓"
                    )
                    if !contacts.authorized {
                        Button("iPhone Rehberine İzin Ver") {
                            contacts.requestAccessAndLoad()
                        }
                    } else {
                        LabeledContent("Rehber", value: "\(contacts.contacts.count) kişi yüklendi ✓")
                    }
                }

                if bridge.isPaired {
                    Section {
                        Button("Eşleştirmeyi Kaldır", role: .destructive) {
                            bridge.unpair()
                        }
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .sheet(isPresented: $showingScanner) {
                QrScannerSheet { code in
                    bridge.applyQrPayload(code)
                }
            }
        }
    }
}
