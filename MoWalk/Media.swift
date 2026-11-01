import SwiftUI
import AVFoundation
import UIKit

// MARK: - Camera

/// System camera. Hands back the JPEG; a copy also goes to the photo library.
struct CameraView: UIViewControllerRepresentable {
    var onPhoto: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ p: CameraView) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let jpg = img.jpegData(compressionQuality: 0.85) {
                if picker.sourceType == .camera { UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil) }
                parent.onPhoto(jpg)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Interview recorder

/// AAC mono interview recorder. Keeps running with the screen locked (audio background mode).
@Observable
final class Recorder {
    var isRecording = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    private var rec: AVAudioRecorder?
    private var timer: Timer?

    func start(to url: URL) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try s.setActive(true)
        let r = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
        r.isMeteringEnabled = true
        r.record()
        rec = r
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let r = self.rec else { return }
            r.updateMeters()
            self.elapsed = r.currentTime
            self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
        }
    }

    /// Stops and returns the duration.
    @discardableResult
    func stop() -> TimeInterval {
        let d = rec?.currentTime ?? elapsed
        rec?.stop(); rec = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return d
    }
}

/// Plays back a capture's audio in the timeline.
@Observable
final class Player {
    var playingID: String?
    private var p: AVAudioPlayer?
    func toggle(_ id: String, url: URL) {
        if playingID == id { p?.stop(); playingID = nil; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        p = try? AVAudioPlayer(contentsOf: url)
        p?.play()
        playingID = p == nil ? nil : id
    }
}
