// 显示器 DDC/CI 控制（Apple Silicon，经 IOAVService）
import Foundation
import IOKit

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ addr: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

enum DDC {
    static let inputSource: UInt8 = 0x60

    static func service() -> CFTypeRef? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue() { return av }
        }
        return nil
    }

    private static func write(_ av: CFTypeRef, _ payload: [UInt8]) -> Bool {
        var data = payload
        var chk: UInt8 = 0x6E ^ 0x51
        for b in data { chk ^= b }
        data.append(chk)
        var ok = false
        for _ in 0..<3 {
            usleep(10_000)
            if IOAVServiceWriteI2C(av, 0x37, 0x51, &data, UInt32(data.count)) == KERN_SUCCESS { ok = true }
        }
        return ok
    }

    static func get(_ vcp: UInt8) -> Int? {
        guard let av = service() else { return nil }
        for _ in 0..<4 {
            guard write(av, [0x82, 0x01, vcp]) else { continue }
            usleep(50_000)
            var r = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(av, 0x37, 0x51, &r, 12) == KERN_SUCCESS else { continue }
            if r[2] == 0x02 && r[3] == 0x00 && r[4] == vcp { return Int(r[8]) << 8 | Int(r[9]) }
        }
        return nil
    }

    static func set(_ vcp: UInt8, _ value: Int) -> Bool {
        guard let av = service() else { return false }
        return write(av, [0x84, 0x03, vcp, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    /// 读取能力字符串，解析出显示器支持的输入源取值，如 [15, 17]
    static func supportedInputs() -> [Int] {
        guard let av = service() else { return [] }
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
        let caps = String(decoding: out.filter { $0 != 0 }, as: UTF8.self)
        // 形如 "... 60(0F 11) ..."
        guard let r = caps.range(of: #"\b60\s*\(([0-9A-Fa-f ]+)\)"#, options: .regularExpression) else { return [] }
        let inner = caps[r].drop { $0 != "(" }.dropFirst().dropLast()
        return inner.split(separator: " ").compactMap { Int($0, radix: 16) }
    }

    static func inputName(_ v: Int) -> String {
        switch v {
        case 0x01: return "VGA 1"
        case 0x02: return "VGA 2"
        case 0x03: return "DVI 1"
        case 0x04: return "DVI 2"
        case 0x0F: return "DisplayPort 1"
        case 0x10: return "DisplayPort 2"
        case 0x11: return "HDMI 1"
        case 0x12: return "HDMI 2"
        case 0x1B: return "USB-C"
        default: return "输入 \(v)"
        }
    }
}
