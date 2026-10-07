import Foundation

// Observation types of contract v1 (spec §04, §08.3). The Runtime produces
// them; GUI code only reads them.

public struct TargetIdentity: Equatable, Sendable {
    public let appId: String
    public let processId: Int
    public let processStartId: String
    public let windowId: String
    public let windowGeometryRevision: UInt64
    public let backendId: String
    public let windowFrameDesktopLogical: Rect

    public init(appId: String, processId: Int, processStartId: String, windowId: String,
                windowGeometryRevision: UInt64, backendId: String, windowFrameDesktopLogical: Rect) {
        self.appId = appId; self.processId = processId; self.processStartId = processStartId
        self.windowId = windowId; self.windowGeometryRevision = windowGeometryRevision
        self.backendId = backendId; self.windowFrameDesktopLogical = windowFrameDesktopLogical
    }

    public var json: JSONValue {
        let f = windowFrameDesktopLogical
        return .obj([
            ("appId", .string(appId)), ("processId", .int(processId)),
            ("processStartId", .string(processStartId)), ("windowId", .string(windowId)),
            ("windowGeometryRevision", .int(Int(windowGeometryRevision))), ("backendId", .string(backendId)),
            ("windowFrameDesktopLogical", .obj([
                ("x", .double(f.origin.x)), ("y", .double(f.origin.y)),
                ("width", .double(f.size.width)), ("height", .double(f.size.height)),
            ])),
        ])
    }
}

/// The image pipeline from the source screenshot to the model input canvas:
/// crop, resize, then letterbox padding.
public struct ScreenshotTransform: Equatable, Sendable {
    public let sourceSize: Size
    public let crop: Rect
    public let resizedSize: Size
    public let letterbox: Insets
    public let modelInputSize: Size
    public let sourceToModel: GuiAffineTransform
    public let modelToSource: GuiAffineTransform

    /// Builds and checks a transform. The two affine maps must be finite,
    /// invertible and each other's inverse; sizes must be consistent.
    public init(sourceSize: Size, crop: Rect, resizedSize: Size, letterbox: Insets,
                modelInputSize: Size, sourceToModel: GuiAffineTransform, modelToSource: GuiAffineTransform) throws {
        self.sourceSize = sourceSize; self.crop = crop; self.resizedSize = resizedSize
        self.letterbox = letterbox; self.modelInputSize = modelInputSize
        self.sourceToModel = sourceToModel; self.modelToSource = modelToSource
        try validate()
    }

    /// The transform for the pipeline itself: crop, scale to `resizedSize`,
    /// offset by the letterbox.
    public static func pipeline(sourceSize: Size, crop: Rect? = nil, resizedSize: Size? = nil,
                                letterbox: Insets = .zero) throws -> ScreenshotTransform {
        let crop = crop ?? Rect(origin: Point(x: 0, y: 0), size: sourceSize)
        let resized = resizedSize ?? crop.size
        let toModel = GuiAffineTransform.translate(-crop.origin.x, -crop.origin.y)
            .then(.scale(resized.width / crop.size.width, resized.height / crop.size.height))
            .then(.translate(letterbox.left, letterbox.top))
        let model = Size(width: resized.width + letterbox.left + letterbox.right,
                         height: resized.height + letterbox.top + letterbox.bottom)
        return try ScreenshotTransform(sourceSize: sourceSize, crop: crop, resizedSize: resized, letterbox: letterbox,
                                       modelInputSize: model, sourceToModel: toModel, modelToSource: try toModel.inverted())
    }

