//
//  BirdAppApp.swift
//  BirdApp
//
//  Created by Bruno Altamirano on 29/05/2026.
//

import SwiftUI

@main
struct BirdAppApp: App {
    init() {
        // Register default values so code that reads UserDefaults directly
        // (e.g. BirdNETAnalyzer) sees the same defaults as the @AppStorage
        // bindings in SettingsView. Without this, `bool(forKey:)` returns
        // false for any key the user has never toggled — which silently
        // disabled the location/season filter for everyone.
        UserDefaults.standard.register(defaults: [
            "confidence_threshold": 0.5,          // whoBIRD-style lower default
            "detection_sensitivity": 1.0,         // sigmoid slope (0.5 … 1.5)
            "temporal_smoothing": true,           // consensus over overlapping windows
            "location_filter_influence": 1.0,     // 0 = off … 1 = full (soft filter)
            "high_pass_filter": true,
            "high_pass_cutoff": 200.0,            // Hz
            "signal_gate": true,                  // skip silence / low-band noise
            "clip_gate": true,                    // skip clipped audio
            "unprocessed_audio": true             // raw mic input (no system DSP)
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
