import SwiftUI
import CoreMedia
import ChunkedAudioPlayer
import MediaPlayer
import AVFAudio

struct Shake: GeometryEffect {
    var amount: CGFloat = 10
    var shakesPerUnit = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translationX = amount * sin(animatableData * .pi * CGFloat(shakesPerUnit))
        return ProjectionTransform(CGAffineTransform(translationX: translationX, y: 0))
    }
}

struct TextToSpeechView: View {
    private let api = OpenAI()

    @AppStorage("apiKey") private var apiKey: String = ""
    @FocusState private var isFocused: Bool
    @StateObject private var player = AudioPlayer()
    @StateObject private var streamManager = AudioStreamManager()

    @State private var format = SpeechFormat.mp3
    @State private var voice = SpeechVoice.alloy
    @State private var model = SpeechModel.tts1
    @State private var inputKey = false
    @State private var errorMessage: String?
    @State private var didFail = false
    @State private var attempts = 0
    @State private var text = ""

    private var volumeBinding: Binding<Float> {
        Binding<Float> {
            player.volume
        } set: { volume in
            player.volume = volume
        }
    }

    private var rateBinding: Binding<Float> {
        Binding<Float> {
            player.rate
        } set: { rate in
            player.rate = rate
        }
    }

    private let commandCenter = MPRemoteCommandCenter.shared()
    private let audioSession = AVAudioSession.sharedInstance()

    var body: some View {
        VStack(alignment: .center, spacing: 24) {
            textInputView
            controlsView
            volumeView
            rateView
        }
        .padding()
        .frame(maxHeight: .infinity)
        .alert("Error", isPresented: $didFail) {
            Button("Retry") {
                errorMessage = nil
                didFail = false
                performConversion()
            }
            Button("Cancel") {
                errorMessage = nil
                didFail = false
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("OpenAI API Key", isPresented: $inputKey) {
            SecureField("API Key", text: $apiKey)
            Button("OK") {}
        } message: {
            Text("Please enter your OpenAI API key")
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                apiKeyButton
            }
            ToolbarItem(placement: .navigation) {
                if #available(iOS 16.4, tvOS 16.4, macOS 13.3, *) {
                    settingsMenu
                        #if !os(macOS)
                        .menuActionDismissBehavior(.disabled)
                        #endif
                } else {
                    settingsMenu
                }
            }
        }
        .onChange(of: player.currentError) { error in
            handleError(error)
            print("Error = \(error.flatMap { $0.debugDescription } ?? "nil")")
        }
        .onChange(of: player.currentTime) { time in
            print("Time = \(time.seconds)")
            updateNowPlayingInfo()
        }
        .onChange(of: player.currentDuration) { duration in
            print("Duration = \(duration.seconds)")
            updateNowPlayingInfo()
        }
        .onChange(of: player.currentRate) { rate in
            print("Rate = \(rate)")
            updateNowPlayingInfo()
        }
        .onChange(of: player.currentState) { state in
            print("State = \(state)")
            updateNowPlayingInfo()
        }
        .onAppear {
            setupRemoteControls()
        }
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("OpenAI Text-to-Speech")
    }

    @ViewBuilder
    private var textInputView: some View {
        inputTextField
            .focused($isFocused, equals: true)
            .font(.title3.monospaced())
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .submitLabel(.return)
            .autocorrectionDisabled()
            .modifier(Shake(animatableData: CGFloat(attempts)))
    }

