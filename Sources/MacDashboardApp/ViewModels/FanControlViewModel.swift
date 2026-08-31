import Foundation
import SwiftUI
import Combine
import MacToolKitCore

@MainActor
public final class FanControlViewModel: ObservableObject {
    public static let shared = FanControlViewModel()

    @Published public var isHelperInstalled: Bool = false
    @Published public var isHelperRunning: Bool = false
    @Published public var helperCapability: FanHelperCapability = .unreachable
    @Published public var isInstallingHelper: Bool = false
    @Published public var selectedMode: FanMode = .automatic
    @Published public var selectedSensorTarget: ThermalSensorTarget = .socPackage
    @Published public var customRPM: Double = 3000
    @Published public var fanStatuses: [FanStatus] = []
    @Published public var componentReadings: [ComponentThermalReading] = []
    @Published public var currentActiveRPM: Int = 0
    @Published public var currentTargetTemp: Int = 65
    @Published public var currentMonitoredTemp: Double? = nil
    @Published public var fanStateDescription: String = "等待硬體讀回"
    @Published public var helperSecurityWarning: String? = nil
    @Published public var message: String? = nil
    @Published public var errorMessage: String? = nil

    private let helperManager = PrivilegedHelperManager.shared
    private let helperClient = FanHelperClient.shared
    private let sensorMonitor = HardwareSensorMonitor()
    private var timerCancellable: AnyCancellable?

    // MARK: - Hysteresis & Anti-Hunting Control States
    private var smoothedTemperature: Double? = nil
    private var lastOutputRPM: Int = 0
    private var spinDownCooldownCycles: Int = 0  // Hold-time cycles to prevent rapid on/off hunting
    private let hysteresisBuffer: Double = 7.0   // 7.0°C deadband between ramp-up and ramp-down (降速門檻延遲 -7°C)

    public init() {
        checkHelperStatus()
        startPolling()
    }

    public var hasMeasuredTemperatureForSelectedTarget: Bool {
        guard selectedSensorTarget != .palmRest else { return false }
        return componentReadings.first(where: { $0.target == selectedSensorTarget })?.temperatureCelsius != nil
    }

    public var measuredComponentReadings: [ComponentThermalReading] {
        ThermalSensorPresentation.measuredPhysicalReadings(from: componentReadings)
    }

    public var measuredSensorTargets: [ThermalSensorTarget] {
        measuredComponentReadings.map(\.target)
    }

    public var measuredSensorPointCount: Int {
        ThermalSensorPresentation.measuredPointCount(from: componentReadings)
    }

    public var supportedManualRPMRange: ClosedRange<Double>? {
        guard !fanStatuses.isEmpty,
              fanStatuses.allSatisfy({ $0.minRPM > 0 && $0.maxRPM >= $0.minRPM }) else { return nil }
        let lower = Double(fanStatuses.map(\.minRPM).max()!)
        let upper = Double(fanStatuses.map(\.maxRPM).min()!)
        return lower <= upper ? lower...upper : nil
    }

    public func checkHelperStatus() {
        self.isHelperInstalled = helperManager.isInstalled()
        self.helperSecurityWarning = currentHelperSecurityWarning()
        Task {
            let capability = await helperManager.capability()
            await MainActor.run {
                self.helperCapability = capability
                self.isHelperRunning = capability != .unreachable
                self.refresh()
            }
        }
    }

