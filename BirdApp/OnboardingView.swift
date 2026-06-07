import SwiftUI

// First-launch welcome screen. Explains why the app needs the microphone and
// location *before* the system permission prompts appear (shown right after the
// user taps "Get Started"), which improves comprehension and acceptance.
struct OnboardingView: View {
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 130, height: 130)
                Image(systemName: "bird.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 16)

            Text("Pájaros")
                .font(.largeTitle.bold())
            Text("Identify bird songs in real time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 24) {
                FeatureRow(icon: "mic.fill",
                           title: "Microphone",
                           detail: "Listens to bird song to identify species in real time.")
                FeatureRow(icon: "location.fill",
                           title: "Location",
                           detail: "Narrows results to the birds expected in your area and season.")
                FeatureRow(icon: "lock.shield.fill",
                           title: "Private & Offline",
                           detail: "All recognition runs on your device. Audio never leaves it.")
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)

            Spacer()

            Button(action: onComplete) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
