import AppKit
import ServiceManagement

/// Menu bar UI: status, connection info, quality, permissions.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let host = HostController()
    private var statusItem: NSStatusItem!
    private var state: HostController.State = .idle
    private var serverError: String?
    private var relayState: RelayClient.State = .offline
    private var relayViewerStale = false
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillTerminate(_ notification: Notification) {
        SpeakerMute.restore()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the menu at the mouse, since the
    /// menu bar icon can end up hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LoginAgent.handOverIfNeeded() { exit(0) }
        // Undo a mute left behind by a crash, unless another instance (e.g. a test host on other
        // ports) is running and may own that mute.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if others.isEmpty { SpeakerMute.restore() }
        // `pkill`/logout send SIGTERM, which skips applicationWillTerminate: unmute first.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler {
            SpeakerMute.restore()
            exit(0)
        }
        termination.resume()
        terminationSignal = termination

        host.onRelayStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.relayState = state }
        }
        host.onRelayViewerStale = { [weak self] stale in
            DispatchQueue.main.async { self?.relayViewerStale = stale }
        }
        host.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.state = state
                self?.updateIcon()
            }
        }
        do {
            try host.start()
        } catch {
            // Already running (e.g. opened by hand while the login agent had started it): leave
            // that copy alone. A clean exit, so the agent doesn't start this one over and over.
            if (error as NSError).code == Int(EADDRINUSE), !others.isEmpty {
                hostLog("[app] another Jump Host is already running; quitting this copy")
                others.first?.activate()
                exit(0)
            }
            serverError = error.localizedDescription
            hostLog("[app] server failed: \(error)")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        hostLog("[app] Jump Host \(version) started\(LoginAgent.isCurrentProcess ? " by the login agent" : "")"
                + " — screen recording \(Permissions.screenRecording ? "ok" : "MISSING"),"
                + " accessibility \(Permissions.accessibility ? "ok" : "MISSING")")
        _ = HostConfig.shared.password  // create one on first launch so the menu and clients agree
        Permissions.requestMissing()
        LoginAgent.apply()
        // Just registered: from now on launchd runs it.
        if LoginAgent.handOverIfNeeded() { exit(0) }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch state {
        case .idle: menu.addItem(label("● 대기 중"))
        case .connecting(let device): menu.addItem(label("◐ 연결 중: \(device)"))
        case .connected(let device): menu.addItem(label("● 연결됨: \(device)"))
        }
        if let serverError { menu.addItem(label("서버 오류: \(serverError)")) }

        menu.addItem(.separator())
        menu.addItem(label("접속 주소 — 브라우저에서 열기, 클릭하면 복사"))
        let addresses = NetworkInfo.addresses()
        if addresses.isEmpty { menu.addItem(label("   네트워크 없음")) }
        for address in addresses {
            let tag = address.isTailscale ? "Tailscale" : address.interface
            let url = "http://\(address.ip):\(HostConfig.shared.webPort)"
            menu.addItem(action("   \(url)   (\(tag))", #selector(copyText(_:)), represented: url))
        }

        menu.addItem(.separator())
        if let link = HostConfig.shared.relayViewerLink {
            let status = switch relayState {
            case .online: "연결됨"
            case .connecting: "연결 중…"
            case .offline: "오프라인"
            case .rejected: "거부됨"
            }
            menu.addItem(label("어디서나 접속 (중개 서버 \(status))"))
            menu.addItem(action("   \(link)  — 클릭해서 복사", #selector(copyText(_:)), represented: link))
            if case .rejected(let why) = relayState {
                menu.addItem(label("   ⚠︎ \(why) — '중개 서버 만들기'를 다시 실행하세요"))
            }
            if relayViewerStale {
                menu.addItem(label("   ⚠︎ 중개 서버의 화면이 이 Mac과 다른 버전 — '중개 서버 만들기'를 다시 실행하세요"))
            }
        } else {
            menu.addItem(label("어디서나 접속: 꺼짐 — 밖에서는 Tailscale 주소로 접속"))
        }
        menu.addItem(action("중개 서버 주소 설정…", #selector(chooseRelay)))
        let turnGB = HostConfig.shared.turnBytesThisMonth / 1e9
        menu.addItem(label(String(format: "이번 달 TURN 우회: %.1f GB / 무료 1,000 GB", turnGB)))

        menu.addItem(.separator())
        // Hidden unless ⌥ is held: the menu is often open on a shared or recorded screen.
        let password = HostConfig.shared.password
        menu.addItem(action("비밀번호: ••••••••  — 클릭해서 복사 (⌥ 누르면 보기)", #selector(copyText(_:)), represented: password))
        let shown = action("비밀번호: \(password)  — 클릭해서 복사", #selector(copyText(_:)), represented: password)
        shown.keyEquivalentModifierMask = .option
        shown.isAlternate = true
        menu.addItem(shown)
        if password.count < 8 {
            menu.addItem(label("   ⚠︎ 비밀번호가 \(password.count)자로 짧습니다. 인터넷에 열려 있으니 8자 이상으로 바꾸세요"))
        }
        menu.addItem(action("비밀번호 새로 만들기", #selector(regeneratePassword)))
        menu.addItem(action("비밀번호 직접 설정…", #selector(choosePassword)))

        menu.addItem(.separator())
        let qualityItem = NSMenuItem(title: "화질", action: nil, keyEquivalent: "")
        let qualityMenu = NSMenu()
        for quality in HostConfig.Quality.allCases {
            let item = action(quality.title, #selector(selectQuality(_:)), represented: quality.rawValue)
            item.state = quality == HostConfig.shared.quality ? .on : .off
            qualityMenu.addItem(item)
        }
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)
        let hevcItem = action("HEVC 사용 (지원 기기)", #selector(toggleHEVC))
        hevcItem.state = HostConfig.shared.useHEVC ? .on : .off
        menu.addItem(hevcItem)
        let audioItem = action("소리 전송", #selector(toggleAudio))
        audioItem.state = HostConfig.shared.sendAudio ? .on : .off
        menu.addItem(audioItem)
        let clipboardItem = action("클립보드 공유", #selector(toggleClipboard))
        clipboardItem.state = HostConfig.shared.shareClipboard ? .on : .off
        menu.addItem(clipboardItem)
        let muteItem = action("연결 중 Mac 소리 끄기", #selector(toggleMute))
        muteItem.state = HostConfig.shared.muteMacWhileConnected ? .on : .off
        muteItem.isEnabled = HostConfig.shared.sendAudio
        menu.addItem(muteItem)

        menu.addItem(.separator())
        menu.addItem(action("화면 기록 권한: \(Permissions.screenRecording ? "허용됨 ✓" : "필요 — 클릭")",
                            #selector(openScreenRecording)))
        menu.addItem(action("손쉬운 사용 권한: \(Permissions.accessibility ? "허용됨 ✓" : "필요 — 클릭")",
                            #selector(openAccessibility)))

        menu.addItem(.separator())
        let loginItem = action("로그인 시 자동 실행 · 멈추면 다시 켜기", #selector(toggleLoginItem))
        loginItem.state = LoginAgent.isEnabled ? .on : .off
        menu.addItem(loginItem)
        if HostConfig.shared.launchAtLogin, LoginAgent.needsApproval {
            menu.addItem(action("   ⚠︎ 시스템 설정에서 허용이 필요합니다 — 클릭", #selector(openLoginItems)))
        }
        menu.addItem(action("연결 기록 보기", #selector(openLog)))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(label("버전 \(version)"))
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Actions

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Only new connections need the new password: dropping the current one would lock out
    /// someone changing it remotely, since the new password is only shown in this menu.
    @objc private func regeneratePassword() {
        HostConfig.shared.regeneratePassword()
    }

    @objc private func choosePassword() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "8자 이상"
        let alert = NSAlert()
        alert.messageText = "새 비밀번호"
        alert.informativeText = "다음 접속부터 적용됩니다. 지금 연결은 유지됩니다."
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            let chosen = field.stringValue.trimmingCharacters(in: .whitespaces)
            if chosen.count >= 8 {
                HostConfig.shared.setPassword(chosen)
                return
            }
            alert.informativeText = "8자 이상으로 입력하세요. 인터넷에서 접속할 수 있으니 짐작하기 어려운 비밀번호가 좋습니다."
        }
    }

    /// Point this Mac at a relay (your own Cloudflare deployment of relay/); empty turns it off.
    @objc private func chooseRelay() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://jump-relay.example.workers.dev"
        field.stringValue = HostConfig.shared.relayURL?.absoluteString ?? ""
        let alert = NSAlert()
        alert.messageText = "중개 서버 주소"
        alert.informativeText = "직접 배포한 Jump 중개 서버 주소를 넣으세요. 비우면 끕니다."
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                HostConfig.shared.relayURL = nil
            } else if let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host != nil {
                HostConfig.shared.relayURL = url
            } else {
                alert.informativeText = "https://로 시작하는 주소를 넣으세요. 비우면 끕니다."
                continue
            }
            host.startRelay()
            return
        }
    }

    /// host.log in Console: sessions, why they ended, the network path and throughput.
    @objc private func openLog() {
        NSWorkspace.shared.open(HostLog.path)
    }

    @objc private func toggleClipboard() {
        HostConfig.shared.shareClipboard.toggle()
    }

    /// Start with the Mac and come back after a crash, so a restart or power cut doesn't leave
    /// it unreachable.
    @objc private func toggleLoginItem() {
        let on = !HostConfig.shared.launchAtLogin
        HostConfig.shared.launchAtLogin = on
        if let error = LoginAgent.apply() {
            let alert = NSAlert()
            alert.messageText = "자동 실행 설정을 바꾸지 못했습니다"
            alert.informativeText = "시스템 설정 → 일반 → 로그인 항목에서 JumpHost를 직접 추가하세요.\n(\(error.localizedDescription))"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func selectQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let quality = HostConfig.Quality(rawValue: raw),
              quality != HostConfig.shared.quality
        else { return }
        HostConfig.shared.quality = quality
        host.disconnect(reason: "화질 설정이 바뀌어 다시 연결합니다", retry: true)
    }

    @objc private func toggleHEVC() {
        HostConfig.shared.useHEVC.toggle()
        host.disconnect(reason: "코덱 설정이 바뀌어 다시 연결합니다", retry: true)
    }

    @objc private func toggleAudio() {
        HostConfig.shared.sendAudio.toggle()
        host.disconnect(reason: "소리 설정이 바뀌어 다시 연결합니다", retry: true)
    }

    @objc private func toggleMute() {
        HostConfig.shared.muteMacWhileConnected.toggle()
        host.refreshSpeakerPolicy()
    }

    @objc private func openScreenRecording() {
        if !Permissions.screenRecording { CGRequestScreenCaptureAccess() }
        Permissions.openScreenRecordingSettings()
    }

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    // MARK: Helpers

    private func updateIcon() {
        let symbol: String
        switch state {
        case .idle: symbol = "display"
        case .connecting: symbol = "display.and.arrow.down"
        case .connected: symbol = "dot.radiowaves.left.and.right"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jump Host")
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }
}
