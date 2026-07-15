#if DEBUG && canImport(UIKit)
import Foundation
import APIOSDebugCore
import UIKit

public enum ScreenshotCaptureMethod: String, Codable, Sendable {
    case drawHierarchy = "draw_hierarchy"
    case layerRender = "layer_render"
}

public struct CapturedScreenshot: Sendable, Equatable {
    public let pngData: Data
    public let method: ScreenshotCaptureMethod
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double
    public let sha256: String
}

@MainActor public final class ScreenshotCapture {
    typealias Renderer = @MainActor (UIWindow, ScreenshotCaptureMethod) -> Bool

    private let windows: @MainActor () -> [UIWindow]
    private let render: Renderer
    private let pngData: @MainActor (UIImage) -> Data?

    public init() {
        windows = {
            UIApplication.shared.connectedScenes
                .filter { $0.activationState == .foregroundActive }
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
        }
        render = { window, method in
            switch method {
            case .drawHierarchy:
                return window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            case .layerRender:
                guard let context = UIGraphicsGetCurrentContext() else { return false }
                window.layer.render(in: context)
                return true
            }
        }
        pngData = { $0.pngData() }
    }

    init(
        windows: @escaping @MainActor () -> [UIWindow],
        render: @escaping Renderer,
        pngData: @escaping @MainActor (UIImage) -> Data? = { $0.pngData() }
    ) {
        self.windows = windows
        self.render = render
        self.pngData = pngData
    }

    public func capture() throws -> CapturedScreenshot {
        do {
            guard let window = selectedWindow(from: windows()) else {
                throw CaptureFailure.noWindow
            }

            if let screenshot = try render(window: window, method: .drawHierarchy) {
                return screenshot
            }
            if let screenshot = try render(window: window, method: .layerRender) {
                return screenshot
            }
            throw CaptureFailure.renderingFailed
        } catch {
            throw Self.protocolError
        }
    }

    private func selectedWindow(from candidates: [UIWindow]) -> UIWindow? {
        let visible = candidates.filter {
            !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal
        }
        return visible.first(where: \.isKeyWindow) ?? visible.first
    }

    private func render(window: UIWindow, method: ScreenshotCaptureMethod) throws -> CapturedScreenshot? {
        let scale = window.screen.scale
        guard window.bounds.width > 0, window.bounds.height > 0, scale > 0 else {
            throw CaptureFailure.invalidImage
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        var succeeded = false
        let image = renderer.image { _ in
            succeeded = render(window, method)
        }
        guard succeeded else { return nil }
        guard let cgImage = image.cgImage,
            cgImage.width > 0,
            cgImage.height > 0,
            let data = pngData(image),
            data.count <= APIOSDebugProtocol.maximumPNGBytes,
            data.starts(with: Self.pngSignature)
        else {
            throw CaptureFailure.invalidImage
        }

        return CapturedScreenshot(
            pngData: data,
            method: method,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            scale: Double(scale),
            sha256: SHA256.hexDigest(data)
        )
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let protocolError = ProtocolError(
        code: AppErrorCode.screenshotFailed.rawValue,
        message: "The foreground App window could not be captured.",
        hint: "Keep the App foregrounded and avoid protected or unsupported rendering surfaces."
    )

    private enum CaptureFailure: Error {
        case noWindow
        case invalidImage
        case renderingFailed
    }
}
#endif
