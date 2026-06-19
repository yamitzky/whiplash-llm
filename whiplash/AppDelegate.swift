import AppKit
import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let newInput = Self("newInput")
    static let capture = Self("capture", default: .init(.x, modifiers: [.command, .shift]))
    static let clipboardCapture = Self("clipboardCapture", default: .init(.v, modifiers: [.command, .shift]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    let roleStore = RoleStore()
    let settingsStore = SettingsStore()
    lazy var captureFlow = CaptureFlow(
        roleStore: roleStore,
        settingsStore: settingsStore
    )

    // Menu items that need shortcut display updates
    private var newInputItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var clipboardItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()

        // 設定ウィンドウのクローズを直接捕捉してアクティベーションポリシーを戻す
        // （SwiftUI の .onDisappear に依存しない）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        KeyboardShortcuts.onKeyDown(for: .newInput) { [weak self] in
            self?.captureFlow.startEmpty()
        }

        KeyboardShortcuts.onKeyDown(for: .capture) { [weak self] in
            self?.captureFlow.start()
        }

        KeyboardShortcuts.onKeyDown(for: .clipboardCapture) { [weak self] in
            self?.captureFlow.startFromClipboard()
        }

        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            Task { @MainActor in
                await captureFlow.runSelfTest()
            }
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "Whiplash")
        }

        let menu = NSMenu()
        menu.delegate = self

        newInputItem = NSMenuItem(title: "新規入力", action: #selector(startEmpty), keyEquivalent: "")
        menu.addItem(newInputItem)

        captureItem = NSMenuItem(title: "キャプチャ", action: #selector(startCapture), keyEquivalent: "")
        menu.addItem(captureItem)

        clipboardItem = NSMenuItem(title: "クリップボードキャプチャ", action: #selector(startClipboardCapture), keyEquivalent: "")
        menu.addItem(clipboardItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "設定を開く...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Whiplash を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func updateMenuShortcutDisplay() {
        applyShortcutDisplay(to: newInputItem, for: .newInput)
        applyShortcutDisplay(to: captureItem, for: .capture)
        applyShortcutDisplay(to: clipboardItem, for: .clipboardCapture)
    }

    private func applyShortcutDisplay(to item: NSMenuItem, for name: KeyboardShortcuts.Name) {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        // Use the native key equivalent display
        item.keyEquivalent = shortcut.keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierMask
    }

    @objc private func startEmpty() {
        captureFlow.startEmpty()
    }

    @objc private func startCapture() {
        captureFlow.start()
    }

    @objc private func startClipboardCapture() {
        captureFlow.startFromClipboard()
    }

    /// ステータスメニューの「設定を開く...」から SwiftUI の Settings シーンを開く。
    /// ⌘, は SwiftUI が同じシーンに紐付けるため、入口がここに一本化される。
    @objc private func openSettings() {
        // .regular 化とアクティベートは Settings シーンの onAppear（settingsWindowDidAppear）に
        // 一本化しているため、ここでは設定シーンを開くだけにする（二重アクティベートの回避）。
        // macOS 13+ は showSettingsWindow:、それ以前は showPreferencesWindow:。
        // sendAction は受け手が無いと false を返すので、フォールバックして無反応を防ぐ。
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// Settings シーンが表示されたとき（⌘, ・メニュー経由とも）に呼ばれる。
    func settingsWindowDidAppear() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 設定ウィンドウが閉じられたらメニューバー常駐（accessory）に戻す。
    /// SwiftUI の Settings シーンは .onDisappear がクローズ時に発火する保証がないため、
    /// AppKit の willClose を直接監視する。自前のウィンドウ（ロール選択・rich message・
    /// ローディング・トースト）はすべて NSPanel なので、素の NSWindow が閉じた＝設定ウィンドウ
    /// とみなす（accessory 時に来ても冪等なので無害）。
    @objc private func settingsWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, !(closing is NSPanel) else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuShortcutDisplay()
    }
}

// MARK: - KeyboardShortcuts Helpers

private extension KeyboardShortcuts.Shortcut {
    var keyEquivalent: String {
        // Convert KeyboardShortcuts.Key to a string for NSMenuItem
        let key = self.key
        // Use Carbon key code mapping
        switch key {
        case .a: return "a"
        case .b: return "b"
        case .c: return "c"
        case .d: return "d"
        case .e: return "e"
        case .f: return "f"
        case .g: return "g"
        case .h: return "h"
        case .i: return "i"
        case .j: return "j"
        case .k: return "k"
        case .l: return "l"
        case .m: return "m"
        case .n: return "n"
        case .o: return "o"
        case .p: return "p"
        case .q: return "q"
        case .r: return "r"
        case .s: return "s"
        case .t: return "t"
        case .u: return "u"
        case .v: return "v"
        case .w: return "w"
        case .x: return "x"
        case .y: return "y"
        case .z: return "z"
        case .zero: return "0"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        default: return ""
        }
    }

    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }
}
