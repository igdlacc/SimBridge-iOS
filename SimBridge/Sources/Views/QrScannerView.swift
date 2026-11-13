import AVFoundation
import SwiftUI
import UIKit

struct QrScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manualJson: String = ""
    @State private var errorMsg: String?

    let onScanned: (String) -> Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CameraQrView { code in
                    if onScanned(code) {
                        dismiss()
                    } else {
                        errorMsg = "Geçersiz SimBridge QR kodu"
                    }
                }
                .frame(height: 290)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.green.opacity(0.6), lineWidth: 2))

                Text("Android cihazdaki SimBridge QR kodunu kameraya tutun veya JSON kodunu yapıştırın.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Eşleştirme JSON (opsiyonel)", text: $manualJson, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                if let errorMsg {
                    Text(errorMsg).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Button("Panodan Yapıştır") {
                        if let str = UIPasteboard.general.string {
                            manualJson = str
                            if onScanned(str) {
                                dismiss()
                            } else {
                                errorMsg = "Panodaki metin geçerli bir SimBridge QR JSON değil."
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Bağlan") {
                        if onScanned(manualJson) {
                            dismiss()
                        } else {
                            errorMsg = "Geçersiz eşleştirme JSON verisi."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Android Eşleştir")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}

struct CameraQrView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QrScannerVC {
        let vc = QrScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: QrScannerVC, context: Context) {}

    final class QrScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var didEmit = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didEmit,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            didEmit = true
            session.stopRunning()
            onCode?(value)
        }
    }
}