    @ViewBuilder
    private var inputTextField: some View {
        if #available(iOS 16.0, tvOS 16.0, macOS 13.0, *) {
            TextField("Enter your input", text: $text, axis: .vertical)
        } else {
            TextField("Enter your input", text: $text)
        }
    }

    @ViewBuilder
    private var controlsView: some View {
        AudioControlsView(player: player) {
            switch player.currentState {
            case .initial, .failed, .completed: performConversion()
            case .playing: player.pause()
            case .paused: player.resume()
            }
        } onStop: {
            player.stop()
        } onRewind: {
            player.rewind(CMTime(seconds: 5.0, preferredTimescale: player.currentTime.timescale))
        } onForward: {
            player.forward(CMTime(seconds: 5.0, preferredTimescale: player.currentTime.timescale))
        }
    }

    @ViewBuilder
    private var volumeView: some View {
        VStack {
            Text("Volume: \(Int(player.volume * 100))")
            Slider(value: volumeBinding, in: 0...1, step: 0.01)
        }
        .frame(maxWidth: 200)
    }

    @ViewBuilder
    private var rateView: some View {
        VStack {
            Text("Rate: \(player.rate.formatted(.number.precision(.fractionLength(2))))")
            Slider(value: rateBinding, in: 0...1, step: 0.01)
        }
        .frame(maxWidth: 200)
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Menu {
            Menu {
                Picker("Format", selection: $format) {
                    ForEach(SpeechFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).id(format)
                    }
                }
            } label: {
                Text("Format")
                Text(format.rawValue)
            }
            Menu {
                Picker("Voice", selection: $voice) {
                    ForEach(SpeechVoice.allCases, id: \.self) { voice in
                        Text(voice.rawValue).id(voice)
                    }
                }
            } label: {
                Text("Voice")
                Text(voice.rawValue)
            }
            Menu {
                Picker("Model", selection: $model) {
                    ForEach(SpeechModel.allCases, id: \.self) { model in
                        Text(model.rawValue).id(model)
                    }
                }
            } label: {
                Text("Model")
                Text(model.rawValue)
            }
        } label: {
            Image(systemName: "gear")
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var apiKeyButton: some View {
        Button {
            inputKey = true
        } label: {
            Image(systemName: "key")
        }
        .tint(.primary)
    }

    private func performConversion() {
        isFocused = false
        if text.isEmpty {
            generateFeedback()
            withAnimation(.default) { attempts += 1 }
        } else if apiKey.isEmpty {
            generateFeedback()
            inputKey = true
        } else {
            Task {
                do {
                    player.stop()
                    streamManager.reset()
                    let stream = streamManager.createStream(from: {
                        try await api.textToSpeech(parameters: makeParameters())
                    })
                    player.start(stream, type: format.fileType)
                    updateNowPlayingInfo()
                } catch {
                    errorMessage = String(describing: error)
                    didFail = true
                }
            }
        }
    }

    private func makeParameters() -> TextToSpeechParameters {
        TextToSpeechParameters(
            apiKey: apiKey,
            model: model,
            voice: voice,
            format: format,
            stream: true,
            input: text
        )
    }

    private func generateFeedback() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        #endif
    }

    private func handleError(_ error: AudioPlayerError?) {
        if let error {
            errorMessage = String(describing: error)
            didFail = true
        } else {
            errorMessage = nil
            didFail = false
        }
    }

    private func setupRemoteControls() {
        do {
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        
        commandCenter.playCommand.addTarget { [weak player] _ in
            player?.resume()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak player] _ in
            player?.pause()
            return .success
        }
        
        commandCenter.stopCommand.addTarget { [weak player] _ in
            player?.stop()
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: 5)]
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: 5)]
        
        commandCenter.skipBackwardCommand.addTarget { [weak player] _ in
            player?.rewind(CMTime(seconds: 5.0, preferredTimescale: player?.currentTime.timescale ?? 1))
            return .success
        }
        
        commandCenter.skipForwardCommand.addTarget { [weak player] _ in
            player?.forward(CMTime(seconds: 5.0, preferredTimescale: player?.currentTime.timescale ?? 1))
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let player = player,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            
            let time = CMTime(seconds: event.positionTime, preferredTimescale: 1000)
            player.seek(to: time)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = text.isEmpty ? "Text to Speech" : text
        nowPlayingInfo[MPMediaItemPropertyArtist] = "OpenAI \(voice.rawValue)"
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime.seconds
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.currentDuration.seconds
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.currentRate
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

#Preview {
    TextToSpeechView()
}

class AudioStreamManager: ObservableObject {
    @Published private var cachedData: Data?
    
    func createStream(from dataProvider: @escaping () async throws -> AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<Data, Error> {
        if let cachedData = cachedData {
            return AsyncThrowingStream { continuation in
                continuation.yield(cachedData)
                continuation.finish()
            }
        } else {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        var collectedData = Data()
                        let stream = try await dataProvider()
                        for try await chunk in stream {
                            collectedData.append(chunk)
                            continuation.yield(chunk)
                        }
                        await MainActor.run {
                            self.cachedData = collectedData
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
    
    func reset() {
        cachedData = nil
    }
}
