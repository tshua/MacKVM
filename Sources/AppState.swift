// 应用状态：设备信息、配置、切换动作、热键、登录自启
import AppKit
import Carbon
import IOKit.hid
import ServiceManagement
import SwiftUI

enum Keys {
    static let targetInput = "targetInput"     // 另一台设备对应的显示器输入源
    static let thisInput = "thisInput"         // 本机对应的显示器输入源（自动记录）
    static let targetHost = "targetHost"       // 另一台设备对应的鼠标通道
    static let thisHost = "thisHost"           // 本机对应的鼠标通道（自动记录）
    static let switchDisplay = "switchDisplay"
    static let switchMouse = "switchMouse"
    static let kbToOther = "kbToOther"
    static let kbToThis = "kbToThis"
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyMods = "hotKeyMods"
    static let hotKeyLabel = "hotKeyLabel"
    static let displayInputs = "displayInputs"
    static let mouseName = "mouseName"
    static let mouseHosts = "mouseHosts"
}

private let ddcQueue = DispatchQueue(label: "switchbar.ddc")
private let logiQueue = DispatchQueue(label: "switchbar.logi")

final class AppState: ObservableObject {
    static let shared = AppState()
    private let d = UserDefaults.standard

    @Published var displayName: String?
    @Published var displayInputs: [Int] = []
    @Published var displayCurrent: Int?
    @Published var mouseName: String?
    @Published var mouseHosts = 3
    @Published var mouseCurrent: Int?
    @Published var mouseStatus = "检测中…"
    @Published var keyboardName: String?
    @Published var hidAccess = false
    @Published var message = ""
    @Published var messageIsError = false
    @Published var recording = false
    @Published var loginItem = false
    @Published var hotKeyOK = true
    @Published var switching = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var recordMonitor: Any?
    private var refreshing = false

    init() {
        d.register(defaults: [
            Keys.targetHost: 0, Keys.targetInput: 0,
            Keys.switchDisplay: true, Keys.switchMouse: true,
            Keys.kbToOther: "", Keys.kbToThis: "",
            Keys.hotKeyCode: kVK_F1, Keys.hotKeyMods: 0, Keys.hotKeyLabel: "F1",
        ])
        displayInputs = d.array(forKey: Keys.displayInputs) as? [Int] ?? []
        mouseName = d.string(forKey: Keys.mouseName)
        if d.integer(forKey: Keys.mouseHosts) > 0 { mouseHosts = d.integer(forKey: Keys.mouseHosts) }
    }