    private func startPolling() {
        timerCancellable = Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    public func refresh() {
        Task {
            let capability = await self.helperManager.capability()
            await MainActor.run {
                self.isHelperInstalled = self.helperManager.isInstalled()
                self.helperCapability = capability
                self.isHelperRunning = capability != .unreachable
                self.helperSecurityWarning = self.currentHelperSecurityWarning()
            }

            // Execute Closed-Loop Thermal Controller Pass with Anti-Hunting Hysteresis
            await self.applyDynamicClosedLoopControl()
        }
    }

    private func currentHelperSecurityWarning() -> String? {
        guard case .unsafe(let reason) = helperClient.socketTrustStatus() else { return nil }
        return "已拒絕連線舊版不安全 helper（\(reason)）；請重新安裝後再使用風扇讀寫。"
    }

    /// 智慧閉迴路動態溫控演算法（含遲滯防抖與平滑降溫保護）
    private func applyDynamicClosedLoopControl() async {
        let baseReadings = sensorMonitor.sampleAllComponents()
        let readings = baseReadings
        let rawSensorTemp = selectedSensorTarget == .palmRest
            ? nil
            : readings.first(where: { $0.target == selectedSensorTarget })?.temperatureCelsius

        let currentSmoothedTemp: Double?
        if let rawSensorTemp, let previous = smoothedTemperature {
            currentSmoothedTemp = (0.35 * rawSensorTemp) + (0.65 * previous)
        } else {
            currentSmoothedTemp = rawSensorTemp
        }
        smoothedTemperature = currentSmoothedTemp

        var targetRPM = 0
        var statusDesc = "等待策略評估與硬體讀回"
        var activeTargetTemp = selectedSensorTarget.defaultTargetTemp

        switch selectedMode {
        case .automatic:
            targetRPM = 0
            statusDesc = "已要求交回 macOS 原廠自動控制；實際 RPM 見上方讀回值"
            spinDownCooldownCycles = 0
            lastOutputRPM = 0
            if isHelperRunning { _ = await helperClient.setAllAuto() }

        case .quiet(let targetTemp):
            guard let currentSmoothedTemp else {
                targetRPM = 0
                statusDesc = "溫度來源不可取得；已停用自訂閉迴路並交回 macOS 原廠控制"
                if isHelperRunning { _ = await helperClient.setAllAuto() }
                break
            }
            activeTargetTemp = (selectedSensorTarget == .palmRest ? 36 : (selectedSensorTarget == .socPackage ? 70 : targetTemp))
            let calculated = calculateHysteresisRPM(
                currentTemp: currentSmoothedTemp,
                targetTemp: activeTargetTemp,
                baseRPM: 1400,
                maxRPM: 3800,
                rampFactor: 200,
                modeLabel: "靜音策略"
            )
            targetRPM = calculated.rpm
            statusDesc = calculated.desc
            await dispatchFanRPM(targetRPM)

        case .balanced(let targetTemp):
            guard let currentSmoothedTemp else {
                targetRPM = 0
                statusDesc = "溫度來源不可取得；已停用自訂閉迴路並交回 macOS 原廠控制"
                if isHelperRunning { _ = await helperClient.setAllAuto() }
                break
            }
            activeTargetTemp = (selectedSensorTarget == .palmRest ? 34 : (selectedSensorTarget == .socPackage ? 60 : targetTemp))
            let calculated = calculateHysteresisRPM(
                currentTemp: currentSmoothedTemp,
                targetTemp: activeTargetTemp,
                baseRPM: 2200,
                maxRPM: 5000,
                rampFactor: 250,
                modeLabel: "智慧溫控"
            )
            targetRPM = calculated.rpm
            statusDesc = calculated.desc
            await dispatchFanRPM(targetRPM)

        case .maxCooling:
            guard let currentSmoothedTemp else {
                targetRPM = 0
                statusDesc = "溫度來源不可取得；已停用自訂閉迴路並交回 macOS 原廠控制"
                if isHelperRunning { _ = await helperClient.setAllAuto() }
                break
            }
            activeTargetTemp = (selectedSensorTarget == .palmRest ? 32 : (selectedSensorTarget == .socPackage ? 48 : 50))
            let calculated = calculateHysteresisRPM(
                currentTemp: currentSmoothedTemp,
                targetTemp: activeTargetTemp,
                baseRPM: 3800,
                maxRPM: 6200,
                rampFactor: 450,
                modeLabel: "極限壓溫"
            )
            targetRPM = calculated.rpm
            statusDesc = calculated.desc
            await dispatchFanRPM(targetRPM)

        case .custom(let rpm):
            targetRPM = rpm
            statusDesc = "手動固定覆寫中：\(rpm) RPM"
            spinDownCooldownCycles = 0
            lastOutputRPM = rpm
            if isHelperRunning {
                if !(await helperClient.setAllFanSpeeds(rpm: rpm)) {
                    statusDesc = "設定失敗或無法確認風扇清單；已交回 macOS 原廠控制"
                    _ = await helperClient.setAllAuto()
                }
            }
        }

        let readback = isHelperRunning ? await helperClient.getFanStatuses(currentMode: selectedMode) : nil
        let updatedRPM = targetRPM
        let updatedDesc = statusDesc
        let updatedMonitoredTemp = currentSmoothedTemp
        let updatedTargetTemp = activeTargetTemp

        await MainActor.run {
            self.componentReadings = readings
            // Hottest measured component drives the Dock temperature bar.
            // Derived targets (peak, palm rest) are excluded so the bar only
            // ever reflects a real sensor.
            DockTileController.shared.updateTemperature(
                ThermalSensorPresentation
                    .measuredPhysicalReadings(from: readings)
                    .compactMap(\.temperatureCelsius)
                    .max()
            )
            if !self.measuredSensorTargets.contains(self.selectedSensorTarget),
               let firstMeasuredTarget = self.measuredSensorTargets.first {
                self.selectedSensorTarget = firstMeasuredTarget
                self.smoothedTemperature = nil
            }
            self.currentActiveRPM = updatedRPM
            self.currentMonitoredTemp = updatedMonitoredTemp
            self.currentTargetTemp = updatedTargetTemp
            self.fanStateDescription = updatedDesc

            self.fanStatuses = readback ?? []
            if let range = self.supportedManualRPMRange {
                self.customRPM = min(range.upperBound, max(range.lowerBound, self.customRPM))
            }
        }
    }

    /// 遲滯防抖與平滑冷卻核心計算函式 (Thermal Hysteresis & Anti-Hunting Core)
    private func calculateHysteresisRPM(
        currentTemp: Double,
        targetTemp: Int,
        baseRPM: Int,
        maxRPM: Int,
        rampFactor: Int,
        modeLabel: String
    ) -> (rpm: Int, desc: String) {
        let target = Double(targetTemp)
        let upperThreshold = target + 0.8                      // 升速門檻 (例: 50.8°C)
        let lowerThreshold = target - hysteresisBuffer         // 降速/停轉門檻 (例: 47.5°C，具備 2.5°C 遲滯死區)

        // 狀況 1：溫度超過上限門檻（需要升速排熱）
        if currentTemp >= upperThreshold {
            let over = currentTemp - target
            let rawRPM = baseRPM + Int(over * Double(rampFactor))
            let calculatedRPM = min(maxRPM, max(baseRPM, rawRPM))
            spinDownCooldownCycles = 8 // 鎖定至少 8 個週期（約 12 秒）平滑冷卻保持期，杜絕反覆開關

            // 限制轉速升速斜率 (Slew Rate Limiting: 每次最大增加 400 RPM)
            let targetOutputRPM: Int
            if lastOutputRPM == 0 {
                targetOutputRPM = baseRPM
            } else {
                targetOutputRPM = min(calculatedRPM, lastOutputRPM + 400)
            }
            lastOutputRPM = targetOutputRPM

            let desc = "🔥 【\(selectedSensorTarget.shortName)】\(String(format: "%.1f", currentTemp))°C > 目標 \(targetTemp)°C (壓溫升速中：\(targetOutputRPM) RPM)"
            return (targetOutputRPM, desc)
        }

        // 狀況 2：溫度落在「遲滯死區 (Deadband)」內（47.5°C ~ 50.8°C）
        if currentTemp >= lowerThreshold && currentTemp < upperThreshold {
            // 如果先前風扇已經在轉，且處於降溫冷卻期中：平穩維持在平緩低轉，不切斷停轉！
            if spinDownCooldownCycles > 0 || lastOutputRPM > 0 {
                if spinDownCooldownCycles > 0 {
                    spinDownCooldownCycles -= 1
                }
                // 平緩降至 baseRPM
                let smoothRPM = max(baseRPM, lastOutputRPM - 200)
                lastOutputRPM = smoothRPM
                let desc = "⚖️ 遲滯穩定防抖中：\(smoothRPM) RPM (【\(selectedSensorTarget.shortName)】\(String(format: "%.1f", currentTemp))°C 接近目標 \(targetTemp)°C)"
                return (smoothRPM, desc)
            } else {
                // 如果先前原本就是停轉的，且未超過 upperThreshold，則繼續保持靜音
                lastOutputRPM = 0
                let desc = "【\(selectedSensorTarget.shortName)】\(String(format: "%.1f", currentTemp))°C ≤ 目標 \(targetTemp)°C (安全靜音停轉)"
                return (0, desc)
            }
        }

        // 狀況 3：溫度已徹底冷卻至 lowerThreshold 以下（例如 < 47.5°C）
        if spinDownCooldownCycles > 0 {
            spinDownCooldownCycles -= 1
            let smoothRPM = max(baseRPM, lastOutputRPM - 300)
            lastOutputRPM = smoothRPM
            let desc = "❄️ 達標冷卻緩衝中：\(smoothRPM) RPM (即將完全停轉)"
            return (smoothRPM, desc)
        }

        // 完全冷卻達標，平順停轉
        lastOutputRPM = 0
        let desc = "【\(selectedSensorTarget.shortName)】\(String(format: "%.1f", currentTemp))°C ≤ 目標 \(targetTemp)°C (安全停轉)"
        return (0, desc)
    }

    private func dispatchFanRPM(_ rpm: Int) async {
        guard isHelperRunning else { return }
        if rpm == 0 {
            _ = await helperClient.setAllAuto()
        } else {
            _ = await helperClient.setAllFanSpeeds(rpm: rpm)
        }
    }

    public func selectSensorTarget(_ target: ThermalSensorTarget) {
        self.selectedSensorTarget = target
        self.smoothedTemperature = nil
        self.spinDownCooldownCycles = 0
        refresh()
        showMessage("已切換溫控基準元件至：\(target.displayName)")
    }

    public func installHelperAction() {
        isInstallingHelper = true
        errorMessage = nil
        Task {
            let res = await helperManager.installHelper()
            await MainActor.run {
                self.isInstallingHelper = false
                switch res {
                case .success:
                    self.isHelperInstalled = true
                    self.isHelperRunning = true
                    self.showMessage("✅ 已安裝，並通過實際 RPM 與硬體範圍讀回驗證")
                    self.refresh()
                case .failure(let err):
                    self.errorMessage = "安裝失敗：\(err)"
                }
            }
        }
    }

    public func uninstallHelperAction() {
        isInstallingHelper = true
        errorMessage = nil
        Task {
            _ = await helperClient.setAllAuto()
            let res = await helperManager.uninstallHelper()
            await MainActor.run {
                self.isInstallingHelper = false
                switch res {
                case .success:
                    self.isHelperInstalled = false
                    self.isHelperRunning = false
                    self.selectedMode = .automatic
                    self.showMessage("已成功解除安裝特權助手並還原原廠自動。")
                    self.refresh()
                case .failure(let err):
                    self.errorMessage = "解除安裝失敗：\(err)"
                }
            }
        }
    }

    public func selectMode(_ mode: FanMode) {
        self.selectedMode = mode
        self.spinDownCooldownCycles = 0
        refresh()
        showMessage("已要求切換散熱策略：\(mode.title)；以實際 RPM 讀回結果為準")
    }

    public func applyCustomRPM() {
        let rpm = Int(customRPM)
        let mode = FanMode.custom(rpm: rpm)
        self.selectedMode = mode
        self.spinDownCooldownCycles = 0
        refresh()
        showMessage("已要求設定目標轉速：\(rpm) RPM；目標值不等於實際 RPM")
    }

    private func showMessage(_ msg: String) {
        self.message = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.message == msg {
                self?.message = nil
            }
        }
    }
}
