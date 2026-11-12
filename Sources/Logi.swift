// 罗技 Easy-Switch 通道切换（HID++ 2.0，功能 0x1814 Change Host）
// 蓝牙直连已验证；经 USB 接收器（Bolt/Unifying）的路径按协议实现，尚未实机验证
import Foundation
import IOKit.hid

private var logiLastReport: [UInt8] = []
private var logiInputBuf = [UInt8](repeating: 0, count: 64)

enum LogiError: Error {
    case notFound, noPermission, noResponse
    var text: String {
        switch self {
        case .notFound: return "未连接本机"
        case .noPermission: return "需要输入监控权限"
        case .noResponse: return "已连接，但未响应切换协议"
        }
    }
}

struct LogiInfo { let name: String; let hosts: Int; let current: Int }  // current 从 1 起

enum Logi {
    private static func send(_ d: IOHIDDevice, _ idx: UInt8, _ feat: UInt8, _ fn: UInt8, _ params: [UInt8]) -> Bool {
        var msg = [UInt8](repeating: 0, count: 20)
        msg[0] = 0x11; msg[1] = idx; msg[2] = feat; msg[3] = (fn << 4) | 0x0A
        for (i, p) in params.enumerated() { msg[4 + i] = p }
        return IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x11, msg, msg.count) == kIOReturnSuccess
    }

    private static func request(_ d: IOHIDDevice, _ idx: UInt8, _ feat: UInt8, _ fn: UInt8, _ params: [UInt8]) -> [UInt8]? {
        logiLastReport = []
        guard send(d, idx, feat, fn, params) else { return nil }
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.03, true)
            let r = logiLastReport
            guard r.count >= 7 else { continue }
            if r[1] == idx && r[2] == feat && r[3] == ((fn << 4) | 0x0A) { return Array(r[4...]) }
            if r[1] == idx && r[2] == 0xFF && r[3] == feat { return nil }
            logiLastReport = []
        }
        return nil
    }

    /// 找到支持 Change Host 的设备并执行 body；必须在同一线程内完成
    private static func withMouse<T>(_ body: (_ d: IOHIDDevice, _ idx: UInt8, _ feat: UInt8, _ info: LogiInfo) -> T) -> Result<T, LogiError> {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        IOHIDManagerOpen(mgr, 0)
        defer { IOHIDManagerClose(mgr, 0) }
        let all = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        // 只保留带 HID++ 私有接口的设备：蓝牙直连为 0xFF43，USB 接收器为 0xFF00
        let devs = all.filter { d in
            let pairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] ?? []
            return pairs.contains { ($0[kIOHIDDeviceUsagePageKey] ?? 0) == 0xFF43 || ($0[kIOHIDDeviceUsagePageKey] ?? 0) == 0xFF00 }
        }
        guard !devs.isEmpty else { return .failure(.notFound) }
        var err = LogiError.noResponse
        for d in devs {
            let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? ""
            let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "罗技设备"
            guard IOHIDDeviceOpen(d, 0) == kIOReturnSuccess else { err = .noPermission; continue }
            defer { IOHIDDeviceClose(d, 0) }
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            defer { IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }
            IOHIDDeviceRegisterInputReportCallback(d, &logiInputBuf, logiInputBuf.count, { _, _, _, _, id, rep, len in
                var r = Array(UnsafeBufferPointer(start: rep, count: len))
                if r.first != UInt8(truncatingIfNeeded: id) { r.insert(UInt8(truncatingIfNeeded: id), at: 0) }
                if r.first == 0x11 { logiLastReport = r }
            }, nil)
            let indices: [UInt8] = transport.contains("Bluetooth") ? [0xFF, 0x00] : [1, 2, 3, 4, 5, 6, 0xFF]
            for idx in indices {
                guard let f = request(d, idx, 0x00, 0, [0x18, 0x14]), f[0] != 0,
                      let h = request(d, idx, f[0], 0, []), h[0] > 0 else { continue }
                return .success(body(d, idx, f[0], LogiInfo(name: name, hosts: Int(h[0]), current: Int(h[1]) + 1)))
            }
        }
        return .failure(err)
    }

    static func info() -> Result<LogiInfo, LogiError> {
        withMouse { _, _, _, info in info }
    }

    /// 切到第 n 个通道（1 起）。成功返回 nil，失败返回原因
    static func setHost(_ n: Int) -> String? {
        let r: Result<String?, LogiError> = withMouse { d, idx, feat, info in
            guard n >= 1, n <= info.hosts else { return "通道 \(n) 超出范围" }
            if info.current == n { return nil }
            return send(d, idx, feat, 1, [UInt8(n - 1)]) ? nil : "指令发送失败"
        }
        switch r {
        case .success(let msg): return msg
        case .failure(let e): return e.text
        }
    }
}
