// 极简 DDC/CI 工具（Apple Silicon），无第三方依赖
// 用法: ddc get <vcp十六进制>      例: ddc get 60
//       ddc set <vcp十六进制> <值>  例: ddc set 60 17
//       ddc toggle <值A> <值B>      在两个输入源之间切换
import Foundation
import IOKit

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ addr: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

func externalAVService() -> CFTypeRef? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let s = IOIteratorNext(iter), s != 0 {
        defer { IOObjectRelease(s) }
        let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue() {
            return av
        }
    }
    return nil
}

func write(_ av: CFTypeRef, _ payload: [UInt8]) -> Bool {
    var data = payload
    var chk: UInt8 = 0x6E ^ 0x51
    for b in data { chk ^= b }
    data.append(chk)
    var ok = false
    for _ in 0..<3 {  // 多写几次提高可靠性
        usleep(10_000)
        if IOAVServiceWriteI2C(av, 0x37, 0x51, &data, UInt32(data.count)) == KERN_SUCCESS { ok = true }
    }
    return ok
}

func getVCP(_ av: CFTypeRef, _ vcp: UInt8) -> (cur: Int, max: Int)? {
    for _ in 0..<5 {
        guard write(av, [0x82, 0x01, vcp]) else { continue }
        usleep(50_000)
        var r = [UInt8](repeating: 0, count: 12)
        guard IOAVServiceReadI2C(av, 0x37, 0x51, &r, 12) == KERN_SUCCESS else { continue }
        if r[2] == 0x02 && r[3] == 0x00 && r[4] == vcp {
            return (Int(r[8]) << 8 | Int(r[9]), Int(r[6]) << 8 | Int(r[7]))
        }
    }
    return nil
}

func setVCP(_ av: CFTypeRef, _ vcp: UInt8, _ value: UInt16) -> Bool {
    write(av, [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
}

func capabilities(_ av: CFTypeRef) -> String {
    var out = [UInt8](), off = 0
    while off < 4096 {
        var chunk: [UInt8]? = nil
        for _ in 0..<5 {
            guard write(av, [0x83, 0xF3, UInt8(off >> 8), UInt8(off & 0xFF)]) else { continue }
            usleep(60_000)
            var r = [UInt8](repeating: 0, count: 40)
            guard IOAVServiceReadI2C(av, 0x37, 0x51, &r, 40) == KERN_SUCCESS else { continue }
            let len = Int(r[1] & 0x7F)
            if r[2] == 0xE3, len >= 3, len <= 35, Int(r[3]) << 8 | Int(r[4]) == off {
                chunk = Array(r[5..<(2 + len)]); break
            }
        }
        guard let c = chunk, !c.isEmpty else { break }
        out += c; off += c.count
    }
    return String(decoding: out.filter { $0 != 0 }, as: UTF8.self)
}

let a = CommandLine.arguments
if a.count >= 2, a[1] == "caps", let av = externalAVService() { print(capabilities(av)); exit(0) }
guard a.count >= 3,let av = externalAVService() else {
    FileHandle.standardError.write("用法: ddc get <vcp> | set <vcp> <值> | toggle <值A> <值B>；或未找到外接显示器\n".data(using: .utf8)!)
    exit(1)
}
switch a[1] {
case "get":
    guard let v = UInt8(a[2], radix: 16), let r = getVCP(av, v) else { print("读取失败"); exit(2) }
    print("VCP 0x\(a[2]) 当前=\(r.cur) (0x\(String(r.cur, radix: 16))) 最大=\(r.max)")
case "set":
    guard a.count >= 4, let v = UInt8(a[2], radix: 16), let val = UInt16(a[3]) else { exit(1) }
    exit(setVCP(av, v, val) ? 0 : 2)
case "toggle":
    guard a.count >= 4, let x = UInt16(a[2]), let y = UInt16(a[3]) else { exit(1) }
    let cur = getVCP(av, 0x60).map { UInt16($0.cur & 0xFF) }
    exit(setVCP(av, 0x60, cur == x ? y : x) ? 0 : 2)
default:
    exit(1)
}
