import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// Everything that goes through Meta's Device Access Toolkit: registration with
/// the Meta AI app, the device session, camera frames and photos. The display
/// and inputs live in GlassesDisplay.swift (their type names clash with SwiftUI).
@MainActor
final class Glasses: ObservableObject {
    @Published private(set) var registration = "unknown"
    @Published private(set) var registered = false
    @Published private(set) var devices = 0
    @Published private(set) var sessionState = "no session"
    @Published private(set) var cameraState = "off"
    @Published private(set) var frame: UIImage?
    @Published private(set) var frames = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var photo: UIImage?
    @Published private(set) var photoMs: Int?

    var onLog: ((String) -> Void)?
    let display = GlassesDisplay()

    private let wearables = Wearables.shared
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [AnyListenerToken] = []
    private var cameraTokens: [AnyListenerToken] = []
    private var fpsWindow: [Date] = []
    private var photoAskedAt: Date?
    private var showFrames = true

    init() {
        display.onLog = { [weak self] text in self?.onLog?(text) }
        Task { [weak self] in
            guard let self else { return }
            for await state in self.wearables.registrationStateStream() {
                self.registration = String(describing: state)
                self.registered = String(describing: state).lowercased().contains("registered")
                    && !String(describing: state).lowercased().contains("unregistered")
                self.onLog?("registration: \(state)")
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await list in self.wearables.devicesStream() {
                self.devices = list.count
                self.onLog?("glasses found: \(list.count)")
            }
        }
    }

    // MARK: Registration

    func register() {
        Task {
            do {
                try await wearables.startRegistration()
                onLog?("registration started: confirm in the Meta AI app")
            } catch {
                onLog?("registration failed: \(error)")
            }
        }
    }

    func unregister() {
        Task {
            do { try await wearables.startUnregistration() } catch { onLog?("unregister failed: \(error)") }
        }
    }

    /// The Meta AI app calls back through stridelab://…
    func handle(_ url: URL) {
        Task {
            do {
                let handled = try await wearables.handleUrl(url)
                onLog?(handled ? "Meta AI app answered" : "link not for the toolkit: \(url.absoluteString.prefix(60))")
            } catch {
                onLog?("callback failed: \(error)")
            }
        }
    }

    // MARK: Session

    /// One session per app run; camera and display hang off it.
    func ensureSession() async -> DeviceSession? {
        if let session { return session }
        do {
            let selector = AutoDeviceSelector(wearables: wearables)
            let session = try wearables.createSession(deviceSelector: selector)
            tokens.append(session.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    self?.sessionState = String(describing: state)
                    self?.onLog?("session: \(state)")
                }
            })
            tokens.append(session.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.onLog?("session error: \(error)") }
            })
            try session.start()
            self.session = session
            // Capabilities can only be added once the session has started.
            for _ in 0..<50 {
                if String(describing: session.state).lowercased().contains("started") { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return session
        } catch {
            onLog?("session failed: \(error)")
            return nil
        }
    }

    func endSession() {
        stopCamera()
        display.stop()
        session?.stop()
        session = nil
        tokens.removeAll()
        sessionState = "no session"
    }

    // MARK: Camera

    func startCamera(raw: Bool = true, showFrames: Bool = true) {
        Task {
            guard await cameraAllowed(), let session = await ensureSession() else { return }
            stopCamera()
            self.showFrames = showFrames
            do {
                let config = StreamConfiguration(videoCodec: raw ? VideoCodec.raw : VideoCodec.hvc1,
                                                 resolution: StreamingResolution.low, frameRate: 24)
                guard let camera = try session.addCamera(config: config) else {
                    onLog?("camera: not available yet (session \(sessionState))")
                    return
                }
                self.camera = camera
                frames = 0
                fpsWindow = []
                let stream = camera.stream
                cameraTokens.append(stream.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.cameraState = String(describing: state)
                        self?.onLog?("camera: \(state)")
                    }
                })
                cameraTokens.append(stream.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in self?.onLog?("camera error: \(error)") }
                })
                cameraTokens.append(stream.videoFramePublisher.listen { [weak self] frame in
                    let image = raw ? frame.makeUIImage() : nil
                    Task { @MainActor in self?.gotFrame(image) }
                })
                cameraTokens.append(stream.photoDataPublisher.listen { [weak self] photo in
                    let image = UIImage(data: photo.data)
                    Task { @MainActor in self?.gotPhoto(image) }
                })
                stream.start()
                onLog?("camera: starting (\(raw ? "raw" : "hvc1"), low, 24 fps)")
            } catch {
                onLog?("camera failed: \(error)")
            }
        }
    }

    func stopCamera() {
        camera?.stop()
        camera = nil
        cameraTokens.removeAll()
        if cameraState != "off" { cameraState = "off" }
        fps = 0
    }

    private func gotFrame(_ image: UIImage?) {
        frames += 1
        let now = Date()
        fpsWindow.append(now)
        fpsWindow.removeAll { now.timeIntervalSince($0) > 2 }
        fps = Double(fpsWindow.count) / 2
        if showFrames, let image { frame = image }
    }

    // MARK: Photo

    func takePhoto() {
        Task {
            if camera == nil {
                startCamera(raw: true)
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if cameraState.lowercased().contains("streaming") { break }
                }
            }
            guard let camera else { onLog?("photo: camera not running"); return }
            photoAskedAt = Date()
            let ok = camera.stream.capturePhoto(format: .jpeg)
            onLog?(ok ? "photo: requested" : "photo: the glasses refused the request")
        }
    }

    private func gotPhoto(_ image: UIImage?) {
        photo = image
        if let asked = photoAskedAt { photoMs = Int(Date().timeIntervalSince(asked) * 1000) }
        onLog?("photo: received\(photoMs.map { " after \($0) ms" } ?? "")\(image == nil ? " but could not decode it" : "")")
    }

    // MARK: Display and inputs

    func showCard(title: String, body: String) {
        Task {
            guard let session = await ensureSession() else { return }
            await display.show(on: session, title: title, body: body)
        }
    }

    func startInputs() {
        Task {
            guard let session = await ensureSession() else { return }
            display.startInputs(on: session)
        }
    }

    // MARK: Permission

    private func cameraAllowed() async -> Bool {
        do {
            if try await wearables.checkPermissionStatus(.camera) == .granted { return true }
            onLog?("camera permission: asking in the Meta AI app")
            let status = try await wearables.requestPermission(.camera)
            onLog?("camera permission: \(status)")
            return status == .granted
        } catch {
            onLog?("camera permission failed: \(error)")
            return false
        }
    }
}
