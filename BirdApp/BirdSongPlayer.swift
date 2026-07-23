import AVFoundation
import Observation
import SwiftUI

// Streams a species' song from xeno-canto.
//
// The recogniser holds the audio session in `.record` mode while listening, so
// playback first asks it to stop (via the same `.stopBirdListening` notification
// the widget uses) — otherwise nothing would come out of the speaker, and the
// app would hear itself and "detect" the bird it is playing.
@Observable
@MainActor
final class BirdSongPlayer {
    static let shared = BirdSongPlayer()

    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var recording: XenoCantoService.Recording?
    // Which species is loaded, so several buttons on screen can tell whether the
    // sound coming out is theirs.
    private(set) var scientificName: String?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    private init() {}

    func toggle(scientificName name: String) async {
        if scientificName == name, state == .playing || state == .loading {
            stop()
            return
        }
        await play(scientificName: name)
    }

    func play(scientificName name: String) async {
        stop()
        scientificName = name
        state = .loading

        let found: XenoCantoService.Recording
        do {
            found = try await XenoCantoService.shared.recording(for: name)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        guard scientificName == name else { return }   // otro botón tomó el relevo

        // Free the microphone and switch the session to playback.
        NotificationCenter.default.post(name: .stopBirdListening, object: nil)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        recording = found
        let item = AVPlayerItem(url: found.audioURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }

        player.play()
        state = .playing
    }

    func stop() {
        player?.pause()
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if case .failed = state { return }   // keep the message on screen
        state = .idle
    }

    func isPlaying(_ name: String) -> Bool {
        scientificName == name && state == .playing
    }
}

// MARK: - SongPlayButton

// Play/stop the song of a species, with the credit xeno-canto's Creative Commons
// licences require. Used from the photo result and from the detail sheet.
struct SongPlayButton: View {
    let scientificName: String

    @State private var player = BirdSongPlayer.shared
    @AppStorage(XenoCantoService.apiKeyDefaultsKey) private var apiKey: String = ""

    private var isMine: Bool { player.scientificName == scientificName }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                Task { await player.toggle(scientificName: scientificName) }
            } label: {
                Label(labelText, systemImage: iconName)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isLoading)

            if apiKey.isEmpty {
                Text("Add your xeno-canto key in Settings to hear songs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if isMine, case .failed(let message) = player.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if isMine, player.state == .playing, let rec = player.recording {
                credit(rec)
            }
        }
    }

    // Attribution for the recordist — required by the CC licences.
    private func credit(_ rec: XenoCantoService.Recording) -> some View {
        Group {
            if let page = rec.pageURL {
                Link(destination: page) { creditText(rec) }
            } else {
                creditText(rec)
            }
        }
    }

    private func creditText(_ rec: XenoCantoService.Recording) -> some View {
        Text(verbatim: "XC\(rec.id) · \(rec.recordist) · xeno-canto")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var isLoading: Bool { isMine && player.state == .loading }

    private var iconName: String {
        if isLoading { return "hourglass" }
        return player.isPlaying(scientificName) ? "stop.fill" : "speaker.wave.2.fill"
    }

    private var labelText: String {
        if isLoading { return NSLocalizedString("Loading song…", comment: "") }
        return player.isPlaying(scientificName)
            ? NSLocalizedString("Stop", comment: "")
            : NSLocalizedString("Hear its song", comment: "")
    }
}

// MARK: - SongPlayIconButton

// Icon-only variant for tight spots such as a history row, where there is no
// room for the recordist credit — that stays on the detail screen, which is one
// tap away. Hidden entirely without a xeno-canto key, since it could do nothing.
struct SongPlayIconButton: View {
    let scientificName: String

    @State private var player = BirdSongPlayer.shared
    @AppStorage(XenoCantoService.apiKeyDefaultsKey) private var apiKey: String = ""

    private var isMine: Bool { player.scientificName == scientificName }
    private var isLoading: Bool { isMine && player.state == .loading }

    var body: some View {
        if !apiKey.isEmpty {
            Button {
                Task { await player.toggle(scientificName: scientificName) }
            } label: {
                Image(systemName: iconName)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            // Otherwise the whole row's NavigationLink would swallow the tap.
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .accessibilityLabel(player.isPlaying(scientificName) ? Text("Stop") : Text("Hear its song"))
        }
    }

    private var iconName: String {
        if isLoading { return "hourglass" }
        if isMine, case .failed = player.state { return "speaker.slash.fill" }
        return player.isPlaying(scientificName) ? "stop.circle.fill" : "speaker.wave.2.fill"
    }

    private var tint: Color {
        if isMine, case .failed = player.state { return .orange }
        return .accentColor
    }
}
