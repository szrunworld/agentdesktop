import Foundation

// GUI geometry of contract v1 (spec §08). Interface shapes follow
// docs/ai-gui/interfaces/AiGuiContracts.swift.

public struct Point: Equatable, Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public var description: String { "(\(x), \(y))" }
}

public struct Size: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct Rect: Equatable, Sendable {
    public let origin: Point
    public let size: Size
    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }
}

public struct Insets: Equatable, Sendable {
    public let left: Double
    public let top: Double
    public let right: Double
    public let bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public static let zero = Insets(left: 0, top: 0, right: 0, bottom: 0)
}

/// How a GUI adapter's model writes coordinates. Always explicit: a value is
/// never reinterpreted by its magnitude.
public enum CoordinateProtocol: String, CaseIterable, Sendable {
    /// 0..<1000 on each axis of the model input canvas.
    case normalized1000 = "normalized_1000"
    /// Pixels of the model input canvas.
    case imagePixels = "image_pixels"
}

/// `[a,b,c,d,tx,ty]` (named apart from Foundation.AffineTransform): x' = a*x + c*y + tx, y' = b*x + d*y + ty.
public struct GuiAffineTransform: Equatable, Sendable, CustomStringConvertible {
    public let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    /// From the wire array; must hold exactly six finite numbers.
    public init(array: [Double]) throws {
        guard array.count == 6 else {
            throw ContractError(.validationError, "an affine transform has exactly six numbers")
        }
        self.init(a: array[0], b: array[1], c: array[2], d: array[3], tx: array[4], ty: array[5])
        guard isFinite else { throw ContractError(.validationError, "affine transform is not finite") }
    }

    public init(json: JSONValue) throws {
        guard let items = json.arrayValue else {
            throw ContractError(.validationError, "affine transform must be an array")
        }
        let numbers = items.compactMap(\.doubleValue)
        guard numbers.count == items.count else {
            throw ContractError(.validationError, "affine transform must hold numbers")
        }
        try self.init(array: numbers)
    }

    public static let identity = GuiAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func scale(_ sx: Double, _ sy: Double) -> GuiAffineTransform {
        GuiAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public static func translate(_ tx: Double, _ ty: Double) -> GuiAffineTransform {
        GuiAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }

    public var array: [Double] { [a, b, c, d, tx, ty] }
    public var json: JSONValue { .array(array.map(JSONValue.double)) }
    public var isFinite: Bool { array.allSatisfy(\.isFinite) }
    public var determinant: Double { a * d - b * c }
    public var description: String { "[\(array.map { String($0) }.joined(separator: ","))]" }

    public func apply(_ p: Point) -> Point {
        Point(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }

    /// `self` first, then `next`: `next.apply(self.apply(p))`.
    public func then(_ next: GuiAffineTransform) -> GuiAffineTransform {
        GuiAffineTransform(
            a: next.a * a + next.c * b,
            b: next.b * a + next.d * b,
            c: next.a * c + next.c * d,
            d: next.b * c + next.d * d,
            tx: next.a * tx + next.c * ty + next.tx,
            ty: next.b * tx + next.d * ty + next.ty)
    }

    /// The inverse; VALIDATION_ERROR for a singular or non-finite matrix.
    public func inverted() throws -> GuiAffineTransform {
        let det = determinant
        guard isFinite, det.isFinite, abs(det) > 1e-12 else {
            throw ContractError(.validationError, "affine transform \(self) is singular")
        }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return GuiAffineTransform(a: ia, b: ib, c: ic, d: id,
                               tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }

    /// Whether two transforms agree to `tolerance` on every coefficient.
    public func isClose(to other: GuiAffineTransform, tolerance: Double = 1e-9) -> Bool {
        zip(array, other.array).allSatisfy { abs($0 - $1) <= tolerance * max(1, abs($0), abs($1)) }
    }
}