    func validate() throws {
        func bad(_ m: String) -> ContractError { ContractError(.validationError, "screenshot transform: \(m)") }
        let dims = [sourceSize.width, sourceSize.height, crop.size.width, crop.size.height,
                    resizedSize.width, resizedSize.height, modelInputSize.width, modelInputSize.height]
        guard dims.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw bad("sizes must be positive") }
        guard crop.origin.x >= 0, crop.origin.y >= 0,
              crop.origin.x + crop.size.width <= sourceSize.width,
              crop.origin.y + crop.size.height <= sourceSize.height else { throw bad("crop lies outside the source") }
        let insets = [letterbox.left, letterbox.top, letterbox.right, letterbox.bottom]
        guard insets.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw bad("letterbox must be non-negative") }
        guard abs(resizedSize.width + letterbox.left + letterbox.right - modelInputSize.width) < 1e-9,
              abs(resizedSize.height + letterbox.top + letterbox.bottom - modelInputSize.height) < 1e-9 else {
            throw bad("model input size is not resized size plus letterbox")
        }
        let inverse = try sourceToModel.inverted()
        _ = try modelToSource.inverted()
        guard inverse.isClose(to: modelToSource, tolerance: 1e-9) else {
            throw bad("modelToSource is not the inverse of sourceToModel")
        }
    }

    /// The part of the model canvas that shows the image (letterbox excluded).
    public var contentRegion: Rect {
        Rect(x: letterbox.left, y: letterbox.top, width: resizedSize.width, height: resizedSize.height)
    }

    public init(json: JSONValue) throws {
        func size(_ v: JSONValue?) throws -> Size {
            guard let w = v?["width"]?.doubleValue, let h = v?["height"]?.doubleValue else {
                throw ContractError(.validationError, "screenshot transform: bad size")
            }
            return Size(width: w, height: h)
        }
        guard let c = json["crop"], let x = c["x"]?.doubleValue, let y = c["y"]?.doubleValue,
              let w = c["width"]?.doubleValue, let h = c["height"]?.doubleValue,
              let l = json["letterbox"], let ll = l["left"]?.doubleValue, let lt = l["top"]?.doubleValue,
              let lr = l["right"]?.doubleValue, let lb = l["bottom"]?.doubleValue,
              let s2m = json["sourceToModel"], let m2s = json["modelToSource"] else {
            throw ContractError(.validationError, "screenshot transform is incomplete")
        }
        try self.init(sourceSize: size(json["sourceSize"]), crop: Rect(x: x, y: y, width: w, height: h),
                      resizedSize: size(json["resizedSize"]), letterbox: Insets(left: ll, top: lt, right: lr, bottom: lb),
                      modelInputSize: size(json["modelInputSize"]),
                      sourceToModel: GuiAffineTransform(json: s2m), modelToSource: GuiAffineTransform(json: m2s))
    }

    public var json: JSONValue {
        func size(_ s: Size) -> JSONValue { .obj([("width", .double(s.width)), ("height", .double(s.height))]) }
        return .obj([
            ("sourceSize", size(sourceSize)),
            ("crop", .obj([("x", .double(crop.origin.x)), ("y", .double(crop.origin.y)),
                           ("width", .double(crop.size.width)), ("height", .double(crop.size.height))])),
            ("resizedSize", size(resizedSize)),
            ("letterbox", .obj([("left", .double(letterbox.left)), ("top", .double(letterbox.top)),
                                ("right", .double(letterbox.right)), ("bottom", .double(letterbox.bottom))])),
            ("modelInputSize", size(modelInputSize)),
            ("sourceToModel", sourceToModel.json),
            ("modelToSource", modelToSource.json),
        ])
    }
}

public struct ScreenshotDescriptor: Equatable, Sendable {
    public let screenshotId: String
    public let artifactRef: String
    public let sha256: String
    public let mimeType: String
    public let transformVersion: String
    /// Source screenshot pixels → Desktop logical points (negative origins are legal).
    public let sourceToDesktop: GuiAffineTransform
    public let transform: ScreenshotTransform

    public init(screenshotId: String, artifactRef: String, sha256: String, mimeType: String,
                transformVersion: String, sourceToDesktop: GuiAffineTransform, transform: ScreenshotTransform) throws {
        self.screenshotId = screenshotId; self.artifactRef = artifactRef; self.sha256 = sha256
        self.mimeType = mimeType; self.transformVersion = transformVersion
        self.sourceToDesktop = sourceToDesktop; self.transform = transform
        _ = try sourceToDesktop.inverted()
    }

    public var json: JSONValue {
        .obj([
            ("screenshotId", .string(screenshotId)), ("artifactRef", .string(artifactRef)),
            ("sha256", .string(sha256)), ("mimeType", .string(mimeType)),
            ("transformVersion", .string(transformVersion)),
            ("sourceToDesktop", sourceToDesktop.json), ("transform", transform.json),
        ])
    }
}

public struct ObservationStamp: Equatable, Sendable {
    public let sessionId: String
    public let desktopId: String
    public let snapshotId: String
    public let bindingEpoch: UInt64
    /// Runtime's currentGeneration when the observation was taken.
    public let runGeneration: UInt64

    public init(sessionId: String, desktopId: String, snapshotId: String, bindingEpoch: UInt64, runGeneration: UInt64) {
        self.sessionId = sessionId; self.desktopId = desktopId; self.snapshotId = snapshotId
        self.bindingEpoch = bindingEpoch; self.runGeneration = runGeneration
    }
}

public struct Observation: Equatable, Sendable {
    public let observationId: String
    public let stamp: ObservationStamp
    public let target: TargetIdentity
    public let observedAt: Date
    public let screenshots: [ScreenshotDescriptor]

    public init(observationId: String, stamp: ObservationStamp, target: TargetIdentity,
                observedAt: Date, screenshots: [ScreenshotDescriptor]) {
        self.observationId = observationId; self.stamp = stamp; self.target = target
        self.observedAt = observedAt; self.screenshots = screenshots
    }

    public func screenshot(_ id: String) -> ScreenshotDescriptor? { screenshots.first { $0.screenshotId == id } }

    public var json: JSONValue {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .obj([
            ("observationId", .string(observationId)), ("snapshotId", .string(stamp.snapshotId)),
            ("sessionId", .string(stamp.sessionId)), ("desktopId", .string(stamp.desktopId)),
            ("target", target.json), ("bindingEpoch", .int(Int(stamp.bindingEpoch))),
            ("runGeneration", .int(Int(stamp.runGeneration))),
            ("observedAt", .string(f.string(from: observedAt))),
            ("screenshots", .array(screenshots.map(\.json))),
        ])
    }
}
