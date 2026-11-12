// 菜单栏面板界面
import SwiftUI

// MARK: 小组件

struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: colors.last!.opacity(0.35), radius: 3, y: 1)
    }
}

struct Keycap: View {
    let text: String
    var onAccent = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(onAccent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(onAccent ? Color.white.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 0.5))
            .foregroundStyle(onAccent ? Color.white : Color.primary)
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

struct DeviceHeader: View {
    let symbol: String
    let colors: [Color]
    let name: String
    let status: String
    let ok: Bool
    var enabled: Binding<Bool>? = nil
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(ok: ok)
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let enabled {
                Toggle("", isOn: enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help("切换时是否包含此设备")
            }
        }
    }
}

/// 「本机 → 另一台」的一行
struct RouteRow<Trailing: View>: View {
    let thisValue: String
    @ViewBuilder var other: Trailing
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本机").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(thisValue).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text("另一台").font(.system(size: 10)).foregroundStyle(.secondary)
                other
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct SettingRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 6)
            trailing
        }
    }
}

// MARK: 面板

struct PanelView: View {
    @EnvironmentObject var s: AppState
    @AppStorage(Keys.targetInput) var targetInput = 0
    @AppStorage(Keys.thisInput) var thisInput = 0
    @AppStorage(Keys.targetHost) var targetHost = 0
    @AppStorage(Keys.thisHost) var thisHost = 0
    @AppStorage(Keys.switchDisplay) var switchDisplay = true
    @AppStorage(Keys.switchMouse) var switchMouse = true
    @AppStorage(Keys.kbToOther) var kbToOther = ""
    @AppStorage(Keys.kbToThis) var kbToThis = ""
    @AppStorage(Keys.hotKeyLabel) var hotKeyLabel = "F1"

    // 键盘组合键：留空时按通道号自动推导（通道 1/2/3 = Fn+Q/W/E）
    var kbOtherDefault: String { AppState.keyboardCombo(forChannel: targetHost) }
    var kbThisDefault: String { AppState.keyboardCombo(forChannel: s.mouseCurrent ?? thisHost) }
    var kbOtherShown: String { kbToOther.isEmpty ? kbOtherDefault : kbToOther }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            hero
            sectionTitle("设备")
            displayCard
            mouseCard
            keyboardCard
            sectionTitle("设置")
            settingsCard
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { s.refresh() }
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 2)
    }

    var header: some View {
        HStack {
            Text("设备切换").font(.system(size: 15, weight: .bold))
            Spacer()
            Button { s.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("重新读取设备状态")
        }
        .padding(.horizontal, 4)
    }

    var includedText: String {
        let parts = [switchDisplay ? "显示器" : nil, switchMouse ? "鼠标" : nil].compactMap { $0 }
        return parts.isEmpty ? "未选择任何设备" : parts.joined(separator: " + ")
    }

    var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { s.switchNow() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.2)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("切换到另一台 Mac").font(.system(size: 14, weight: .semibold))
                        Text(includedText).font(.system(size: 11)).opacity(0.85)
                    }
                    Spacer()
                    if s.switching { ProgressView().controlSize(.small).tint(.white) }
                    else { Keycap(text: hotKeyLabel, onAccent: true) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.52, blue: 1.0), Color(red: 0.36, green: 0.34, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: Color(red: 0.33, green: 0.4, blue: 1).opacity(0.35), radius: 8, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(s.switching)

            HStack(spacing: 5) {
                Image(systemName: "keyboard").font(.system(size: 10))
                Text("键盘无法由软件切换，之后请再按")
                Keycap(text: kbOtherShown)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4)
        }
    }

    var displayCard: some View {
        Card {
            DeviceHeader(symbol: "display", colors: [Color(red: 0.35, green: 0.68, blue: 1), Color(red: 0.1, green: 0.48, blue: 0.96)],
                         name: s.displayName ?? "外接显示器",
                         status: s.displayName == nil ? "未检测到" : (s.displayCurrent == nil ? "DDC 无响应" : "DDC/CI 已连接"),
                         ok: s.displayCurrent != nil, enabled: $switchDisplay)
            RouteRow(thisValue: (s.displayCurrent ?? (thisInput > 0 ? thisInput : nil)).map(DDC.inputName) ?? "—") {
                if s.displayInputs.isEmpty {
                    Text("—").font(.system(size: 12, weight: .medium))
                } else {
                    Picker("", selection: $targetInput) {
                        ForEach(s.displayInputs, id: \.self) { Text(DDC.inputName($0)).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
            }
        }
    }

    var mouseCard: some View {
        Card {
            DeviceHeader(symbol: "computermouse.fill", colors: [Color(red: 0.72, green: 0.5, blue: 1), Color(red: 0.5, green: 0.3, blue: 0.92)],
                         name: s.mouseName ?? "罗技鼠标", status: s.mouseStatus, ok: s.mouseCurrent != nil, enabled: $switchMouse)
            RouteRow(thisValue: (s.mouseCurrent ?? (thisHost > 0 ? thisHost : nil)).map { "Easy-Switch 通道 \($0)" } ?? "—") {
                Picker("", selection: $targetHost) {
                    ForEach(1...max(s.mouseHosts, 1), id: \.self) { Text("通道 \($0)").tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
        }
    }

    var keyboardCard: some View {
        Card {
            DeviceHeader(symbol: "keyboard.fill", colors: [Color(red: 1, green: 0.72, blue: 0.3), Color(red: 0.98, green: 0.5, blue: 0.15)],
                         name: s.keyboardName ?? "键盘", status: s.keyboardName == nil ? "未连接本机 · 手动切换" : "已连接本机 · 手动切换",
                         ok: s.keyboardName != nil)
            HStack(spacing: 8) {
                comboField("去另一台", text: $kbToOther, placeholder: kbOtherDefault)
                comboField("回本机", text: $kbToThis, placeholder: kbThisDefault)
            }
        }
    }

    func comboField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    var hotKeyDetail: String {
        if !s.hotKeyOK { return "注册失败，可能被其他程序占用" }
        if let hint = AppState.fnHint(for: hotKeyLabel) { return "紧凑键盘上按 \(hint)；点击右侧可重新录制" }
        return "全局生效；点击右侧可重新录制"
    }

    var settingsCard: some View {
        Card {
            SettingRow(symbol: "command", title: "切换快捷键", detail: hotKeyDetail) {
                Button { s.toggleRecording() } label: {
                    Keycap(text: s.recording ? "请按键… Esc 取消" : hotKeyLabel)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: s.recording ? 1.5 : 0))
                }
                .buttonStyle(.plain)
            }
            Divider().opacity(0.5)
            SettingRow(symbol: "power", title: "登录时自动启动") {
                Toggle("", isOn: Binding(get: { s.loginItem }, set: { s.setLoginItem($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            Divider().opacity(0.5)
            SettingRow(symbol: "lock.shield", title: "输入监控权限", detail: s.hidAccess ? "已授权，可控制鼠标" : "控制鼠标需要此权限") {
                if s.hidAccess {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                } else {
                    Button("去授权") { s.requestInputMonitoring() }.controlSize(.small)
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 6) {
            if !s.message.isEmpty {
                Image(systemName: s.messageIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(s.messageIsError ? Color.orange : Color.secondary).font(.system(size: 10))
                Text(s.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
