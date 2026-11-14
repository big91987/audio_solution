import Cocoa
import ApplicationServices

// MARK: - 配置（默认值 = 实测可用组合；改 ~/.voicebridge/config.json 后重启生效）
struct VBConfig: Codable {
    var triggerKeyCode: Int64   // 触发 VoiceBridge 的键（默认 49 = 空格）
    var doubaoKeyCode: Int64    // 唤起豆包语音的键（默认 59 = 左侧 Control）
    var armDelay: Double        // 按住多久才开录（防误触）
    var clipboardWait: Double   // 写剪贴板到按 Cmd+V 的等待（留 UU 同步时间）

    static let `default` = VBConfig(triggerKeyCode: 49, doubaoKeyCode: 59,
                                    armDelay: 0.35, clipboardWait: 0.85)
}

let vbConfigDir = NSHomeDirectory() + "/.voicebridge"
let vbConfigPath = vbConfigDir + "/config.yaml"

// 运行期可改：菜单里点选后立即写入 YAML 并生效；手改 YAML 后 1 秒内自动重载
var cfg: VBConfig = VBConfig.default

// 菜单里可选的值
let triggerOptions: [Int64] = [49, 48, 36, 53, 41, 43, 47, 50, 105, 54, 56]
let doubaoOptions:  [Int64] = [59, 62, 58, 61, 105, 96, 97, 98, 100, 101]
let armOptions:     [Int]   = [200, 300, 350, 500, 800]

func saveConfig() {
    let text = """
    # VoiceBridge 配置（改完保存，1 秒内自动重载；菜单里的设置也写进这个文件）
    # 常用键码：
    #   49=空格  48=Tab  36=回车  53=Esc  41=分号  43=逗号  47=句号  50=反引号
    #   59=左Control  62=右Control  58=左Option  61=右Option  54=右Command  55=左Command  56=左Shift
    #   105=F13  103=F11  111=F12  96=F5  97=F6  98=F7  100=F8  101=F9
    triggerKeyCode: \(cfg.triggerKeyCode)
    doubaoKeyCode: \(cfg.doubaoKeyCode)
    armDelay: \(cfg.armDelay)
    clipboardWait: \(cfg.clipboardWait)

    """
    try? FileManager.default.createDirectory(atPath: vbConfigDir, withIntermediateDirectories: true)
    try? text.write(toFile: vbConfigPath, atomically: true, encoding: .utf8)
}

func loadConfig() -> VBConfig {
    var c = VBConfig.default
    try? FileManager.default.createDirectory(atPath: vbConfigDir, withIntermediateDirectories: true)
    guard let text = try? String(contentsOfFile: vbConfigPath, encoding: .utf8) else {
        saveConfig()
        return c
    }
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = line.split(separator: ":")
        guard parts.count >= 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let val = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "triggerKeyCode": if let v = Int64(val) { c.triggerKeyCode = v }
        case "doubaoKeyCode":  if let v = Int64(val) { c.doubaoKeyCode = v }
        case "armDelay":       if let v = Double(val) { c.armDelay = v }
        case "clipboardWait":  if let v = Double(val) { c.clipboardWait = v }
        default: break
        }
    }
    return c
}

let kVKey: CGKeyCode = 9
let uuBundleID = "com.netease.uuremote"
let uuActivateWait: Double = 0.45

// 修饰键 → CGEventFlags（既用于合成豆包快捷键，也用于识别修饰键型触发键）
let modifierFlags: [Int64: CGEventFlags] = [
    54: .maskCommand,   55: .maskCommand,
    56: .maskShift,     60: .maskShift,
    58: .maskAlternate, 61: .maskAlternate,
    59: .maskControl,   62: .maskControl,
]

