import Foundation
import SwiftUI
import Combine
import MacToolKitCore

public enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "系統總覽"
    case aiAnalytics = "AI 寫程式分析"
    case lagDetective = "Lag 診斷中心"
    case cpu = "CPU 運算"
    case memory = "記憶體 RAM"
    case diskNetwork = "磁碟與網路"
    case thermalFan = "風扇與散熱"
    case processes = "行程管理員"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .aiAnalytics: return "brain.head.profile"
        case .lagDetective: return "stethoscope"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .diskNetwork: return "network"
        case .thermalFan: return "fanblades.fill"
        case .processes: return "list.bullet.rectangle.portrait"
        }
    }

    public var keyboardShortcutKey: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .aiAnalytics: return "2"
        case .lagDetective: return "3"
        case .cpu: return "4"
        case .memory: return "5"
        case .diskNetwork: return "6"
        case .thermalFan: return "7"
        case .processes: return "8"
        }
    }
}

public enum MonitoringProfile: String, CaseIterable, Identifiable, Sendable {
    case realtime = "realtime"
    case balanced = "balanced"
    case fanOnlyEco = "fanOnlyEco"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .realtime: return "即時全景 (1秒)"
        case .balanced: return "平衡節能 (3秒)"
        case .fanOnlyEco: return "僅風扇控溫 (極致省電)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .realtime: return "即時 (1s)"
        case .balanced: return "平衡 (3s)"
        case .fanOnlyEco: return "僅風扇 (Eco)"
        }
    }

    public var iconName: String {
        switch self {
        case .realtime: return "bolt.fill"
        case .balanced: return "leaf.fill"
        case .fanOnlyEco: return "fanblades.fill"
        }
    }

    public var description: String {
        switch self {
        case .realtime: return "每秒刷新硬體、行程與 Docker；實際監控開銷請以行程頁讀值為準"
        case .balanced: return "每 3 秒刷新一次；實際監控開銷請以行程頁讀值為準"
        case .fanOnlyEco: return "暫停 CPU、RAM、行程、磁碟與 Docker 掃描，只保留電池與風扇讀回"
        }
    }
}

@MainActor
public final class DashboardViewModel: ObservableObject {
    public static let shared = DashboardViewModel()

    // Navigation state
    @Published public var selectedTab: DashboardTab = .overview

    // Monitoring Mode Profile
    @Published public var monitoringProfile: MonitoringProfile = .realtime {
        didSet {
            startMonitoring()
        }
    }

    // Current Live Metrics
    @Published public var cpuSnapshot = CPUUsageSnapshot()
    @Published public var memorySnapshot = MemoryUsageSnapshot()
    @Published public var gpuSnapshot = GPUUsageSnapshot()
    @Published public var processes: [ProcessItem] = []
    @Published public var diskVolumes: [DiskVolumeInfo] = []
    @Published public var diskIOSnapshot = DiskIOSnapshot()
    @Published public var networkIOSnapshot = NetworkIOSnapshot()
    @Published public var batteryThermalSnapshot = BatteryThermalSnapshot()
    @Published public var fanStatuses: [FanStatus] = []
    @Published public var dockerContainers: [DockerContainerInfo] = []
    @Published public var storageAnalysis = StorageAnalysisSnapshot.empty
    @Published public var storageCleanupResult: StorageCleanupResult? = nil
    @Published public var isStorageAnalysisRunning = false
    @Published public var isStorageCleanupRunning = false

    // History for Sparkline Graphs (Last 30 points)
    @Published public var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published public var memoryHistory: [Double] = Array(repeating: 0, count: 30)
    @Published public var gpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published public var networkDownHistory: [Double] = Array(repeating: 0, count: 30)
    @Published public var networkUpHistory: [Double] = Array(repeating: 0, count: 30)

    // Filtering & UI State
    @Published public var processSearchText: String = ""
    @Published public var onlyUserApps: Bool = false
    @Published public var processSortByCPU: Bool = true
    @Published public var statusMessage: String? = nil

    // Services
    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let gpuMonitor = GPUMonitor()
    private let processMonitor = ProcessMonitor()
    private let diskMonitor = DiskMonitor()
    private let networkMonitor = NetworkMonitor()
    private let batteryThermalMonitor = BatteryThermalMonitor()
    private let storageAnalyzer = StorageAnalyzer()
    private let storageCleanupService = StorageCleanupService()

    private var monitorTask: Task<Void, Never>?

    public init() {
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
    }