    func start() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        registerHotKey()
        refresh()
        if CommandLine.arguments.contains("--request-access") { continueAccessRequest() }
    }

    // MARK: 设备状态

    func refresh() {
        hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        loginItem = SMAppService.mainApp.status == .enabled
        displayName = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }?.localizedName
        keyboardName = Self.externalKeyboardName()

        guard !refreshing else { return }
        refreshing = true
        let group = DispatchGroup()

        ddcQueue.async(group: group) {
            var inputs = self.d.array(forKey: Keys.displayInputs) as? [Int] ?? []
            if inputs.isEmpty {
                inputs = DDC.supportedInputs()
                if !inputs.isEmpty { self.d.set(inputs, forKey: Keys.displayInputs) }
            }
            let cur = DDC.get(DDC.inputSource).map { $0 & 0xFF }
            DispatchQueue.main.async {
                self.displayInputs = inputs
                self.displayCurrent = cur
                if let cur {
                    self.d.set(cur, forKey: Keys.thisInput)
                    if self.d.integer(forKey: Keys.targetInput) == 0, let other = inputs.first(where: { $0 != cur }) {
                        self.d.set(other, forKey: Keys.targetInput)
                    }
                }
            }
        }

        logiQueue.async(group: group) {
            let r = Logi.info()
            DispatchQueue.main.async {
                switch r {
                case .success(let info):
                    self.mouseName = info.name; self.mouseHosts = info.hosts; self.mouseCurrent = info.current
                    self.mouseStatus = "已连接本机"
                    self.d.set(info.name, forKey: Keys.mouseName)
                    self.d.set(info.hosts, forKey: Keys.mouseHosts)
                    self.d.set(info.current, forKey: Keys.thisHost)
                    if self.d.integer(forKey: Keys.targetHost) == 0 {
                        self.d.set(info.current == 1 ? 2 : 1, forKey: Keys.targetHost)
                    }
                case .failure(let e):
                    self.mouseCurrent = nil
                    self.mouseStatus = e.text
                }
            }
        }

        group.notify(queue: .main) { self.refreshing = false }
    }

    private static func externalKeyboardName() -> String? {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        for dev in devs {
            let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let transport = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String ?? ""
            guard vid != 0, vid != 0x05AC, vid != 0x046D, transport.contains("Bluetooth") || transport == "USB" else { continue }
            if let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String { return name }
        }
        return nil
    }

    // MARK: 切换

    func switchNow() {
        let host = d.integer(forKey: Keys.targetHost), input = d.integer(forKey: Keys.targetInput)
        let doMouse = d.bool(forKey: Keys.switchMouse) && host > 0
        let doDisplay = d.bool(forKey: Keys.switchDisplay) && input > 0
        guard doMouse || doDisplay else { show("没有可切换的设备，请先在面板中配置", error: true); return }
        // 没有输入监控权限时鼠标切不过去；此时不切显示器，否则错误提示会跟着屏幕一起消失
        if doMouse, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            hidAccess = false
            show("缺少输入监控权限，未执行切换", error: true)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法切换鼠标"
            alert.informativeText = "「设备切换」没有输入监控权限，所以这次没有执行切换。\n\n点击「去授权」后应用会重启并打开设置页，在列表里打开 SwitchBar 的开关即可。应用更新后需要重新授权一次。"
            alert.addButton(withTitle: "去授权")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { requestInputMonitoring() }
            return
        }
        switching = true
        show("正在切换…", error: false)
        // 先切鼠标：显示器切走后 DDC 调用会阻塞一段时间
        logiQueue.async {
            var problems: [String] = []
            if doMouse, let err = Logi.setHost(host) { problems.append("鼠标：\(err)") }
            if doDisplay, !DDC.set(DDC.inputSource, input) { problems.append("显示器：指令发送失败") }
            DispatchQueue.main.async {
                self.switching = false
                if problems.isEmpty {
                    let custom = self.d.string(forKey: Keys.kbToOther) ?? ""
                    self.show("已切换。键盘请按 \(custom.isEmpty ? AppState.keyboardCombo(forChannel: host) : custom)", error: false)
                } else {
                    self.show(problems.joined(separator: "；"), error: true)
                }
            }
        }
    }

    func show(_ text: String, error: Bool) { message = text; messageIsError = error }

    // MARK: 热键

    func registerHotKey() {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { AppState.shared.switchNow() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        unregisterHotKey()
        let rc = RegisterEventHotKey(UInt32(d.integer(forKey: Keys.hotKeyCode)), UInt32(d.integer(forKey: Keys.hotKeyMods)),
                                     EventHotKeyID(signature: 0x53574252, id: 1), GetApplicationEventTarget(), 0, &hotKeyRef)
        hotKeyOK = rc == noErr
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    func toggleRecording() {
        if recording { stopRecording(); return }
        recording = true
        unregisterHotKey()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.captured(ev)
            return nil
        }
    }

    private func stopRecording() {
        if let m = recordMonitor { NSEvent.removeMonitor(m); recordMonitor = nil }
        recording = false
        registerHotKey()
    }

    private func captured(_ ev: NSEvent) {
        let code = Int(ev.keyCode)
        if code == kVK_Escape { stopRecording(); return }
        let f = ev.modifierFlags
        var mods = 0, prefix = ""
        if f.contains(.control) { mods |= controlKey; prefix += "⌃" }
        if f.contains(.option) { mods |= optionKey; prefix += "⌥" }
        if f.contains(.shift) { mods |= shiftKey; prefix += "⇧" }
        if f.contains(.command) { mods |= cmdKey; prefix += "⌘" }
        let special = Self.specialKeys[code]
        let isFunctionKey = special?.hasPrefix("F") == true
        guard mods & (controlKey | optionKey | cmdKey) != 0 || isFunctionKey else {
            show("需要带 ⌃ ⌥ ⌘ 之一，或使用 F1–F12", error: true)
            return
        }
        let name = special ?? ev.charactersIgnoringModifiers?.uppercased() ?? "键 \(code)"
        d.set(code, forKey: Keys.hotKeyCode)
        d.set(mods, forKey: Keys.hotKeyMods)
        d.set(prefix + name, forKey: Keys.hotKeyLabel)
        stopRecording()
        show(hotKeyOK ? "快捷键已设为 \(prefix + name)" : "该快捷键已被占用，请换一个", error: !hotKeyOK)
    }

    static let specialKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
    ]

    /// 键盘蓝牙通道 1/2/3 对应 Fn+Q/W/E，与鼠标通道号保持一致
    static func keyboardCombo(forChannel n: Int) -> String {
        let keys = ["Q", "W", "E"]
        return (1...keys.count).contains(n) ? "Fn+\(keys[n - 1])" : "—"
    }

    /// 65% 键盘上 F1–F12 由 Fn+数字行发出，给出对应提示
    static func fnHint(for label: String) -> String? {
        let row = ["F1": "1", "F2": "2", "F3": "3", "F4": "4", "F5": "5", "F6": "6",
                   "F7": "7", "F8": "8", "F9": "9", "F10": "0", "F11": "-", "F12": "="]
        return row[label].map { "Fn+\($0)" }
    }

    // MARK: 登录自启 / 权限

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("设置登录自启失败：\(error.localizedDescription)", error: true)
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    private var accessTimer: Timer?

    /// 授权流程第一步：清掉旧版本留下的失效记录，然后重启自己。
    /// 必须重启：系统只在进程首次申请时把应用登记进「输入监控」列表
    func requestInputMonitoring() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ListenEvent", Bundle.main.bundleIdentifier ?? "local.switchbar"]
        try? reset.run()
        reset.waitUntilExit()
        relaunch(extraArgs: ["--request-access"])
    }

    /// 授权流程第二步（重启后）：应用已在 start() 中登记进列表，这里打开设置页并等待授权
    func continueAccessRequest() {
        openInputMonitoringSettings()
        show("请在列表中打开 SwitchBar 的开关", error: false)
        accessTimer?.invalidate()
        var ticks = 0
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            ticks += 1
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
                t.invalidate()
                self?.relaunch()
            } else if ticks > 200 {
                t.invalidate()
            }
        }
    }

    private func relaunch(extraArgs: [String] = []) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath] + (extraArgs.isEmpty ? [] : ["--args"] + extraArgs)
        try? p.run()
        NSApp.terminate(nil)
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
