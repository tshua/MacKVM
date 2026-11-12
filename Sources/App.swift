// 菜单栏应用入口
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
        // 调试用：--snapshot <路径> 把面板渲染成 PNG 后退出
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dark = args.contains("--dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Self.snapshot(to: args[i + 1], dark: dark) }
        }
    }

    static func snapshot(to path: String, dark: Bool) {
        let host = NSHostingView(rootView: PanelView().environmentObject(AppState.shared)
            .background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        win.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

@main
struct SwitchBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("设备切换", systemImage: "arrow.left.arrow.right.square.fill") {
            PanelView().environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}
