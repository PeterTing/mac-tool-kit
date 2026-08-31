import SwiftUI
import MacToolKitCore

public struct OverviewView: View {
    @ObservedObject var dashboardVM: DashboardViewModel
    @ObservedObject var lagVM: LagDetectiveViewModel

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Top Status & Lag Banner
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 10, height: 10)
                            Text("Mac 系統狀態總覽")
                                .font(.title2.bold())
                        }
                        Text("顯示各來源的最新取樣；不可取得與衍生值會明確標示")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    Button {
                        dashboardVM.selectedTab = .lagDetective
                        lagVM.runDiagnosis(from: dashboardVM)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stethoscope")
                                .font(.system(size: 14, weight: .bold))
                            Text("立即診斷 Lag")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                // Feedback Banner if any
                if let msg = dashboardVM.statusMessage {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(msg)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(10)
                }

                // Grid 1: Gauges (CPU & Memory)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    // CPU Card
                    GlassCard(title: "處理器 (CPU)", iconName: "cpu", accentColor: .blue) {
                        HStack(spacing: 20) {
                            CircularGaugeView(
                                percentage: dashboardVM.cpuSnapshot.totalUsage,
                                title: "總使用率",
                                subtitle: "\(dashboardVM.cpuSnapshot.logicalCores) 核心",
                                iconName: "cpu",
                                size: 100
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("使用者:").foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f%%", dashboardVM.cpuSnapshot.userUsage)).bold()
                                }
                                HStack {
                                    Text("系統核心:").foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f%%", dashboardVM.cpuSnapshot.systemUsage)).bold()
                                }
                                HStack {
                                    Text("閒置:").foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f%%", dashboardVM.cpuSnapshot.idleUsage)).foregroundColor(.secondary)
                                }

                                SparklineView(data: dashboardVM.cpuHistory, lineColor: .blue, fillColor: .blue.opacity(0.2))
                                    .frame(height: 35)
                            }
                            .font(.system(size: 12))
                        }
                    }

                    // RAM Card
                    GlassCard(title: "記憶體（衍生使用量）", iconName: "memorychip", accentColor: .purple) {
                        HStack(spacing: 20) {
                            CircularGaugeView(
                                percentage: dashboardVM.memorySnapshot.usedPercentage,
                                title: "衍生使用量",
                                subtitle: "\(String(format: "%.1f", Double(dashboardVM.memorySnapshot.usedBytes) / (1024*1024*1024))) / \(String(format: "%.0f", Double(dashboardVM.memorySnapshot.totalPhysicalBytes) / (1024*1024*1024))) GiB",
                                iconName: "memorychip",
                                size: 100
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("活躍 RAM:").foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(dashboardVM.memorySnapshot.activeBytes / (1024*1024)) MiB (\(String(format: "%.1f%%", (Double(dashboardVM.memorySnapshot.activeBytes) / Double(max(1, dashboardVM.memorySnapshot.totalPhysicalBytes))) * 100.0)))").bold()
                                }
                                HStack {
                                    Text("壓縮記憶體:").foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(dashboardVM.memorySnapshot.compressedBytes / (1024*1024)) MiB").bold()
                                }
                                HStack {
                                    Text("Dashboard 衍生壓力:").foregroundColor(.secondary)
                                    Spacer()
                                    Text(dashboardVM.memorySnapshot.pressureState.rawValue)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(dashboardVM.memorySnapshot.pressureState == .normal ? .green : .red)
                                }

                                SparklineView(data: dashboardVM.memoryHistory, lineColor: .purple, fillColor: .purple.opacity(0.2))
                                    .frame(height: 35)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }

                // GPU Card (full width strip)
                GlassCard(title: "繪圖處理器 (GPU)", iconName: "cpu.fill", accentColor: .orange) {
                    HStack(spacing: 20) {
                        CircularGaugeView(
                            percentage: dashboardVM.gpuSnapshot.utilization,
                            title: "使用率",
                            subtitle: dashboardVM.gpuSnapshot.deviceName.isEmpty ? "GPU" : dashboardVM.gpuSnapshot.deviceName,
                            iconName: "cpu.fill",
                            size: 100
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("統一記憶體佔用:").foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.2f GiB", Double(dashboardVM.gpuSnapshot.inUseMemoryBytes) / (1024*1024*1024))).bold()
                            }
                            HStack {
                                Text("Renderer:").foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.0f%%", dashboardVM.gpuSnapshot.rendererUtilization)).bold()
                            }
                            HStack {
                                Text("Tiler:").foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.0f%%", dashboardVM.gpuSnapshot.tilerUtilization)).bold()
                            }
                        }
                        .font(.system(size: 12))
                        .frame(width: 220)

                        SparklineView(data: dashboardVM.gpuHistory, lineColor: .orange, fillColor: .orange.opacity(0.2))
                            .frame(height: 70)
                    }
                }

                // Grid 2: Storage & Network & Thermal
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    // Storage
                    GlassCard(title: "磁碟儲存", iconName: "internaldrive", accentColor: .orange) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let mainVol = dashboardVM.diskVolumes.first {
                                Text(mainVol.name)
                                    .font(.headline)

                                ProgressView(value: mainVol.usedPercentage, total: 100.0)
                                    .tint(mainVol.usedPercentage > 85 ? .red : .orange)

                                HStack {
                                    Text("可用: \(mainVol.freeBytes / (1024*1024*1024)) GiB")
                                        .font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    Text("總計: \(mainVol.totalBytes / (1024*1024*1024)) GiB")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            } else {
                                Text("正在偵測磁碟...")
                                    .font(.caption).foregroundColor(.secondary)
                            }

                            Divider()

                            HStack {
                                Label("\(String(format: "%.1f", dashboardVM.diskIOSnapshot.readBytesPerSec / (1024*1024))) MiB/s", systemImage: "arrow.down.circle")
                                    .font(.caption)
                                Spacer()
                                Label("\(String(format: "%.1f", dashboardVM.diskIOSnapshot.writeBytesPerSec / (1024*1024))) MiB/s", systemImage: "arrow.up.circle")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                    }

                    // Network
                    GlassCard(title: "網路即時傳輸", iconName: "network", accentColor: .teal) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "arrow.down.forward")
                                    .foregroundColor(.teal)
                                Text("下載:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formatSpeed(dashboardVM.networkIOSnapshot.downloadBytesPerSec))
                                    .bold()
                            }
                            .font(.system(size: 13))

                            HStack {
                                Image(systemName: "arrow.up.forward")
                                    .foregroundColor(.blue)
                                Text("上傳:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formatSpeed(dashboardVM.networkIOSnapshot.uploadBytesPerSec))
                                    .bold()
                            }
                            .font(.system(size: 13))

                            SparklineView(data: dashboardVM.networkDownHistory, lineColor: .teal, fillColor: .teal.opacity(0.15))
                                .frame(height: 40)
                        }
                    }

                    // Thermal & Battery
                    GlassCard(title: "散熱與電量", iconName: "flame", accentColor: .red) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("晶片熱狀態:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                StatBadge(text: dashboardVM.batteryThermalSnapshot.thermalState.rawValue, color: dashboardVM.batteryThermalSnapshot.thermalState == .nominal ? .green : .orange)
                            }
                            .font(.system(size: 12))

                            if dashboardVM.batteryThermalSnapshot.hasBattery {
                                HStack {
                                    Text("電池電量:").foregroundColor(.secondary)
                                    Spacer()
                                    Text(dashboardVM.batteryThermalSnapshot.batteryPercentage.map { "\($0)% \(dashboardVM.batteryThermalSnapshot.isCharging ? "⚡" : "")" } ?? "不可取得").bold()
                                }
                                .font(.system(size: 12))

                                HStack {
                                    Text("電池溫度:").foregroundColor(.secondary)
                                    Spacer()
                                    Text(formatOptionalTemperature(dashboardVM.batteryThermalSnapshot.batteryTemperatureCelsius)).bold()
                                }
                                .font(.system(size: 12))
                            }

                            Divider()

                            HStack {
                                Text("風扇轉速:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(dashboardVM.fanStatuses.first.map { "\($0.currentRPM) RPM（實際讀回）" } ?? "不可取得")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.accentColor)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }

                // Docker Containers Live Breakdown (if running)
                if !dashboardVM.dockerContainers.isEmpty {
                    GlassCard(title: "Docker 運行中容器資源拆解 (Docker Containers Breakdown)", iconName: "shippingbox.fill", accentColor: .blue) {
                        VStack(spacing: 8) {
                            ForEach(dashboardVM.dockerContainers) { container in
                                HStack(spacing: 12) {
                                    Image(systemName: "shippingbox.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.blue)
                                        .frame(width: 24, height: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(container.name)
                                                .font(.system(size: 13, weight: .bold))
                                            Text("(\(container.image.prefix(24)))")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }

                                        Text("ID: \(container.containerId.prefix(12)) • 狀態: \(container.status)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(String(format: "%.2f%% CPU", container.cpuPercentage))
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(container.cpuPercentage > 10 ? .orange : .primary)
                                        Text("\(container.memoryUsage) (\(String(format: "%.1f%%", container.memoryPercentage)))")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)

                                if container.id != dashboardVM.dockerContainers.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                // Top Resource Consumers Preview
                GlassCard(title: "高資源消耗應用程式 (Top Consumers)", iconName: "list.bullet.rectangle.portrait", accentColor: .indigo) {
                    VStack(spacing: 8) {
                        ForEach(dashboardVM.filteredProcesses.prefix(5)) { proc in
                            HStack(spacing: 12) {
                                Image(systemName: proc.category.iconName)
                                    .font(.system(size: 16))
                                    .foregroundColor(proc.isUserApp ? .blue : .purple)
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(proc.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("[\(proc.category.rawValue)]")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)

                                        if let proj = proc.projectName {
                                            Text("📁 \(proj)")
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.blue.opacity(0.12))
                                                .foregroundColor(.blue)
                                                .cornerRadius(4)
                                        }

                                        if let ai = proc.aiContext {
                                            HStack(spacing: 4) {
                                                Image(systemName: "brain.head.profile")
                                                    .font(.system(size: 9))
                                                Text(ai.displayBadge)
                                                    .font(.system(size: 10, weight: .bold))
                                            }
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.purple.opacity(0.15))
                                            .foregroundColor(.purple)
                                            .cornerRadius(4)
                                        }
                                    }

                                    HStack(spacing: 6) {
                                        if let trigger = proc.triggerAppName {
                                            Text("來自: \(trigger)")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }

                                        Text("PID \(proc.pid) • 已運作 \(proc.formattedUptime)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "%.1f%% CPU", proc.cpuPercentage))
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(proc.cpuPercentage > 50 ? .red : (proc.cpuPercentage > 20 ? .orange : .primary))
                                    Text("\(formatMemory(proc.memoryBytes)) (\(String(format: "%.1f%%", proc.memoryPercentage)))")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .help("行程說明：\(proc.terminationImpact)\(proc.commandLine != nil ? "\n指令：\(proc.commandLine!)" : "")\(proc.workingDirectory != nil ? "\n目錄：\(proc.workingDirectory!)" : "")")

                            if proc.id != dashboardVM.filteredProcesses.prefix(5).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func formatOptionalTemperature(_ value: Double?) -> String {
        value.map { String(format: "%.1f °C", $0) } ?? "不可取得"
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GiB", mb / 1024)
        } else {
            return String(format: "%.0f MiB", mb)
        }
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024 * 1024 {
            return String(format: "%.1f MiB/s", bytesPerSec / (1024 * 1024))
        } else {
            return String(format: "%.1f KiB/s", bytesPerSec / 1024)
        }
    }
}
