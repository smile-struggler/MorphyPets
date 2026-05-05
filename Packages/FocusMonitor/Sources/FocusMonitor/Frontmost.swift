import Foundation
#if canImport(AppKit) && canImport(ApplicationServices)
import AppKit
import ApplicationServices

public struct FrontmostInfo: Sendable, Equatable {
    public let bundleID: String?
    public let appName: String?
    public let pid: pid_t
    public let windowTitle: String?
    public let url: String?
}

public enum FrontmostReader {
    public static func snapshot() -> FrontmostInfo {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let bundleID = app?.bundleIdentifier
        let name = app?.localizedName
        let (title, url) = pid > 0 ? readWindow(pid: pid, bundleID: bundleID) : (nil, nil)
        return FrontmostInfo(bundleID: bundleID, appName: name, pid: pid, windowTitle: title, url: url)
    }

    private static func readWindow(pid: pid_t, bundleID: String?) -> (String?, String?) {
        let appElem = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowElem = focused, CFGetTypeID(windowElem) == AXUIElementGetTypeID()
        else { return (nil, nil) }
        let window = windowElem as! AXUIElement

        var titleRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        let url = isBrowser(bundleID) ? findURL(in: window) : nil
        return (title, url)
    }

    private static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",   // Arc
            "org.mozilla.firefox",
        ].contains(bundleID)
    }

    /// DFS search the window's accessibility tree for an AXWebArea, return its AXURL.
    private static func findURL(in element: AXUIElement, depth: Int = 0) -> String? {
        if depth > 6 { return nil }
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == "AXWebArea" {
            var urlRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef)
            if let s = urlRef as? String { return s }
            if let u = urlRef as? NSURL { return u.absoluteString }
        }
        var childrenRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let url = findURL(in: child, depth: depth + 1) { return url }
            }
        }
        return nil
    }

    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt + opens System Settings if not yet trusted.
    @discardableResult
    public static func promptAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
#endif
