import AppKit

final class FloatingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Injected by the owning `TimerInstanceController`. The window asks the
    /// model to perform actions without holding a direct reference to it.
    var onResetRequested: (() -> Void)?
    var onResetTodayTotal: (() -> Void)?
    var onSetWorkMinutes: ((Int) -> Void)?
    var onSetBreakMinutes: ((Int) -> Void)?
    var currentWorkMinutes: (() -> Int)?
    var currentBreakMinutes: (() -> Int)?
    /// "Set Task…" menu item — sets/clears the free-text task label.
    var onSetTask: ((String) -> Void)?
    var currentTaskText: (() -> String)?
    var onRecordReview: ((String) -> Void)?
    var canRecordReview: (() -> Bool)?
    /// Cmd+T toggles the live-tuning panel (injected by AppDelegate).
    var onToggleTuning: (() -> Void)?
    /// "Pin on Top" toggle (pomo-ten-segments-and-pin). `onTogglePin` flips
    /// window.level between .floating (pinned, the default) and .normal
    /// (unpinned — can sit behind other apps); `isPinned` reports the live
    /// state for the ⚙ menu's checkbox. Also reachable via Cmd+P.
    var onTogglePin: (() -> Void)?
    var isPinned: (() -> Bool)?
    /// "Extend +5 min" / "Reduce −5 min" (pomo-p1-visibility §3).
    var onExtendRemaining: (() -> Void)?
    var onReduceRemaining: (() -> Void)?
    /// Whether those two items should be enabled right now — false while the
    /// phase hasn't been started yet (`PomodoroSource.isIdleForAdjust`).
    var canAdjustRemaining: (() -> Bool)?

    /// Cmd+= / Cmd++ enlarges, Cmd+- shrinks, Cmd+0 returns to Medium,
    /// Cmd+R resets the timer, Cmd+P toggles Pin on Top.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let chars = event.charactersIgnoringModifiers ?? ""
            switch chars {
            case "+", "=":
                PomoSizeController.shared.bump(+1)
                return
            case "-", "_":
                PomoSizeController.shared.bump(-1)
                return
            case "0":
                PomoSizeController.shared.set(.medium)
                return
            case "r", "R":
                onResetRequested?()
                return
            case "t", "T":
                onToggleTuning?()
                return
            case "p", "P":
                onTogglePin?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// Right-click (and Control+click) shows the full preferences menu.
    override func rightMouseDown(with event: NSEvent) {
        guard let contentView = self.contentView else { return }
        NSMenu.popUpContextMenu(buildContextMenu(), with: event, for: contentView)
    }

    /// ⚙ button (header row) pops up the SAME preferences menu as the
    /// right-click, anchored at the current mouse position within the content
    /// view (no dedicated NSView anchor — see spec §4/§8 risk note).
    func popUpPreferencesMenu() {
        guard let contentView = self.contentView else { return }
        let menu = buildContextMenu()
        let pointInWindow = self.mouseLocationOutsideOfEventStream
        let point = contentView.convert(pointInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }

    // MARK: - Menu construction

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Pomo")
        // P1修正ラウンド1: NSMenu defaults to `autoenablesItems == true`, which
        // makes AppKit's automatic target/action validation run right before
        // the menu is shown (popUpContextMenu / menu.update()) and overwrite
        // any `isEnabled = false` we set below back to `true` whenever the
        // target responds to the selector (it always does here, since
        // `target` is this window and the @objc actions are always
        // implemented). That silently re-enabled Extend/Reduce even when
        // `canAdjustRemaining` was false. Disabling autoenablesItems makes
        // the manual `isEnabled` assignments below authoritative — so this
        // line must run before any of them.
        menu.autoenablesItems = false

        addTimerItems(to: menu)
        menu.addItem(.separator())
        addAppearanceItems(to: menu)
        menu.addItem(.separator())
        addUtilityItems(to: menu)
        menu.addItem(.separator())

        // Quit targets NSApp, not this window, so it is built inline rather
        // than through `addItem(to:…)`.
        let quit = NSMenuItem(
            title: "Quit Pomo",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    /// Appends an item targeting this window. A non-empty `key` also gets the
    /// ⌘ modifier. Returns the item so the caller can set `.isEnabled` or
    /// `.state` inline.
    @discardableResult
    private func addItem(to menu: NSMenu,
                         title: String,
                         action: Selector,
                         key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = [.command]
        }
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addTimerItems(to menu: NSMenu) {
        addItem(to: menu, title: "Reset Timer", action: #selector(menuResetTimer(_:)), key: "r")

        // pomo-p1-visibility §3: placed right next to Reset Timer per the
        // task card. Both are disabled while the phase hasn't started.
        let enabled = canAdjustRemaining?() ?? true
        addItem(to: menu, title: "Extend +5 min",
                action: #selector(menuExtendRemaining(_:))).isEnabled = enabled
        addItem(to: menu, title: "Reduce −5 min",
                action: #selector(menuReduceRemaining(_:))).isEnabled = enabled

        addItem(to: menu, title: "Set Task…", action: #selector(menuSetTask(_:)))
        if canRecordReview?() == true {
            addItem(to: menu, title: "Add Review…", action: #selector(menuRecordReview(_:)))
        }
        addItem(to: menu, title: "Pin on Top",
                action: #selector(menuTogglePin(_:)), key: "p")
            .state = (isPinned?() ?? true) ? .on : .off
    }

    private func addAppearanceItems(to menu: NSMenu) {
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = buildSizeSubmenu()
        menu.addItem(sizeItem)

        let workItem = NSMenuItem(title: "Work Duration", action: nil, keyEquivalent: "")
        workItem.submenu = buildDurationSubmenu(
            title: "Work Duration",
            presets: Self.workPresets,
            current: currentWorkMinutes?() ?? PomodoroSource.defaultWorkMinutes,
            select: #selector(menuSelectWork(_:)),
            custom: #selector(menuCustomWork(_:))
        )
        menu.addItem(workItem)

        let breakItem = NSMenuItem(title: "Break Duration", action: nil, keyEquivalent: "")
        breakItem.submenu = buildDurationSubmenu(
            title: "Break Duration",
            presets: Self.breakPresets,
            current: currentBreakMinutes?() ?? PomodoroSource.defaultBreakMinutes,
            select: #selector(menuSelectBreak(_:)),
            custom: #selector(menuCustomBreak(_:))
        )
        menu.addItem(breakItem)

        addItem(to: menu, title: "Gauge Color…", action: #selector(menuGaugeColor(_:)))
    }

    private func addUtilityItems(to menu: NSMenu) {
        addItem(to: menu, title: "Open Logs Folder", action: #selector(menuOpenLogsFolder(_:)))
    }

    private func buildSizeSubmenu() -> NSMenu {
        let sub = NSMenu(title: "Size")
        let current = PomoSizeController.shared.current
        for size in PomoSize.allCases {
            let item = NSMenuItem(
                title: size.displayName,
                action: #selector(menuSelectSize(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = size.rawValue
            item.state = (size == current) ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    /// Preset minute choices shown in the Work Duration submenu.
    private static let workPresets = [15, 25, 45, 60, 90]
    /// Preset minute choices shown in the Break Duration submenu.
    private static let breakPresets = [3, 5, 10, 15, 20]

    /// Builds one duration submenu: the presets, then a Custom… item.
    ///
    /// If `current` is not one of the presets (i.e. it was set via Custom…) it
    /// is spliced into the list in sorted order, so the menu always shows a
    /// checked item matching the live setting rather than nothing checked.
    private func buildDurationSubmenu(title: String,
                                      presets: [Int],
                                      current: Int,
                                      select: Selector,
                                      custom: Selector) -> NSMenu {
        let sub = NSMenu(title: title)
        var minutes = presets
        if !minutes.contains(current) {
            minutes.append(current)
            minutes.sort()
        }
        for mins in minutes {
            let item = NSMenuItem(title: "\(mins) minutes", action: select, keyEquivalent: "")
            item.target = self
            item.tag = mins
            item.state = (mins == current) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom…", action: custom, keyEquivalent: "")
        customItem.target = self
        sub.addItem(customItem)
        return sub
    }

    // MARK: - Menu actions

    @objc private func menuResetTimer(_ sender: NSMenuItem) {
        onResetRequested?()
    }

    @objc private func menuExtendRemaining(_ sender: NSMenuItem) {
        onExtendRemaining?()
    }

    @objc private func menuReduceRemaining(_ sender: NSMenuItem) {
        onReduceRemaining?()
    }

    @objc private func menuOpenLogsFolder(_ sender: NSMenuItem) {
        // Ensure the directory exists even if no session has been logged yet,
        // so Finder always has somewhere to land.
        guard let dirURL = SessionLog.shared.ensureDirectoryExists() else {
            NSSound.beep()
            return
        }
        if let fileURL = SessionLog.shared.fileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: dirURL.path)
        } else {
            NSWorkspace.shared.open(dirURL)
        }
    }

    @objc private func menuSetTask(_ sender: NSMenuItem) {
        Self.presentTaskInputAlert(current: currentTaskText?() ?? "") { [weak self] text in
            self?.onSetTask?(text)
        }
    }

    @objc private func menuRecordReview(_ sender: NSMenuItem) {
        Self.presentReviewInputAlert { [weak self] text in
            self?.onRecordReview?(text)
        }
    }

    @objc private func menuTogglePin(_ sender: NSMenuItem) {
        onTogglePin?()
    }

    @objc private func menuSelectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = PomoSize(rawValue: raw) else { return }
        PomoSizeController.shared.set(size)
    }

    @objc private func menuSelectWork(_ sender: NSMenuItem) {
        onSetWorkMinutes?(sender.tag)
    }

    @objc private func menuSelectBreak(_ sender: NSMenuItem) {
        onSetBreakMinutes?(sender.tag)
    }

    @objc private func menuCustomWork(_ sender: NSMenuItem) {
        presentCustomDurationAlert(
            title: "Custom Work Duration",
            current: currentWorkMinutes?() ?? PomodoroSource.defaultWorkMinutes
        ) { [weak self] minutes in
            self?.onSetWorkMinutes?(minutes)
        }
    }

    @objc private func menuCustomBreak(_ sender: NSMenuItem) {
        presentCustomDurationAlert(
            title: "Custom Break Duration",
            current: currentBreakMinutes?() ?? PomodoroSource.defaultBreakMinutes
        ) { [weak self] minutes in
            self?.onSetBreakMinutes?(minutes)
        }
    }

    /// Empty input reverts to the default colour; unparsable input beeps and
    /// changes nothing.
    @objc private func menuGaugeColor(_ sender: NSMenuItem) {
        guard let text = Self.promptForText(
            title: "Gauge Color",
            message: "RGB (例: 0,167,96) または hex (#00A796)。空欄でデフォルトに戻す。",
            initial: AccentColorStore.format(AccentColorStore.shared.rgb),
            placeholder: "R,G,B or #RRGGBB",
            fieldWidth: Tokens.Dialog.numericFieldWidth
        ) else { return }

        if text.isEmpty {
            AccentColorStore.shared.reset()
            return
        }
        guard let parsed = AccentColorStore.parse(text) else {
            NSSound.beep()
            return
        }
        AccentColorStore.shared.set(parsed)
    }

    // MARK: - Modal text prompt

    /// The shared NSAlert + NSTextField spine behind every dialog in this
    /// file. Returns nil on Cancel, otherwise the trimmed field contents —
    /// each caller decides for itself what an empty string means, because
    /// they genuinely differ (clear the task / revert the colour / no-op).
    ///
    /// The app runs with `.accessory` activation policy (no Dock icon), so
    /// without an explicit `NSApp.activate` the alert can appear without
    /// keyboard focus. Activating first makes the field focused and typable
    /// immediately.
    private static func promptForText(title: String,
                                      message: String,
                                      initial: String = "",
                                      placeholder: String,
                                      fieldWidth: CGFloat) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: fieldWidth, height: Tokens.Dialog.fieldHeight)
        )
        inputField.stringValue = initial
        inputField.placeholderString = placeholder
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prompts for a custom minute value. Out-of-range or unparsable input
    /// beeps and changes nothing; Cancel is silent.
    private func presentCustomDurationAlert(
        title: String,
        current: Int,
        onConfirm: @escaping (Int) -> Void
    ) {
        let range = PomodoroSource.minCustomMinutes...PomodoroSource.maxCustomMinutes
        guard let text = Self.promptForText(
            title: title,
            message: "Enter minutes (\(range.lowerBound)–\(range.upperBound)):",
            initial: "\(current)",
            placeholder: "Minutes",
            fieldWidth: Tokens.Dialog.numericFieldWidth
        ) else { return }

        guard let value = Int(text), range.contains(value) else {
            NSSound.beep()
            return
        }
        onConfirm(value)
    }

    /// Prompts for a free-text task label. Empty input is a valid confirm (it
    /// clears the task) — only Cancel is a no-op. `static` (no instance state
    /// used) so `PomoView` can call it directly, not just the menu.
    static func presentTaskInputAlert(
        current: String,
        onConfirm: @escaping (String) -> Void
    ) {
        guard let text = promptForText(
            title: "Set Task",
            message: "What are you working on? (leave empty to clear)",
            initial: current,
            placeholder: "e.g. 広告コピー作成",
            fieldWidth: Tokens.Dialog.textFieldWidth
        ) else { return }
        onConfirm(text)
    }

    /// Sister to `presentTaskInputAlert`, called from the break-only menu item.
    /// Unlike the task dialog, empty input here
    /// is NOT a valid confirm (task card: "空文字ならappendしない") — both an
    /// empty OK and Cancel are silent no-ops.
    static func presentReviewInputAlert(
        onConfirm: @escaping (String) -> Void
    ) {
        guard let text = promptForText(
            title: "このセッションの振り返り",
            message: "1行でOK。何をやった?どうだった?",
            placeholder: "例: 資料作成、思ったより捗った",
            fieldWidth: Tokens.Dialog.textFieldWidth
        ) else { return }
        guard !text.isEmpty else { return }
        onConfirm(text)
    }
}
