import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraManager: BlinkCameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onLayout = { [weak view] in
            guard let view else { return }
            syncOrientation(for: view)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.session = session
        uiView.previewLayer.videoGravity = .resizeAspectFill
        syncOrientation(for: uiView)
    }

    private func syncOrientation(for view: PreviewUIView) {
        let interfaceOrientation = view.window?.windowScene?.interfaceOrientation
        cameraManager.updateOrientation(
            to: UIDevice.current.orientation,
            interfaceOrientation: interfaceOrientation,
            previewConnection: view.previewLayer.connection
        )
    }

    final class PreviewUIView: UIView {
        var onLayout: (() -> Void)?

        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
            onLayout?()
        }
    }
}
