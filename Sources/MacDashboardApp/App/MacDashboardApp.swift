import SwiftUI
import AppKit
import MacToolKitCore

/// Owns the Dock tile gauge and the Dock right-click menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockTileController.shared.activate()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: "在 Dock 圖示顯示用量 (CPU / RAM / GPU / 溫度)",
            action: #selector(toggleDockUsage),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = DockTileController.shared.isEnabled ? .on : .off
        menu.addItem(toggle)
        return menu
    }

    @objc private func toggleDockUsage() {
        DockTileController.shared.toggle()
    }
}

@main
struct MacDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var dashboardVM = DashboardViewModel.shared
    @StateObject private var lagVM = LagDetectiveViewModel.shared
    @StateObject private var fanVM = FanControlViewModel.shared
    @StateObject private var aiVM = AIAnalyticsViewModel()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Main Dashboard Window
        Window("Mac 運作監控臺 (Dashboard)", id: "main_dashboard") {
            MainWindowView(
                dashboardVM: dashboardVM,
                lagVM: lagVM,
                fanVM: fanVM,
                aiVM: aiVM
            )
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 680)

        // Menu Bar Extra Status Item
        MenuBarExtra("Mac Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            Button("打開完整監控主視窗...") {
                openWindow(id: "main_dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Divider()

            Text("CPU 總負載: \(String(format: "%.1f%%", dashboardVM.cpuSnapshot.totalUsage))")
            Text("RAM 佔用: \(String(format: "%.1f%%", dashboardVM.memorySnapshot.usedPercentage))")
            Text("GPU 使用率: \(String(format: "%.1f%%", dashboardVM.gpuSnapshot.utilization))")
            Text(dashboardVM.fanStatuses.first.map { "風扇實際轉速: \($0.currentRPM) RPM" } ?? "風扇實際轉速: 不可取得")

            Divider()

            Button("全速冷卻散熱 (Max Turbo)") {
                fanVM.selectMode(.maxCooling)
            }

            Divider()

            Button("結束 Mac Dashboard") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
