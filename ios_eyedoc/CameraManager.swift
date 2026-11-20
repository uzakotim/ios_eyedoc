//
//  CameraManager.swift
//  ios_eyedoc
//
//  Created by Timur Uzakov on 20/11/26.
//

import AVFoundation
import Observation
import UIKit
import Vision

@Observable
final class BlinkCameraManager: NSObject {
    // MARK: - Published / Observable UI State
    
    /// Current number of blinks recorded in the active 60-second window.
    var currentMinuteBlinkCount: Int = 0
    
    /// The final blink count from the previous completed minute.
    var lastCompletedMinuteBlinkCount: Int? = nil
    
    /// Seconds remaining until the current minute window resets (0...60).
    var secondsRemainingInMinute: Int = 60
    
    /// Estimated or measured face distance in meters (nil when unavailable or no face detected).
    var faceDistanceMeters: Float? = nil
    
    /// True when a face is detected at or closer than `maxCloseDistanceMeters` (0.4m).
    var isFaceWithinCloseRange: Bool = false
    
    /// Camera permission or detection status for UI feedback.
    var statusMessage: String = "Initializing camera..."
    var isRunning: Bool = false
    
    // MARK: - Configuration Thresholds
    
    /// Target proximity threshold: 0.4 meters (40 cm).
    let maxCloseDistanceMeters: Float = 0.4
    
    // Blink state & EAR (Eye Aspect Ratio) tuning
    private var isEyeClosed = false
    private var closedFrameCount = 0
    private let minClosedFramesForBlink = 2
    private let eyeClosedRatioThreshold: CGFloat = 0.25
    
    /// Fallback bounding-box height threshold (~0.45 of frame height) when TrueDepth isn't available.
    private let fallbackCloseFaceHeightThreshold: CGFloat = 0.45
    
    // MARK: - Private Camera & Vision Properties
    
    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.eyedoc.camera.session")
    private let dataOutputQueue = DispatchQueue(label: "com.eyedoc.camera.dataOutput", qos: .userInteractive)
    
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var usingTrueDepthCamera = false
    
    private var faceLandmarksRequest: VNDetectFaceLandmarksRequest?
    private var isProcessingFrame = false
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait
    private weak var previewConnection: AVCaptureConnection?
    
    // Minute timer state
    private var minuteTimer: Timer?
    private var elapsedSecondsInMinute = 0
    
    // MARK: - Initialization & Lifecycle
    
    override init() {
        super.init()
        setupVisionRequest()
    }
    
    deinit {
        stopSession()
    }
    
