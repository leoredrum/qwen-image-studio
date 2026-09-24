import SwiftUI

@main
struct QwenImageStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var studio = Studio()

    var body: some Scene {
        WindowGroup("Qwen Image Studio") {
            ContentView()
                .environment(studio)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("生成") {
                Button("生成") { studio.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!studio.canSend)
                Button("停止") { studio.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(studio.runningID == nil)
                Divider()
                Button("添加参考图…") { studio.pickReferences() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("模型管理…") { studio.showModelManager = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("打开输出文件夹") { NSWorkspace.shared.open(studio.outputsDir) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        HSplitView {
            ChatPanel()
                .frame(minWidth: 590, idealWidth: 600, maxWidth: 760)
            ViewerPanel()
                .frame(minWidth: 520, maxWidth: .infinity)
        }
        .frame(minWidth: 1120, minHeight: 700)
        .sheet(isPresented: $studio.showModelManager) {
            ModelManagerView().environment(studio)
        }
        .sheet(isPresented: $studio.showLog) {
            LogView().environment(studio)
        }
    }
}
