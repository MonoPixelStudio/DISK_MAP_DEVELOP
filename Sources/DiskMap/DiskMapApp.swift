import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.isTrashBusy == true { NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model?.isTrashBusy == true { NSSound.beep(); return false }
        return true
    }
}

@main
struct DiskMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DiskMap", id: "main") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model
                    NSApplication.shared.windows.first(where: { $0.title == "DiskMap" })?.delegate = delegate
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.automatic)
        .commands {
            CommandMenu("정리") {
                Button("정리 목록 검토") { model.reviewCleanup() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.isTrashBusy)
                Button("최근 정리 결과") { model.reviewCleanup(results: true) }.disabled(model.isTrashBusy)
                Button("여유 공간 새로고침") { model.refreshSpace() }.disabled(model.isSample || model.isRefreshingSpace)
            }
            CommandGroup(after: .textEditing) {
                Button("파일 이름 검색") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("스캔할 폴더 선택…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isScanning || model.isCleanupPresented || model.isTrashBusy)
                Button("샘플 보기") { model.showSample() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(model.isTrashBusy)
            }
        }
    }
}
