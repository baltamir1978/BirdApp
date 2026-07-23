//
//  BirdAppApp.swift
//  BirdApp
//
//  Created by Bruno Altamirano on 29/05/2026.
//

import SwiftUI

// C-compatible Darwin callback: a "Stop" tapped in the widget (a separate
// process) fires this; we re-post it as a normal Notification ContentView observes.
private func birdStopDarwinCallback(_ center: CFNotificationCenter?,
                                    _ observer: UnsafeMutableRawPointer?,
                                    _ name: CFNotificationName?,
                                    _ object: UnsafeRawPointer?,
                                    _ userInfo: CFDictionary?) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .stopBirdListening, object: nil)
    }
}

@main
struct BirdAppApp: App {
    init() {
        // Listen for the widget's cross-process "Stop" signal.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            birdStopDarwinCallback,
            birdStopDarwinName,
            nil,
            .deliverImmediately)

        // Register default values so code that reads UserDefaults directly
        // (e.g. BirdNETAnalyzer) sees the same defaults as the @AppStorage
        // bindings in SettingsView. Without this, `bool(forKey:)` returns
        // false for any key the user has never toggled — which silently
        // disabled the location/season filter for everyone.
        UserDefaults.standard.register(defaults: [
            "confidence_threshold": 0.35,         // lower default — catch quieter / less certain birds
            "detection_sensitivity": 1.3,         // sigmoid slope (0.5 … 1.5); higher = more eager
            "temporal_smoothing": false,          // consensus over overlapping windows
            "location_filter_influence": 0.7,     // 0 = off … 1 = full (soft filter)
            "high_pass_filter": false,
            "high_pass_cutoff": 200.0,            // Hz
            "signal_gate": false,                 // skip silence / low-band noise
            "clip_gate": true,                    // skip clipped audio
            "unprocessed_audio": true,            // raw mic input (no system DSP)
            "detection_display_seconds": 8.0,     // how long a result stays on screen
            PhotoIdentifier.fusionDefaultsKey: true, // let a recent song favour that species in a photo
            "background_listening": false,        // keep listening when minimised (opt-in)
            "background_listening_minutes": 30.0  // auto-stop after this long in the background
        ])

        // Optional developer convenience: if DeveloperKeys.plist is bundled it
        // seeds the xeno-canto key so it needn't be typed on every install. The
        // file is gitignored and absent from release builds — then, as intended,
        // each user supplies their own key in Settings. Registering it as a
        // *default* means a key typed in Settings still wins.
        if let key = XenoCantoService.bundledDeveloperKey {
            UserDefaults.standard.register(defaults: [XenoCantoService.apiKeyDefaultsKey: key])
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
