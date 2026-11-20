//
//  BlinkTrackerViews.swift
//  ios_eyedoc
//
//  Created by Timur Uzakov on 20/11/26.
//

import SwiftUI

struct BlinkMonitorView: View {
    @Environment(BlinkCameraManager.self) private var cameraManager
    @State private var showSummarySheet = false
    @State private var rotationCounter = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                CameraPreviewView(session: cameraManager.captureSession, cameraManager: cameraManager)
                    .frame(height: 600)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(alignment: .topLeading) {
                        Text(cameraManager.statusMessage)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                    }

                VStack(spacing: 6) {
                    Text("Blinks This Minute")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("\(cameraManager.currentMinuteBlinkCount)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())

                    Text("Resets in \(cameraManager.secondsRemainingInMinute)s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let lastCount = cameraManager.lastCompletedMinuteBlinkCount {
                    Text("Last minute total: \(lastCount) blinks")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Reset Now") {
                        cameraManager.resetCounter()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Other View") {
                        showSummarySheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Blink Counter")
            .onAppear {
                cameraManager.startSession()
            }
            .onDisappear {
                cameraManager.stopSession()
            }
            .sheet(isPresented: $showSummarySheet) {
                SecondaryBlinkView()
            }
            // Attach to your view:
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                rotationCounter += 1
            }
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
    }
}

/// Another view automatically reading the same live blink count via @Environment.
struct SecondaryBlinkView: View {
    @Environment(BlinkCameraManager.self) private var cameraManager

    var body: some View {
        VStack(spacing: 16) {
            Text("Live Shared Blink Count")
                .font(.headline)

            Text("\(cameraManager.currentMinuteBlinkCount)")
                .font(.system(size: 48, weight: .bold, design: .rounded))

            Text("Window resets in \(cameraManager.secondsRemainingInMinute) seconds")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
