import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// The live picture of one Desktop display from ScreenCaptureKit. Low frame
/// rate, scaled down by the capture to the hub's width cap, each frame
/// copied out of the capture's IOSurface into a CGImage so the stream's
/// buffer pool is never pinned. At most one frame waits for the main actor;
/// newer frames replace it. Nothing is written to disk.
///
/// Ideas from engine SecondScreenCore/DisplayPreview (one SCStream per
/// display, complete frames only, a generation guard against late starts);
/// this target does not link the engine.
@MainActor
public final class ScreenCaptureFrameSource: DesktopFrameSource {
    private let request: DesktopFrameRequest
    private var stream: SCStream?
    private var output: Output?
    /// Bumped by every start and stop; a start or frame from an older
    /// generation is discarded.
    private var generation = 0

    public init(request: DesktopFrameRequest) { self.request = request }

    /// The factory the app hands to its hub.
    public static func hub() -> DesktopFrameHub {
        DesktopFrameHub { ScreenCaptureFrameSource(request: $0) }
    }

    public func start(frame: @escaping @MainActor (DesktopFrame) -> Void,
                      failure: @escaping @MainActor (DesktopFrameProblem) -> Void) {
        generation += 1
        let gen = generation
        // Checking does not prompt; the user grants it in System Settings.
        guard CGPreflightScreenCaptureAccess() else {
            failure(.permissionDenied)
            return
        }
        let request = self.request
        Task { @MainActor [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let self, gen == self.generation else { return }
                guard let display = content.displays.first(where: { $0.displayID == request.displayId }) else {
                    failure(.unavailable("找不到这个 Desktop 的显示器（\(request.displayId)）。"))
                    return
                }
                let config = SCStreamConfiguration()
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                let pxW = max(1, mode?.pixelWidth ?? display.width)
                let pxH = max(1, mode?.pixelHeight ?? display.height)
                let shrink = min(1, Double(request.maxPixelWidth) / Double(pxW))
                config.width = max(1, Int((Double(pxW) * shrink).rounded()))
                config.height = max(1, Int((Double(pxH) * shrink).rounded()))
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.framesPerSecond))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 3
                config.showsCursor = true
                let scale = Double(config.width) / Double(max(1, display.width))
                let out = Output(scale: scale, deliver: { [weak self] f in
                    guard let self, gen == self.generation else { return }
                    frame(f)
                }, stopped: { [weak self] error in
                    guard let self, gen == self.generation else { return }
                    failure(Self.problem(error))
                })
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                      configuration: config, delegate: out)
                try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: out.queue)
                try await stream.startCapture()
                guard gen == self.generation else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.output = out
            } catch {
                guard let self, gen == self.generation else { return }
                failure(Self.problem(error))
            }
        }
    }

    public func stop() {
        generation += 1
        output?.cancel()
        stream?.stopCapture { _ in }
        stream = nil
        output = nil
    }

    nonisolated static func problem(_ error: Error) -> DesktopFrameProblem {
        let e = error as NSError
        if e.domain == SCStreamErrorDomain, e.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        return .unavailable("屏幕捕获失败：\(e.localizedDescription)")
    }

    /// Receives sample buffers on its own queue and hands the newest frame
    /// to the main actor; never more than one frame is waiting.
    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "agentdesktop.live-frame")
        private let scale: Double
        private let deliver: @MainActor (DesktopFrame) -> Void
        private let stopped: @MainActor (Error) -> Void
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let lock = NSLock()
        private var pending: DesktopFrame?
        private var scheduled = false
        private var cancelled = false

        init(scale: Double, deliver: @escaping @MainActor (DesktopFrame) -> Void,
             stopped: @escaping @MainActor (Error) -> Void) {
            self.scale = scale
            self.deliver = deliver
            self.stopped = stopped
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                pending = nil
            }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, Self.isComplete(sampleBuffer),
                  let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ci = CIImage(cvPixelBuffer: pixels)
            // A copy: the IOSurface goes back to the stream at once.
            guard let image = context.createCGImage(ci, from: ci.extent) else { return }
            let frame = DesktopFrame(image: image, scale: scale)
            let schedule: Bool = lock.withLock {
                guard !cancelled else { return false }
                pending = frame
                if scheduled { return false }
                scheduled = true
                return true
            }
            guard schedule else { return }
            DispatchQueue.main.async { [self] in
                let next: DesktopFrame? = lock.withLock {
                    scheduled = false
                    defer { pending = nil }
                    return cancelled ? nil : pending
                }
                guard let next else { return }
                MainActor.assumeIsolated { deliver(next) }
            }
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            let cancelled = lock.withLock { self.cancelled }
            guard !cancelled else { return }
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { stopped(error) }
            }
        }

        /// Idle and blank frames carry no new picture.
        private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw) else { return false }
            return status == .complete
        }
    }
}