    func startSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndStartCaptureSession()
                    } else {
                        self?.statusMessage = "Camera access was denied. Enable it in Settings."
                    }
                }
            }
        case .denied, .restricted:
            statusMessage = "Camera access is restricted or denied in Settings."
        @unknown default:
            statusMessage = "Unknown camera authorization status."
        }
    }
    
    func stopSession() {
        stopMinuteTimer()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.isFaceWithinCloseRange = false
                self.faceDistanceMeters = nil
            }
        }
    }
    
    /// Manually resets the current minute counter and timer.
    func resetCounter() {
        DispatchQueue.main.async { [weak self] in
            self?.currentMinuteBlinkCount = 0
            self?.elapsedSecondsInMinute = 0
            self?.secondsRemainingInMinute = 60
        }
    }
    
    /// Updates rotation and mirroring across video output, depth output, and preview layer.
    func updateOrientation(
        to deviceOrientation: UIDeviceOrientation,
        interfaceOrientation: UIInterfaceOrientation? = nil,
        previewConnection: AVCaptureConnection?
    ) {
        if let previewConnection {
            self.previewConnection = previewConnection
        }
        
        let resolvedOrientation = resolvedDeviceOrientation(
            from: deviceOrientation,
            interfaceOrientation: interfaceOrientation
        )
        
        currentDeviceOrientation = resolvedOrientation
        let activePreviewConnection = previewConnection ?? self.previewConnection
        
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyOrientation(resolvedOrientation, previewConnection: activePreviewConnection)
        }
    }
    
    private func resolvedDeviceOrientation(
        from deviceOrientation: UIDeviceOrientation,
        interfaceOrientation: UIInterfaceOrientation?
    ) -> UIDeviceOrientation {
        if deviceOrientation.isValidInterfaceOrientation {
            return deviceOrientation
        }
        
        if let interfaceOrientation {
            switch interfaceOrientation {
            case .landscapeLeft:
                return .landscapeLeft
            case .landscapeRight:
                return .landscapeRight
            case .portraitUpsideDown:
                return .portraitUpsideDown
            case .portrait:
                return .portrait
            default:
                break
            }
        }
        
        return currentDeviceOrientation
    }
    
    private func applyOrientation(_ deviceOrientation: UIDeviceOrientation, previewConnection: AVCaptureConnection?) {
        let videoConnection = videoOutput.connection(with: .video)
        let depthConnection = usingTrueDepthCamera ? depthOutput.connection(with: .depthData) : nil
        
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch deviceOrientation {
            case .landscapeLeft:
                // If landscapeLeft is 180° upside-down on your iPad, change 0 to 180
                angle = 0
            case .landscapeRight:
                angle = 180
            case .portraitUpsideDown:
                angle = 270
            case .portrait:
                angle = 90
            default:
                angle = 90
            }
            
            configureConnection(videoConnection, rotationAngle: angle, mirror: true)
            configureConnection(depthConnection, rotationAngle: angle, mirror: false)
            
            DispatchQueue.main.async { [self] in
                self.configureConnection(previewConnection, rotationAngle: angle, mirror: true)
            }
        } else {
            let videoOrientation: AVCaptureVideoOrientation
            switch deviceOrientation {
            case .landscapeLeft:
                videoOrientation = .landscapeRight
            case .landscapeRight:
                videoOrientation = .landscapeLeft
            case .portraitUpsideDown:
                videoOrientation = .portraitUpsideDown
            default:
                videoOrientation = .portrait
            }
            
            configureLegacyConnection(videoConnection, orientation: videoOrientation, mirror: true)
            configureLegacyConnection(depthConnection, orientation: videoOrientation, mirror: false)
            
            DispatchQueue.main.async { [self] in
                self.configureLegacyConnection(previewConnection, orientation: videoOrientation, mirror: true)
            }
        }
    }
    
    // MARK: - Camera & Depth Setup
    
    private func configureAndStartCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            var didCommitConfiguration = false
            func finishConfiguration() {
                guard !didCommitConfiguration else { return }
                didCommitConfiguration = true
                self.captureSession.commitConfiguration()
            }
            
            self.captureSession.beginConfiguration()
            defer { finishConfiguration() }
            
            self.captureSession.sessionPreset = .vga640x480
            
            self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }
            self.outputSynchronizer = nil
            self.usingTrueDepthCamera = false
            
            let cameraDevice: AVCaptureDevice?
            if let trueDepth = AVCaptureDevice.default(
                .builtInTrueDepthCamera,
                for: .video,
                position: .front
            ) {
                cameraDevice = trueDepth
                self.usingTrueDepthCamera = true
            } else {
                cameraDevice = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .front
                )
                self.usingTrueDepthCamera = false
            }
            
            guard let frontCamera = cameraDevice else {
                finishConfiguration()
                DispatchQueue.main.async {
                    self.statusMessage = "Front camera not available on this device."
                }
                return
            }
            
            do {
                let input = try AVCaptureDeviceInput(device: frontCamera)
                guard self.captureSession.canAddInput(input) else {
                    finishConfiguration()
                    DispatchQueue.main.async {
                        self.statusMessage = "Unable to add front camera input."
                    }
                    return
                }
                self.captureSession.addInput(input)
                
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                
                guard self.captureSession.canAddOutput(self.videoOutput) else {
                    finishConfiguration()
                    DispatchQueue.main.async {
                        self.statusMessage = "Unable to add video frame output."
                    }
                    return
                }
                self.captureSession.addOutput(self.videoOutput)
                
                if self.usingTrueDepthCamera, self.captureSession.canAddOutput(self.depthOutput) {
                    self.captureSession.addOutput(self.depthOutput)
                    self.depthOutput.isFilteringEnabled = true
                    
                    let synchronizer = AVCaptureDataOutputSynchronizer(
                        dataOutputs: [self.videoOutput, self.depthOutput]
                    )
                    synchronizer.setDelegate(self, queue: self.dataOutputQueue)
                    self.outputSynchronizer = synchronizer
                } else {
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)
                }
                
                self.applyOrientation(self.currentDeviceOrientation, previewConnection: self.previewConnection)
                
                // Must commit configuration BEFORE calling startRunning()
                finishConfiguration()
                self.captureSession.startRunning()
                
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.statusMessage = self.usingTrueDepthCamera
                    ? "TrueDepth active • Checking 0.4m proximity & blinks..."
                    : "Front camera active • Using size estimate for proximity..."
                    self.startMinuteTimer()
                }
            } catch {
                finishConfiguration()
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to configure camera: \(error.localizedDescription)"
                }
            }
        }
    }
    

    @available(iOS 17.0, *)
    private func configureConnection(_ connection: AVCaptureConnection?, rotationAngle: CGFloat, mirror: Bool) {
        guard let connection else { return }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }

        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }

    private func configureLegacyConnection(_ connection: AVCaptureConnection?, orientation: AVCaptureVideoOrientation, mirror: Bool) {
        guard let connection else { return }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }

    private func visionImageOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch deviceOrientation {
        case .landscapeLeft:
            return .upMirrored
        case .landscapeRight:
            return .downMirrored
        case .portraitUpsideDown:
            return .leftMirrored
        case .portrait:
            return .rightMirrored
        default:
            return .upMirrored
        }
    }

    // MARK: - Vision Landmark Setup & Blink / Distance Evaluation

    private func setupVisionRequest() {
        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            defer { self?.isProcessingFrame = false }

            if let error {
                print("Vision face landmark error: \(error.localizedDescription)")
                return
            }

            guard let observations = request.results as? [VNFaceObservation],
                  let face = observations.first else {
                DispatchQueue.main.async { [weak self] in
                    self?.statusMessage = "No face detected"
                    self?.faceDistanceMeters = nil
                    self?.isFaceWithinCloseRange = false
                    self?.closedFrameCount = 0
                    self?.isEyeClosed = false
                }
                return
            }

            self?.evaluateFace(face, depthData: nil)
        }

        self.faceLandmarksRequest = request
    }

    private func evaluateFace(_ face: VNFaceObservation, depthData: AVDepthData?) {
        evaluateFace(face, depthData: depthData, completion: nil)
    }

    private func evaluateFace(
        _ face: VNFaceObservation,
        depthData: AVDepthData?,
        completion: (() -> Void)?
    ) {
        // 1. Evaluate 0.4m proximity
        let measuredDistance = estimateDistanceMeters(for: face, depthData: depthData)
        let isClose: Bool
        if let distance = measuredDistance {
            isClose = distance <= maxCloseDistanceMeters
        } else {
            // Fallback heuristic when depth data isn't available
            isClose = face.boundingBox.height >= fallbackCloseFaceHeightThreshold
        }

        // 2. Evaluate eye openness / blink state
        var averageRatio: CGFloat?
        if let landmarks = face.landmarks,
           let leftEye = landmarks.leftEye,
           let rightEye = landmarks.rightEye,
           let leftRatio = eyeAspectRatio(for: leftEye),
           let rightRatio = eyeAspectRatio(for: rightEye) {
            averageRatio = (leftRatio + rightRatio) / 2.0
        }

        DispatchQueue.main.async { [weak self] in
            defer { completion?() }
            guard let self else { return }

            self.faceDistanceMeters = measuredDistance
            self.isFaceWithinCloseRange = isClose

            let distanceText: String
            if let d = measuredDistance {
                distanceText = String(format: "%.2fm%@", d, isClose ? " (≤0.4m!)" : "")
            } else {
                distanceText = isClose ? "Close (≤0.4m est.)" : "Far"
            }

            if let ratio = averageRatio {
                let eyesClosedNow = ratio < self.eyeClosedRatioThreshold
                if eyesClosedNow {
                    self.closedFrameCount += 1
                    if self.closedFrameCount >= self.minClosedFramesForBlink {
                        self.isEyeClosed = true
                    }
                } else {
                    if self.isEyeClosed {
                        self.currentMinuteBlinkCount += 1
                    }
                    self.isEyeClosed = false
                    self.closedFrameCount = 0
                }
                self.statusMessage = String(format: "Dist: %@ • EAR: %.2f", distanceText, ratio)
            } else {
                self.statusMessage = "Dist: \(distanceText)"
            }
        }
    }

    /// Samples depth values inside the detected VNFaceObservation bounding box (in meters).
    private func estimateDistanceMeters(for face: VNFaceObservation, depthData: AVDepthData?) -> Float? {
        guard let depthData else { return nil }

        let floatDepthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = floatDepthData.depthDataMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        // Vision boundingBox uses normalized coordinates with origin at bottom-left.
        // Convert to top-left pixel coordinates for the depth map.
        let box = face.boundingBox
        let minX = max(0, Int(box.minX * CGFloat(width)))
        let maxX = min(width - 1, Int(box.maxX * CGFloat(width)))
        let minY = max(0, Int((1.0 - box.maxY) * CGFloat(height)))
        let maxY = min(height - 1, Int((1.0 - box.minY) * CGFloat(height)))

        guard maxX > minX, maxY > minY else { return nil }

        // Sample a grid inside the face box for fast, noise-resistant distance estimation
        var depths: [Float] = []
        let stepX = max(1, (maxX - minX) / 16)
        let stepY = max(1, (maxY - minY) / 16)

        var y = minY
        while y <= maxY {
            let rowPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            var x = minX
            while x <= maxX {
                let d = rowPtr[x]
                if d.isFinite && d > 0.05 && d < 5.0 {
                    depths.append(d)
                }
                x += stepX
            }
            y += stepY
        }

        guard !depths.isEmpty else { return nil }
        depths.sort()
        // Use the 25th percentile (closer to nose/forehead surface rather than background)
        let index = min(depths.count - 1, depths.count / 4)
        return depths[index]
    }

    private func eyeAspectRatio(for region: VNFaceLandmarkRegion2D) -> CGFloat? {
        let points = region.normalizedPoints
        guard points.count >= 4 else { return nil }

        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let width = maxX - minX
        let height = maxY - minY
        guard width > 0.0001 else { return nil }

        return height / width
    }

    // MARK: - Minute Counter & Reset Timer

    private func startMinuteTimer() {
        stopMinuteTimer()
        elapsedSecondsInMinute = 0
        secondsRemainingInMinute = 60

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            self.elapsedSecondsInMinute += 1
            let remaining = max(0, 60 - self.elapsedSecondsInMinute)
            self.secondsRemainingInMinute = remaining

            if self.elapsedSecondsInMinute >= 60 {
                self.lastCompletedMinuteBlinkCount = self.currentMinuteBlinkCount
                self.currentMinuteBlinkCount = 0
                self.elapsedSecondsInMinute = 0
                self.secondsRemainingInMinute = 60
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func stopMinuteTimer() {
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, depthData: AVDepthData?) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        let orientation = visionImageOrientation(for: currentDeviceOrientation)

        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let self else { return }

            if let error {
                print("Vision face landmark error: \(error.localizedDescription)")
                self.isProcessingFrame = false
                return
            }

            guard let observations = request.results as? [VNFaceObservation],
                  let face = observations.first else {
                DispatchQueue.main.async {
                    self.statusMessage = "No face detected"
                    self.faceDistanceMeters = nil
                    self.isFaceWithinCloseRange = false
                    self.closedFrameCount = 0
                    self.isEyeClosed = false
                    self.isProcessingFrame = false
                }
                return
            }

            self.evaluateFace(face, depthData: depthData) {
                self.isProcessingFrame = false
            }
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            isProcessingFrame = false
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension BlinkCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processPixelBuffer(pixelBuffer, depthData: nil)
    }
}

// MARK: - AVCaptureDataOutputSynchronizerDelegate

extension BlinkCameraManager: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ dataOutputSynchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        let depthSynced = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData
        let depthData = (depthSynced?.depthDataWasDropped == false) ? depthSynced?.depthData : nil

        if let videoSynced = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
           !videoSynced.sampleBufferWasDropped,
           let pixelBuffer = CMSampleBufferGetImageBuffer(videoSynced.sampleBuffer) {
            processPixelBuffer(pixelBuffer, depthData: depthData)
        }
    }
}