func keyName(_ code: Int64) -> String {
    switch code {
    case 49: return "空格"
    case 36: return "回车"
    case 48: return "Tab"
    case 53: return "Esc"
    case 51: return "Delete"
    case 54: return "右侧 Command"
    case 55: return "左侧 Command"
    case 56: return "左侧 Shift"
    case 60: return "右侧 Shift"
    case 58: return "左侧 Option"
    case 61: return "右侧 Option"
    case 59: return "左侧 Control"
    case 62: return "右侧 Control"
    case 41: return "分号"
    case 43: return "逗号"
    case 47: return "句号"
    case 42: return "反斜杠"
    case 50: return "反引号"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    case 105: return "F13"
    default: return "键码\(code)"
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Bridge: NSObject, NSApplicationDelegate {
    var panel: KeyPanel!
    var textView: NSTextView!
    var caption: NSTextField!
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var src: CGEventSource!

    var holding = false
    var recording = false
    var busy = false
    var sawOtherKey = false
    var pendingStart: DispatchWorkItem?
    var ctrlHeld = false
    var tapEnabled = false
    var tapSource: CFRunLoopSource?
    var pollTimer: Timer?
    var configTimer: Timer?
    var lastConfigMTime = Date.distantPast

    // MARK: 启动
    func applicationDidFinishLaunching(_ n: Notification) {
        cfg = loadConfig()
        lastConfigMTime = ((try? FileManager.default.attributesOfItem(atPath: vbConfigPath))?[.modificationDate] as? Date) ?? Date()
        src = CGEventSource(stateID: .hidSystemState)
        buildStatusItem()
        buildPanel()
        checkPermissions()
        installTap()
        startConfigWatcher()
        log("VoiceBridge 已启动 · 按住\(keyName(cfg.triggerKeyCode))说话，唤起豆包用 \(keyName(cfg.doubaoKeyCode)) · 松开自动粘贴到远端")
    }

    func startConfigWatcher() {
        configTimer?.invalidate()
        configTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let m = ((try? FileManager.default.attributesOfItem(atPath: vbConfigPath))?[.modificationDate] as? Date) ?? Date.distantPast
            if m != self.lastConfigMTime {
                self.lastConfigMTime = m
                let old = cfg
                cfg = loadConfig()
                if old.triggerKeyCode != cfg.triggerKeyCode || old.doubaoKeyCode != cfg.doubaoKeyCode
                    || old.armDelay != cfg.armDelay || old.clipboardWait != cfg.clipboardWait {
                    self.rebuildMenu()
                    self.caption.stringValue = "按住\(keyName(cfg.triggerKeyCode))说话 · 松开自动粘贴"
                    self.log("[配置] 文件已变更并重载：触发=\(keyName(cfg.triggerKeyCode)) 豆包=\(keyName(cfg.doubaoKeyCode)) 按住=\(cfg.armDelay)s")
                }
            }
        }
    }

    func log(_ s: String) {
        print(s)
        fflush(stdout)
    }

    // MARK: 权限
    func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        log("辅助功能权限: \(trusted ? "已授权" : "未授权")")
        if !trusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        let listen = CGPreflightListenEventAccess()
        log("输入监控权限: \(listen ? "已授权" : "未授权")")
        if !listen {
            _ = CGRequestListenEventAccess()
        }
    }

    // MARK: 菜单栏
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let head = NSMenuItem(title: "按住\(keyName(cfg.triggerKeyCode))说话 · 唤起豆包用 \(keyName(cfg.doubaoKeyCode))", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(NSMenuItem.separator())

        // 触发键
        let trig = NSMenuItem(title: "触发键：\(keyName(cfg.triggerKeyCode))", action: nil, keyEquivalent: "")
        let trigSub = NSMenu()
        for k in triggerOptions {
            let it = NSMenuItem(title: keyName(k), action: #selector(setTriggerKey(_:)), keyEquivalent: "")
            it.tag = Int(k)
            it.target = self
            it.state = Int(k) == Int(cfg.triggerKeyCode) ? .on : .off
            trigSub.addItem(it)
        }
        trig.submenu = trigSub
        menu.addItem(trig)

        // 唤起豆包的键
        let db = NSMenuItem(title: "唤起豆包的键：\(keyName(cfg.doubaoKeyCode))", action: nil, keyEquivalent: "")
        let dbSub = NSMenu()
        for k in doubaoOptions {
            let it = NSMenuItem(title: keyName(k), action: #selector(setDoubaoKey(_:)), keyEquivalent: "")
            it.tag = Int(k)
            it.target = self
            it.state = Int(k) == Int(cfg.doubaoKeyCode) ? .on : .off
            dbSub.addItem(it)
        }
        db.submenu = dbSub
        menu.addItem(db)

        // 按住时长
        let armMs = Int((cfg.armDelay * 1000).rounded())
        let arm = NSMenuItem(title: "按住时长：\(armMs) ms", action: nil, keyEquivalent: "")
        let armSub = NSMenu()
        for ms in armOptions {
            let it = NSMenuItem(title: "\(ms) ms", action: #selector(setArmDelay(_:)), keyEquivalent: "")
            it.tag = ms
            it.target = self
            it.state = armMs == ms ? .on : .off
            armSub.addItem(it)
        }
        arm.submenu = armSub
        menu.addItem(arm)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打开配置文件", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打开辅助功能设置", action: #selector(openAXSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开输入监控设置", action: #selector(openIMSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func setTriggerKey(_ sender: NSMenuItem) {
        cfg.triggerKeyCode = Int64(sender.tag)
        saveConfig()
        rebuildMenu()
        caption.stringValue = "按住\(keyName(cfg.triggerKeyCode))说话 · 松开自动粘贴"
        log("[配置] 触发键 → \(keyName(cfg.triggerKeyCode))（键码 \(sender.tag)）")
    }

    @objc func setDoubaoKey(_ sender: NSMenuItem) {
        cfg.doubaoKeyCode = Int64(sender.tag)
        saveConfig()
        rebuildMenu()
        log("[配置] 唤起豆包的键 → \(keyName(cfg.doubaoKeyCode))（键码 \(sender.tag)）")
    }

    @objc func setArmDelay(_ sender: NSMenuItem) {
        cfg.armDelay = Double(sender.tag) / 1000.0
        saveConfig()
        rebuildMenu()
        log("[配置] 按住时长 → \(sender.tag) ms")
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openIMSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func openConfig() { NSWorkspace.shared.open(URL(fileURLWithPath: vbConfigPath)) }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: 浮窗
    func buildPanel() {
        let w: CGFloat = 780, h: CGFloat = 150
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor

        let scroll = NSScrollView(frame: NSRect(x: 22, y: 46, width: w - 44, height: h - 66))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder

        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.font = NSFont.systemFont(ofSize: 20)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.drawsBackground = false
        tv.isRichText = false
        scroll.documentView = tv
        textView = tv
        container.addSubview(scroll)

        let cap = NSTextField(frame: NSRect(x: 24, y: 14, width: w - 48, height: 22))
        cap.isEditable = false
        cap.isBordered = false
        cap.drawsBackground = false
        cap.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        cap.font = NSFont.systemFont(ofSize: 12)
        cap.stringValue = "按住\(keyName(cfg.triggerKeyCode))说话 · 松开自动粘贴"
        caption = cap
        container.addSubview(cap)

        panel.contentView = container
    }

    func panelOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        let w = panel.frame.width
        return NSPoint(x: f.midX - w / 2, y: f.minY + 40)
    }

    // MARK: 事件监听
    func installTap() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let b = Unmanaged<Bridge>.fromOpaque(refcon).takeUnretainedValue()
            return b.handle(proxy: proxy, type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("!! 事件监听创建失败：请在系统设置 → 隐私与安全性 → 输入监控 里授权本 App")
            return
        }
        tap = t
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        tapSource = source
        CGEvent.tapEnable(tap: t, enable: true)
        tapEnabled = true
        log("事件监听已安装")
    }

    func destroyTap() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
            CFMachPortInvalidate(t)
        }
        tap = nil
        tapSource = nil
        tapEnabled = false
        log("[tap] 已销毁")
    }

    func setTap(_ on: Bool) {
        guard let tap = tap, tapEnabled != on else { return }
        CGEvent.tapEnable(tap: tap, enable: on)
        tapEnabled = on
        log("[tap] \(on ? "开启" : "关闭")")
    }

    func startPollingRelease() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(cfg.triggerKeyCode)) {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.holding = false
                self.log("[轮询] 触发键已松开")
                self.stopRecording()
            }
        }
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == cfg.triggerKeyCode {
            // 修饰键型触发键（如右侧 Command）：走 flagsChanged，且不吞事件，以免破坏其它组合键
            if type == .flagsChanged, let flag = modifierFlags[code] {
                if event.flags.contains(flag) { beginHold() } else { cancelPendingStart() }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return nil }
                beginHold()
                return nil
            }
            if type == .keyUp {
                cancelPendingStart()
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { sawOtherKey = true }
        return Unmanaged.passUnretained(event)
    }

    func beginHold() {
        guard !holding && !busy else { return }
        holding = true
        sawOtherKey = false
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.holding, !self.sawOtherKey, !self.busy else { return }
            self.startRecording()
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.armDelay, execute: work)
    }

    func cancelPendingStart() {
        if !recording {
            holding = false
            pendingStart?.cancel()
            pendingStart = nil
        }
    }

    // MARK: 合成豆包快捷键（唤起录音）
    func doubaoBarVisible() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let wd = (b["Width"] as? Double) ?? 0
            let ht = (b["Height"] as? Double) ?? 0
            if owner.contains("豆包输入法") { return true }
            if owner.lowercased().contains("doubao") && wd > 80 && wd < 260 && ht > 20 && ht < 70 { return true }
        }
        return false
    }

    func synthDoubao(_ down: Bool) {
        let kc = CGKeyCode(cfg.doubaoKeyCode)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: down) else { return }
        if let flag = modifierFlags[cfg.doubaoKeyCode] {
            // 修饰键：发 flagsChanged，只带这一个修饰位（清掉其它修饰，避免继承物理状态）
            e.type = .flagsChanged
            e.flags = down ? flag : []
        } else {
            // 普通键：发 keyDown / keyUp
            e.type = down ? .keyDown : .keyUp
            e.flags = []
        }
        e.post(tap: .cghidEventTap)
        ctrlHeld = down
        log(down ? "[合成] \(keyName(cfg.doubaoKeyCode)) down → 豆包开始录音"
                 : "[合成] \(keyName(cfg.doubaoKeyCode)) up → 豆包结束录音")
    }

    // MARK: 录音
    func startRecording() {
        guard !recording, !busy else { return }
        recording = true
        destroyTap()
        textView.string = ""
        caption.stringValue = "● 正在听… 说完松开\(keyName(cfg.triggerKeyCode))"
        panel.setFrameOrigin(panelOrigin())
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        log("[开始] 浮窗已抢焦点")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.recording else { return }
            self.log("[诊断] isKey=\(self.panel.isKeyWindow) appActive=\(NSApp.isActive) first=\(type(of: self.panel.firstResponder ?? NSView()))")
            self.synthDoubao(true)
            self.startPollingRelease()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self = self else { return }
                self.log("[诊断] 豆包录音条: \(self.doubaoBarVisible() ? "已出现" : "没出现")")
            }
        }
    }

    func stopRecording() {
        guard recording else { return }
        recording = false
        busy = true
        pollTimer?.invalidate()
        pollTimer = nil
        if ctrlHeld { synthDoubao(false) }
        caption.stringValue = "转写中…"
        log("[结束] 等待豆包出字")
        waitStable { [weak self] text in
            self?.finish(text)
        }
    }

    func waitStable(_ done: @escaping (String) -> Void) {
        var last = ""
        var stable = 0
        var ticks = 0
        func tick() {
            ticks += 1
            let s = textView.string
            if s != last {
                last = s
                stable = 0
            } else {
                stable += 1
            }
            let stableEnough = stable >= 4 && !s.isEmpty
            let tooLong = ticks > 28   // ~7s
            if stableEnough || tooLong {
                done(s)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
    }

    func finish(_ text: String) {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 按住分号期间键盘自动重复，会往浮窗里灌一串分号，剥掉开头和结尾的标点
        while let f = clean.first, "；;，,。.、 ".contains(f) { clean.removeFirst() }
        while let l = clean.last, "；;，,。.、 ".contains(l) { clean.removeLast() }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        log("[文本] \(clean.isEmpty ? "(空)" : clean)")
        guard !clean.isEmpty else {
            hidePanel()
            busy = false
            installTap()
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clean, forType: .string)
        log("[剪贴板] 已写入 \(clean.count) 字")
        hidePanel()
        activateUU()
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.clipboardWait) { [weak self] in
            self?.sendCmdV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.busy = false
                self?.installTap()
            }
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    func activateUU() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: uuBundleID)
        if let app = apps.first {
            app.activate(options: [.activateAllWindows])
            log("[UU] 已激活")
        } else {
            log("!! 没找到 UU 远程进程")
        }
    }

    func sendCmdV() {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: kVKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: kVKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(30000)
        up.post(tap: .cghidEventTap)
        log("[粘贴] 已发送 Cmd+V")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let bridge = Bridge()
app.delegate = bridge
app.run()
