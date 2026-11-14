import Cocoa
import ApplicationServices

// MARK: - 常量
let kRightCommand: Int64 = 54
let kHoldKey: Int64 = 49            // 空格（非修饰键，UU 场景下实测可触发）
let kSyntheticCtrl: CGKeyCode = 59
let kVKey: CGKeyCode = 9
let uuBundleID = "com.netease.uuremote"
let armDelay: Double = 0.35          // 按住多久才真正开录（防误触）
let clipboardWait: Double = 0.85     // 写剪贴板到发 Cmd+V 之间的等待
let uuActivateWait: Double = 0.45    // 激活 UU 到发 Cmd+V

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

    // MARK: 启动
    func applicationDidFinishLaunching(_ n: Notification) {
        src = CGEventSource(stateID: .hidSystemState)
        buildStatusItem()
        buildPanel()
        checkPermissions()
        installTap()
        log("VoiceBridge 已启动 · 按住空格键说话，松开自动粘贴到远端")
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
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "按住空格键说话", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打开辅助功能设置", action: #selector(openAXSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开输入监控设置", action: #selector(openIMSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openIMSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
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
        cap.stringValue = "按住空格键说话 · 松开自动粘贴"
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
            if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kHoldKey)) {
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
        if code == kHoldKey {
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return nil }
                if !holding && !busy {
                    holding = true
                    sawOtherKey = false
                    let work = DispatchWorkItem { [weak self] in
                        guard let self = self, self.holding, !self.sawOtherKey, !self.busy else { return }
                        self.startRecording()
                    }
                    pendingStart = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + armDelay, execute: work)
                }
                return nil
            }
            if type == .keyUp {
                if !recording {
                    holding = false
                    pendingStart?.cancel()
                    pendingStart = nil
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { sawOtherKey = true }
        return Unmanaged.passUnretained(event)
    }

    // MARK: 合成 Control（唤起豆包录音）
    func clearPhysicalModifiers() {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kRightCommand), keyDown: false) else { return }
        e.type = .flagsChanged
        e.flags = []
        e.post(tap: .cghidEventTap)
        log("[修饰] 已清除右⌘修饰状态")
    }

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

    func synthCtrl(_ down: Bool) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: kSyntheticCtrl, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = down ? [.maskControl] : []
        e.post(tap: .cghidEventTap)
        ctrlHeld = down
        log(down ? "[合成] Ctrl down → 豆包开始录音" : "[合成] Ctrl up → 豆包结束录音")
    }

    // MARK: 录音
    func startRecording() {
        guard !recording, !busy else { return }
        recording = true
        destroyTap()
        textView.string = ""
        caption.stringValue = "● 正在听… 说完松开空格键"
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
            self.synthCtrl(true)
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
        if ctrlHeld { synthCtrl(false) }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardWait) { [weak self] in
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