    public func startMonitoring() {
        monitorTask?.cancel()
        let intervalSec: Double
        switch monitoringProfile {
        case .realtime: intervalSec = 1.0
        case .balanced: intervalSec = 3.0
        case .fanOnlyEco: intervalSec = 3.0
        }

        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.performSample()
                try? await Task.sleep(nanoseconds: UInt64(intervalSec * 1_000_000_000))
            }
        }
    }

    public func performSample() async {
        let cpuMon = cpuMonitor
        let memMon = memoryMonitor
        let gpuMon = gpuMonitor
        let procMon = processMonitor
        let diskMon = diskMonitor
        let netMon = networkMonitor
        let btMon = batteryThermalMonitor
        let isFanOnly = monitoringProfile == .fanOnlyEco
        let fans = await FanHelperClient.shared.getFanStatuses() ?? []

        let sample = await Task.detached(priority: .userInitiated) {
            autoreleasepool { () -> (
                cpu: CPUUsageSnapshot,
                mem: MemoryUsageSnapshot,
                gpu: GPUUsageSnapshot,
                procs: [ProcessItem],
                vols: [DiskVolumeInfo],
                dIO: DiskIOSnapshot,
                nIO: NetworkIOSnapshot,
                bt: BatteryThermalSnapshot,
                dockers: [DockerContainerInfo]
            ) in
                let bt = btMon.sample()
                // Reading IOAccelerator statistics costs well under a
                // millisecond, so the GPU gauge stays live even in Eco mode.
                let gpu = gpuMon.sample()

                if isFanOnly {
                    // Eco Mode: zero process scanning, zero docker stats, minimal overhead
                    return (CPUUsageSnapshot(), MemoryUsageSnapshot(), gpu, [], [], DiskIOSnapshot(), NetworkIOSnapshot(), bt, [])
                }

                let cpu = cpuMon.sample()
                let mem = memMon.sample()
                let procs = procMon.sampleProcesses()
                let vols = diskMon.sampleVolumes()
                let dIO = diskMon.sampleIO()
                let nIO = netMon.sample()
                let dockers = procMon.sampleDockerContainers()
                return (cpu, mem, gpu, procs, vols, dIO, nIO, bt, dockers)
            }
        }.value

        // Atomic batch update on MainActor
        self.batteryThermalSnapshot = sample.bt
        self.fanStatuses = fans
        self.gpuSnapshot = sample.gpu
        self.appendHistory(value: sample.gpu.utilization, to: &self.gpuHistory)

        if !isFanOnly {
            self.cpuSnapshot = sample.cpu
            self.memorySnapshot = sample.mem
            self.processes = sample.procs
            self.diskVolumes = sample.vols
            self.diskIOSnapshot = sample.dIO
            self.networkIOSnapshot = sample.nIO
            self.dockerContainers = sample.dockers

            self.appendHistory(value: sample.cpu.totalUsage, to: &self.cpuHistory)
            self.appendHistory(value: sample.mem.usedPercentage, to: &self.memoryHistory)
            self.appendHistory(value: sample.nIO.downloadBytesPerSec / (1024 * 1024), to: &self.networkDownHistory)
            self.appendHistory(value: sample.nIO.uploadBytesPerSec / (1024 * 1024), to: &self.networkUpHistory)
        }

        // Keep the Dock icon gauge in sync. Eco mode skips CPU/RAM sampling,
        // so those two bars hold their last known values while GPU keeps ticking.
        DockTileController.shared.update(
            cpu: self.cpuSnapshot.totalUsage,
            ram: self.memorySnapshot.usedPercentage,
            gpu: self.gpuSnapshot.utilization
        )
    }

    public func refreshAll() {
        Task { @MainActor in
            await performSample()
        }
    }

    public func refreshStorageAnalysis(force: Bool = false) async {
        guard !isStorageAnalysisRunning, !isStorageCleanupRunning else { return }
        let age = Date().timeIntervalSince(storageAnalysis.scannedAt)
        guard force || storageAnalysis.categories.isEmpty || age >= 300 else { return }

        isStorageAnalysisRunning = true
        let analyzer = storageAnalyzer
        let snapshot = await Task.detached(priority: .utility) {
            analyzer.scan()
        }.value
        storageAnalysis = snapshot
        isStorageAnalysisRunning = false
    }

    public func cleanStorage(candidateIDs: Set<String>) async {
        guard !candidateIDs.isEmpty, !isStorageAnalysisRunning, !isStorageCleanupRunning else { return }

        isStorageCleanupRunning = true
        storageCleanupResult = nil
        let service = storageCleanupService
        let analyzer = storageAnalyzer
        let outcome = await Task.detached(priority: .userInitiated) {
            let result = service.clean(candidateIDs: candidateIDs)
            return (result, analyzer.scan())
        }.value
        storageCleanupResult = outcome.0
        storageAnalysis = outcome.1
        isStorageCleanupRunning = false
    }

    private func appendHistory(value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 30 {
            history.removeFirst(history.count - 30)
        }
    }

    public func terminateProcess(pid: pid_t, force: Bool = true) {
        let success = processMonitor.terminateProcess(pid: pid, force: force)
        if success {
            self.statusMessage = "已成功送出 \(force ? "SIGKILL" : "SIGTERM") (PID \(pid))；是否退出以重新取樣為準"
            refreshAll()
        } else {
            self.statusMessage = "無法結束行程 (PID \(pid))，可能權限不足"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.statusMessage = nil
        }
    }

    public var filteredProcesses: [ProcessItem] {
        var list = processes
        if onlyUserApps {
            list = list.filter { $0.isUserApp }
        }
        if !processSearchText.isEmpty {
            let q = processSearchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.rawName.lowercased().contains(q) ||
                String($0.pid).contains(q) ||
                ($0.bundleIdentifier?.lowercased().contains(q) ?? false)
            }
        }
        if processSortByCPU {
            return list.sorted { $0.cpuPercentage > $1.cpuPercentage }
        } else {
            return list.sorted { $0.memoryBytes > $1.memoryBytes }
        }
    }

    public func lowerPriority(pid: pid_t) {
        lowerProcessPriority(pid: pid)
    }

    public func lowerProcessPriority(pid: pid_t) {
        let success = processMonitor.lowerPriority(pid: pid)
        if success {
            self.statusMessage = "已成功降低行程優先權 (PID \(pid))"
            refreshAll()
        } else {
            self.statusMessage = "無法更改優先權 (PID \(pid))"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.statusMessage = nil
        }
    }
}
