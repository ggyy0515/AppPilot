#if DEBUG && canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import APIOSDebugKit
import APIOSDebugCore

private let expectedScreenshotFailure = ProtocolError(
    code: "screenshot_failed",
    message: "The foreground App window could not be captured.",
    hint: "Keep the App foregrounded and avoid protected or unsupported rendering surfaces."
)

private final class ControlledKeyWindow: UIWindow {
    var controlledIsKeyWindow = false
    override var isKeyWindow: Bool { controlledIsKeyWindow }
}

@Test @MainActor func prefersVisibleNormalLevelKeyWindow() throws {
    let fallback = UIWindow(frame: CGRect(x: 0, y: 0, width: 4, height: 5))
    let key = ControlledKeyWindow(frame: CGRect(x: 0, y: 0, width: 6, height: 7))
    fallback.isHidden = false
    key.isHidden = false
    key.controlledIsKeyWindow = true
    var selected: UIWindow?
    let capture = ScreenshotCapture(
        windows: { [fallback, key] },
        render: { window, _ in
            selected = window
            return true
        })

    _ = try capture.capture()

    #expect(selected === key)
}

@Test @MainActor func ignoresHiddenTransparentAndSystemLevelWindows() throws {
    let hidden = ControlledKeyWindow(frame: CGRect(x: 0, y: 0, width: 4, height: 5))
    hidden.controlledIsKeyWindow = true
    hidden.isHidden = true
    let transparent = ControlledKeyWindow(frame: CGRect(x: 0, y: 0, width: 4, height: 5))
    transparent.controlledIsKeyWindow = true
    transparent.alpha = 0
    let system = ControlledKeyWindow(frame: CGRect(x: 0, y: 0, width: 4, height: 5))
    system.controlledIsKeyWindow = true
    system.windowLevel = .alert
    let visible = UIWindow(frame: CGRect(x: 0, y: 0, width: 8, height: 9))
    visible.isHidden = false
    var selected: UIWindow?
    let capture = ScreenshotCapture(
        windows: { [hidden, transparent, system, visible] },
        render: { window, _ in
            selected = window
            return true
        })

    _ = try capture.capture()

    #expect(selected === visible)
}

@Test @MainActor func usesDrawHierarchyWithoutUnneededFallback() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 20))
    window.isHidden = false
    var calls: [ScreenshotCaptureMethod] = []
    let capture = ScreenshotCapture(
        windows: { [window] },
        render: { _, method in
            calls.append(method)
            return true
        })

    let result = try capture.capture()

    #expect(calls == [.drawHierarchy])
    #expect(result.method == .drawHierarchy)
}

@Test @MainActor func fallsBackToLayerRendering() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 20))
    window.isHidden = false
    var calls: [ScreenshotCaptureMethod] = []
    let capture = ScreenshotCapture(
        windows: { [window] },
        render: { _, method in
            calls.append(method)
            return method == .layerRender
        })

    let result = try capture.capture()

    #expect(calls == [.drawHierarchy, .layerRender])
    #expect(result.method == .layerRender)
}

@Test @MainActor func reportsValidPNGAndExactMetadata() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 20))
    window.isHidden = false
    let capture = ScreenshotCapture(windows: { [window] }, render: { _, _ in true })

    let result = try capture.capture()

    #expect(result.pngData.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])))
    #expect(result.pixelWidth == Int(10 * window.screen.scale))
    #expect(result.pixelHeight == Int(20 * window.screen.scale))
    #expect(result.scale == Double(window.screen.scale))
    #expect(result.sha256 == SHA256.hexDigest(result.pngData))
    #expect(result.sha256.count == 64)
    #expect(result.sha256.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
}

@Test @MainActor func noWindowBecomesStableProtocolError() {
    expectScreenshotFailure(from: ScreenshotCapture(windows: { [] }, render: { _, _ in true }))
}

@Test @MainActor func bothRenderersFailWithNoPartialResult() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 20))
    window.isHidden = false
    expectScreenshotFailure(from: ScreenshotCapture(windows: { [window] }, render: { _, _ in false }))
}

@Test @MainActor func oversizedPNGBecomesStableProtocolError() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    window.isHidden = false
    let oversized = Data(repeating: 0, count: APIOSDebugProtocol.maximumPNGBytes + 1)
    let capture = ScreenshotCapture(
        windows: { [window] },
        render: { _, _ in true },
        pngData: { _ in oversized }
    )
    expectScreenshotFailure(from: capture)
}

@Test @MainActor func invalidPrimaryPNGDoesNotInvokeFallback() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    window.isHidden = false
    var calls: [ScreenshotCaptureMethod] = []
    let capture = ScreenshotCapture(
        windows: { [window] },
        render: { _, method in
            calls.append(method)
            return true
        },
        pngData: { _ in Data("not-png".utf8) }
    )

    expectScreenshotFailure(from: capture)

    #expect(calls == [.drawHierarchy])
}

@MainActor private func expectScreenshotFailure(from capture: ScreenshotCapture) {
    do {
        _ = try capture.capture()
        Issue.record("Expected screenshot capture to fail without returning a partial result")
    } catch let error as ProtocolError {
        #expect(error == expectedScreenshotFailure)
    } catch {
        Issue.record("Expected ProtocolError, got \(type(of: error))")
    }
}
#endif
