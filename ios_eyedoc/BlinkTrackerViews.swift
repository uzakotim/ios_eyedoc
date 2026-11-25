//
//  BlinkTrackerViews.swift
//  ios_eyedoc
//
//  Created by Timur Uzakov on 20/11/26.
//

import AudioToolbox
import SwiftUI

struct BlinkMonitorView: View {
    @Environment(BlinkCameraManager.self) private var cameraManager
    @State private var showSummarySheet = false
    @State private var rotationCounter = 0
    @State private var isBlinkShining = false
    @State private var isRedGlowing = false
    @State private var redGlowTask: Task<Void, Never>?

    private let lowBlinkThreshold = 12
    private let redGlowDurationSeconds: TimeInterval = 5.0

    private var circleGlowColor: Color {
        if isRedGlowing {
            return .red
        } else if isBlinkShining {
            return .cyan
        } else {
            return .secondary.opacity(0.35)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Color.clear
                    .frame(width: 0, height: 0)
                    .id(rotationCounter)

                // Prominent Circle for Last Completed Minute Blink Count
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(circleGlowColor.opacity(isRedGlowing || isBlinkShining ? 0.16 : 0.06))

                        Circle()
                            .stroke(circleGlowColor, lineWidth: 4)

                        VStack(spacing: 2) {
                            if let lastCount = cameraManager.lastCompletedMinuteBlinkCount {
                                Text("\(lastCount)")
                                    .font(.system(size: 46, weight: .bold, design: .rounded))
                                    .foregroundStyle(isRedGlowing ? .red : .primary)
                                    .contentTransition(.numericText())
                            } else {
                                Text("--")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }

                            Text("blinks/min")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 300, height: 300)
                    .scaleEffect(isBlinkShining ? 1.07 : 1.0)
                    .shadow(
                        color: isRedGlowing
                            ? .red.opacity(0.85)
                            : (isBlinkShining ? .cyan.opacity(0.9) : .clear),
                        radius: (isRedGlowing || isBlinkShining) ? 18 : 0
                    )
                    .animation(.easeOut(duration: 0.22), value: isBlinkShining)
                    .animation(.easeInOut(duration: 0.3), value: isRedGlowing)

                    if isRedGlowing, let lastCount = cameraManager.lastCompletedMinuteBlinkCount, lastCount < lowBlinkThreshold {
                        Label("Low blink rate last minute (< \(lowBlinkThreshold))", systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                // Current Active Minute Counter
                VStack(spacing: 4) {
                    Text("\(cameraManager.currentMinuteBlinkCount)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())

                    Text("Resets in \(cameraManager.secondsRemainingInMinute)s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Reset Now") {
                        cameraManager.resetCounter()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Blink Counter")
            .onChange(of: cameraManager.currentMinuteBlinkCount) { oldValue, newValue in
                guard newValue > oldValue else { return }
                triggerBlinkShine()
            }
            .onChange(of: cameraManager.lastCompletedMinuteBlinkCount) { _, newValue in
                guard let count = newValue, count < lowBlinkThreshold else { return }
                triggerRedGlowForFiveSeconds()
                playLowBlinkAlertSound()
            }
            .onAppear {
                cameraManager.startSession()
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
            .onDisappear {
                redGlowTask?.cancel()
                cameraManager.stopSession()
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            .sheet(isPresented: $showSummarySheet) {
                SecondaryBlinkView()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                rotationCounter += 1
            }
        }
    }

    private func triggerBlinkShine() {
        isBlinkShining = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            isBlinkShining = false
        }
    }

    private func triggerRedGlowForFiveSeconds() {
        redGlowTask?.cancel()
        isRedGlowing = true

        redGlowTask = Task {
            try? await Task.sleep(for: .seconds(redGlowDurationSeconds))
            guard !Task.isCancelled else { return }
            isRedGlowing = false
        }
    }

    private func playLowBlinkAlertSound() {
        // System alert tone; swap for AVAudioPlayer with a custom .wav/.mp3 in your bundle if preferred
        AudioServicesPlaySystemSound(1005)
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
