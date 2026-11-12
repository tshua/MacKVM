// 罗技 Easy-Switch 通道切换（HID++ 2.0，功能 0x1814 Change Host），无第三方依赖
// 用法: logi info        只读：列出设备、通道数、当前通道
//       logi host <n>    切到第 n 个通道（1 起）
import Foundation
import IOKit.hid

var lastReport: [UInt8] = []
var inputBuf = [UInt8](repeating: 0, count: 64)
let verbose = CommandLine.arguments.contains("-v")

func prop(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }

func send(_ d: IOHIDDevice, _ devIdx: UInt8, _ feat: UInt8, _ fn: UInt8, _ params: [UInt8]) -> IOReturn {
    var msg = [UInt8](repeating: 0, count: 20)
    msg[0] = 0x11; msg[1] = devIdx; msg[2] = feat; msg[3] = (fn << 4) | 0x0A
    for (i, p) in params.enumerated() { msg[4 + i] = p }
    return IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x11, msg, msg.count)
}

// 发请求并等待匹配的应答；返回应答参数（从第 5 字节起）
func request(_ d: IOHIDDevice, _ devIdx: UInt8, _ feat: UInt8, _ fn: UInt8, _ params: [UInt8]) -> [UInt8]? {
    lastReport = []
    let rc = send(d, devIdx, feat, fn, params)
    if rc != kIOReturnSuccess { if verbose { print("  写入失败 0x\(String(UInt32(bitPattern: rc), radix: 16))") }; return nil }
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
        let r = lastReport
        guard r.count >= 7 else { continue }
        if verbose { print("  收到: " + r.map { String(format: "%02x", $0) }.joined(separator: " ")) }
        if r[2] == feat && r[3] == ((fn << 4) | 0x0A) { return Array(r[4...]) }
        if r[2] == 0xFF && r[3] == feat { if verbose { print("  设备返回错误码 \(r[5])") }; return nil }
        lastReport = []
    }
    return nil
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
IOHIDManagerOpen(mgr, 0)
let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
guard !devs.isEmpty else { print("未找到罗技设备"); exit(1) }

let args = CommandLine.arguments.filter { $0 != "-v" }
let cmd = args.count > 1 ? args[1] : "info"
var done = false

for d in devs {
    let name = prop(d, kIOHIDProductKey) as? String ?? "?"
    let pairs = (prop(d, kIOHIDDeviceUsagePairsKey) as? [[String: Int]] ?? [])
        .map { String(format: "%04x:%04x", $0[kIOHIDDeviceUsagePageKey] ?? 0, $0[kIOHIDDeviceUsageKey] ?? 0) }
    if cmd == "info" {
        print("设备: \(name)  传输=\(prop(d, kIOHIDTransportKey) ?? "?")  用途=\(pairs.joined(separator: ","))  最大输出报告=\(prop(d, kIOHIDMaxOutputReportSizeKey) ?? "?")")
    }
    let orc = IOHIDDeviceOpen(d, 0)
    if orc != kIOReturnSuccess { print("  打开失败 0x\(String(UInt32(bitPattern: orc), radix: 16))（可能需要输入监控权限），继续尝试") }
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceRegisterInputReportCallback(d, &inputBuf, inputBuf.count, { _, _, _, _, id, rep, len in
        var r = Array(UnsafeBufferPointer(start: rep, count: len))
        if r.first != UInt8(truncatingIfNeeded: id) { r.insert(UInt8(truncatingIfNeeded: id), at: 0) }
        if r.first == 0x11 || r.first == 0x10 { lastReport = r }
    }, nil)

    for idx: UInt8 in [0xFF, 0x00, 0x01] {
        // Root.getFeature(0x1814) -> 功能索引
        guard let f = request(d, idx, 0x00, 0, [0x18, 0x14]), f[0] != 0 else { continue }
        let feat = f[0]
        guard let h = request(d, idx, feat, 0, []) else { continue }
        if cmd == "info" {
            print("  设备索引=0x\(String(idx, radix: 16)) ChangeHost功能索引=\(feat) 通道数=\(h[0]) 当前通道=\(h[1] + 1)")
        } else if cmd == "host", args.count > 2, let n = UInt8(args[2]), n >= 1, n <= h[0] {
            if h[1] + 1 == n { print("已在通道 \(n)") }
            else { let rc = send(d, idx, feat, 1, [n - 1]); print(rc == kIOReturnSuccess ? "已发送切换到通道 \(n)" : "发送失败") }
        } else { print("通道号无效（共 \(h[0]) 个）"); exit(1) }
        done = true
        break
    }
    IOHIDDeviceClose(d, 0)
    if done { break }
}
if !done { print("未能与鼠标完成 HID++ 通信"); exit(2) }
