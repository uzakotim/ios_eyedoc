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
    @State private var isBlinkShining = false

    /// Shines red if the face is too close (≤ 0.4m) OR the last completed minute had fewer than 12 blinks.
    private var shouldShineRed: Bool {
        let lowLastMinuteCount = (cameraManager.lastCompletedMinuteBlinkCount ?? 12) < 12
        return lowLastMinuteCount
    }

    private var circleGlowColor: Color {
        if shouldShineRed {
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
                // Hidden/background orientation tracker so camera rotation still updates if preview is hidden
                Color.clear
                    .frame(width: 0, height: 0)
                    .id(rotationCounter)

                // Prominent Circle for Last Completed Minute Blink Count
                VStack(spacing: 8) {
//                    Text("Last Minute Blinks")
//                        .font(.subheadline.weight(.medium))
//                        .foregroundStyle(.secondary)

                    ZStack {
                        Circle()
                            .fill(circleGlowColor.opacity(shouldShineRed || isBlinkShining ? 0.16 : 0.06))

                        Circle()
                            .stroke(circleGlowColor, lineWidth: 4)

                        VStack(spacing: 2) {
                            if let lastCount = cameraManager.lastCompletedMinuteBlinkCount {
                                Text("\(lastCount)")
                                    .font(.system(size: 46, weight: .bold, design: .rounded))
                                    .foregroundStyle(shouldShineRed ? .red : .primary)
                                    .contentTransition(.numericText())
                            } else {
                                Text("--")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .foregroundStyle(shouldShineRed ? .red : .secondary)
                            }

                            Text("blinks/min")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 256, height: 256)
                    .scaleEffect(isBlinkShining ? 1.07 : 1.0)
                    .shadow(
                        color: shouldShineRed
                            ? .red.opacity(0.85)
                            : (isBlinkShining ? .cyan.opacity(0.9) : .clear),
                        radius: (shouldShineRed || isBlinkShining) ? 18 : 0
                    )
                    .animation(.easeOut(duration: 0.22), value: isBlinkShining)
                    .animation(.easeInOut(duration: 0.3), value: shouldShineRed)

                    // Optional contextual warning pill when shining red
                    if let lastCount = cameraManager.lastCompletedMinuteBlinkCount, lastCount < 12 {
                        Label("Low blink rate last minute (< 12)", systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                // Current Active Minute Counter
                VStack(spacing: 4) {
//                    Text("Current Minute")
//                        .font(.caption)
//                        .foregroundStyle(.secondary)

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

//                    Button("Open Other View") {
//                        showSummarySheet = true
//                    }
//                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Blink Counter")
            .onChange(of: cameraManager.currentMinuteBlinkCount) { oldValue, newValue in
                guard newValue > oldValue else { return }
                triggerBlinkShine()
            }
            .onAppear {
                cameraManager.startSession()
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
            .onDisappear {
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
