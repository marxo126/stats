//
//  fanProfileEngine.swift
//  Sensors
//
//  Created for Stats fan profile engine.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

#if arch(arm64)

import Foundation
import IOKit.ps
import Kit

// MARK: - Power source detection

private enum PowerSource: String {
    case ac, battery, unknown

    static var current: PowerSource {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let typeRef = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() else {
            return .unknown
        }
        let type = typeRef as String
        if type == kIOPSACPowerValue { return .ac }
        if type == kIOPSBatteryPowerValue { return .battery }
        return .unknown
    }
}

// MARK: - CSV telemetry logger

private final class TelemetryLogger {
    static let shared = TelemetryLogger()

    private let url: URL
    private let queue = DispatchQueue(label: "eu.exelban.Stats.FanTelemetry")
    private var handle: FileHandle?
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stats")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("fan-telemetry.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "timestamp,driver_temp,cpu_max_temp,gpu_max_temp,vent_max_temp,power_source,slope_c_per_s,fan_id,actual_rpm,profile,engaged,safety,target_fraction,target_rpm,sustained_s\n"
            try? header.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    func log(timestamp: Date, driverTemp: Double, cpuMax: Double, gpuMax: Double,
             ventMax: Double, powerSource: String, slope: Double, fanID: Int,
             actualRPM: Double, profile: String?, engaged: Bool, safety: Bool,
             fraction: Double, targetRPM: Int, sustained: TimeInterval?) {
        let ts = isoFormatter.string(from: timestamp)
        let prof = profile ?? ""
        let sus = sustained.map { String(format: "%.1f", $0) } ?? ""
        let line = "\(ts),\(String(format: "%.1f", driverTemp)),\(String(format: "%.1f", cpuMax)),\(String(format: "%.1f", gpuMax)),\(String(format: "%.1f", ventMax)),\(powerSource),\(String(format: "%.2f", slope)),\(fanID),\(String(format: "%.0f", actualRPM)),\(prof),\(engaged),\(safety),\(String(format: "%.4f", fraction)),\(targetRPM),\(sus)\n"
        queue.async { [weak self] in
            guard let self, let data = line.data(using: .utf8) else { return }
            if self.handle == nil {
                self.handle = try? FileHandle(forWritingTo: self.url)
                _ = try? self.handle?.seekToEnd()
            }
            try? self.handle?.write(contentsOf: data)
        }
    }
}

// Minimum RPM delta before issuing a new setFanSpeed SMC call.
// Prevents constant SMC churn when temperature hovers around a curve knee.
private let hysteresisRPMThreshold: Int = 100

// Cap how often the engine acts regardless of how fast the sensor reader fires.
private let minTickInterval: TimeInterval = 1.0

// Safety override: above this temperature, jump to maxRPMPercent immediately
// regardless of sustainedTriggerSec / ramp governor. Clears via 5° hysteresis.
// M-series throttles ~83°C GPU under sustained LLM workloads — 92°C is a
// "should never reach this" backstop, not normal operating territory.
private let safetyOverrideTemp: Double = 92.0
private let safetyOverrideClearTemp: Double = 87.0

// MARK: - Per-fan runtime state

private struct FanState {
    /// True once sustainedTriggerSec has elapsed and the engine has written
    /// at least one SMC speed command for this fan.
    var engaged: Bool = false

    /// The moment temperature first crossed startTemp on this engagement cycle.
    /// Reset to nil whenever temp falls below startTemp.
    var sustainedSince: Date? = nil

    /// Last fraction written to SMC (0.0–1.0 of fan's full RPM range).
    /// Used by the ramp governor to limit per-tick speed change.
    var lastFraction: Double = 0.0

    /// Last RPM written to SMC — used for the 100-RPM hysteresis gate.
    var lastSetRPM: Int = 0

    /// True if we previously wrote resetAuto for this fan on this disengage
    /// cycle — prevents spamming setFanMode(.automatic) every tick.
    var autoWritten: Bool = false

    /// True while temp is in the safety override band (≥92°C, clears <87°C).
    /// Logged to telemetry so we can see how often it fires.
    var safetyActive: Bool = false
}

// MARK: - Engine

public class FanProfileEngine {
    public static let shared = FanProfileEngine()

    private var profiles: [FanProfile] = []
    private var fanStates: [Int: FanState] = [:]
    private var fanBounds: [Int: (min: Double, max: Double)] = [:]
    private var lastTickDate: Date = .distantPast
    private let queue = DispatchQueue(label: "eu.exelban.Stats.FanProfileEngine", qos: .utility)

    // Rolling driver-temp history for rate-of-change boost. 4 samples at 1 Hz
    // = 3-second window. Smooths sensor jitter (~1-2°C noise floor) before
    // computing slope, since raw consecutive-sample derivative amplifies noise.
    private var tempHistory: [Double] = []
    private static let tempHistoryCapacity = 4

    private init() {
        // Graceful migration: old JSON used [CurvePoint] schema. If the decode
        // fails the store just returns [], and the user picks a new preset.
        self.profiles = FanProfileStore.load()
    }

    // MARK: - Public API

    public var allProfiles: [FanProfile] { profiles }

    public func profileForFan(_ fanID: Int) -> FanProfile? {
        profiles.first(where: { $0.enabled && ($0.fanID == fanID || $0.fanID == -1) })
    }

    public func addProfile(_ profile: FanProfile) {
        profiles.append(profile)
        FanProfileStore.save(profiles)
    }

    public func updateProfile(_ profile: FanProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        FanProfileStore.save(profiles)
    }

    public func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        Store.shared.remove("fanProfile_\(id.uuidString)_enabled")
        FanProfileStore.save(profiles)
    }

    /// Called by main.swift once the sensor list is available.
    public func registerFans(_ fans: [Fan]) {
        for fan in fans {
            fanBounds[fan.id] = (min: fan.minSpeed, max: fan.maxSpeed)
        }
    }

    /// Called from the sensor reader callback in main.swift on every tick.
    public func processTick(_ sensors: [Sensor_p]) {
        queue.async { [weak self] in
            guard let self else { return }

            let now = Date()
            let rawDt = now.timeIntervalSince(self.lastTickDate)
            guard rawDt >= minTickInterval else { return }
            self.lastTickDate = now

            // Wake / cold-start detection. .distantPast first tick or any gap
            // longer than 30s (sleep, app pause) means accumulated state is
            // stale: reset per-fan engagement so the ramp budget can't blow up
            // and so we don't race PR1's FanPowerManager wake restore.
            if rawDt > 30 {
                self.fanStates = [:]
                self.tempHistory = []
                return
            }
            let dt = min(rawDt, 5.0)

            let enabledProfiles = self.profiles.filter { $0.enabled }
            guard !enabledProfiles.isEmpty else { return }

            // Max temperature across CPU and GPU sensor groups. Apple Silicon parks
            // efficiency cores under low load (≤5°C noise floor); filter those.
            // GPU group includes a miscategorized NAND CH% sensor in some builds —
            // exclude by name pattern.
            let cpuTemps = sensors
                .filter { $0.type == .temperature && $0.group == .CPU && $0.value > 5 }
                .map { $0.value }
            let gpuTemps = sensors
                .filter { $0.type == .temperature && $0.group == .GPU && $0.value > 5
                          && !$0.key.contains("NAND") && !$0.name.contains("NAND") }
                .map { $0.value }
            let cpuMax = cpuTemps.max() ?? 0
            let gpuMax = gpuTemps.max() ?? 0
            // Vent / airflow sensors (TaLP / TaRF / TaLW / TaRW) — surface
            // temperature proxy. Lap-comfort driver, optional alternative to
            // die temp. Currently logged only; not yet used as primary driver.
            let ventTemps = sensors
                .filter { $0.type == .temperature && $0.group == .sensor && $0.value > 5
                          && $0.name.contains("Airflow") }
                .map { $0.value }
            let ventMax = ventTemps.max() ?? 0
            let driverTemp = max(cpuMax, gpuMax)
            guard driverTemp > 0 else { return }
            let powerSource = PowerSource.current

            // Update rolling temp history + compute slope (°C/sec). Only valid
            // once buffer is full to avoid noisy 1- or 2-sample slopes.
            self.tempHistory.append(driverTemp)
            if self.tempHistory.count > Self.tempHistoryCapacity {
                self.tempHistory.removeFirst()
            }
            let slope: Double
            if self.tempHistory.count == Self.tempHistoryCapacity {
                let span = Double(Self.tempHistoryCapacity - 1)  // 3 ticks ≈ 3 s at 1 Hz
                slope = (self.tempHistory.last! - self.tempHistory.first!) / span
            } else {
                slope = 0
            }

            // Skip pseudo-fans (id < 0 = aggregates like "fastest fan").
            let fans = sensors.compactMap { $0 as? Fan }.filter { $0.id >= 0 }

            for fan in fans {
                let profile = self.profileForFan(fan.id)
                if profile == nil {
                    if self.fanStates[fan.id]?.engaged == true {
                        SMCHelper.shared.setFanMode(fan.id, mode: FanMode.automatic.rawValue)
                        self.fanStates[fan.id] = FanState()
                    }
                } else {
                    self.processFan(fan, profile: profile!, temp: driverTemp, slope: slope, dt: dt, now: now)
                }

                let state = self.fanStates[fan.id] ?? FanState()
                let sustained = state.sustainedSince.map { now.timeIntervalSince($0) }
                TelemetryLogger.shared.log(
                    timestamp: now,
                    driverTemp: driverTemp,
                    cpuMax: cpuMax,
                    gpuMax: gpuMax,
                    ventMax: ventMax,
                    powerSource: powerSource.rawValue,
                    slope: slope,
                    fanID: fan.id,
                    actualRPM: fan.value,
                    profile: profile?.name,
                    engaged: state.engaged,
                    safety: state.safetyActive,
                    fraction: state.lastFraction,
                    targetRPM: state.lastSetRPM,
                    sustained: sustained
                )
            }
        }
    }

    /// Release all engine-owned fans back to Apple auto on app quit.
    /// Synchronous — willTerminate gives only ~5s before the process exits;
    /// an async dispatch can be skipped entirely if the main thread is busy.
    public func releaseAll(fans: [Fan]) {
        queue.sync {
            for fan in fans {
                guard self.fanStates[fan.id] != nil else { continue }
                SMCHelper.shared.setFanMode(fan.id, mode: FanMode.automatic.rawValue)
            }
            self.fanStates = [:]
        }
    }

    // MARK: - Per-fan tick logic

    private func processFan(_ fan: Fan, profile: FanProfile, temp: Double, slope: Double, dt: TimeInterval, now: Date) {
        let curve = profile.curve
        var state = fanStates[fan.id] ?? FanState()
        defer { fanStates[fan.id] = state }

        let bounds = fanBounds[fan.id]
        let minRPM = bounds?.min ?? 0
        let maxRPM = bounds.map { $0.max } ?? Double(fan.maxSpeed > 0 ? fan.maxSpeed : 6000)

        // ── Safety override: ≥92°C bypasses sustained timer + ramp governor ──
        // Apple Silicon throttles ~83°C GPU under sustained LLM. 92°C means
        // something is wrong — blast 100% immediately. Clears at <87°C
        // (5° hysteresis to avoid flapping).
        if !curve.handsOff && temp >= safetyOverrideTemp {
            state.engaged = true
            state.sustainedSince = state.sustainedSince ?? now
            state.safetyActive = true
            let target = curve.maxRPMPercent > 0 ? curve.maxRPMPercent : 1.0
            applyFraction(target, fan: fan, state: &state, minRPM: minRPM, maxRPM: maxRPM, profile: profile)
            return
        }
        if state.safetyActive && temp < safetyOverrideClearTemp {
            state.safetyActive = false
        }

        // ── Hands-off profile (Automatic) ───────────────────────────────────
        // Do not write fan speeds. If we previously held it, release once.
        if curve.handsOff {
            if state.engaged && !state.autoWritten {
                SMCHelper.shared.setFanMode(fan.id, mode: FanMode.automatic.rawValue)
                state = FanState()
                state.autoWritten = true
            }
            return
        }

        // ── Disengage: temp below stopTemp ──────────────────────────────────
        if temp <= curve.stopTemp {
            if state.engaged {
                NSLog("FanProfileEngine: fan %d off (%.1f°C ≤ %.0f°C stopTemp) [%@]",
                      fan.id, temp, curve.stopTemp, profile.name)
                SMCHelper.shared.setFanMode(fan.id, mode: FanMode.automatic.rawValue)
            }
            state = FanState()
            return
        }

        // ── Hysteresis band: stopTemp < temp < startTemp ────────────────────
        // If already engaged, coast down toward minimum via the ramp governor;
        // otherwise stay idle.
        if temp < curve.startTemp {
            if !state.engaged {
                state.sustainedSince = nil
                return
            }
            let minFraction = maxRPM > 0 ? minRPM / maxRPM : 0
            let rampDownBudget = curve.rampDownPerSec * dt
            var coastTarget = state.lastFraction
            if coastTarget > minFraction {
                coastTarget = max(minFraction, coastTarget - rampDownBudget)
            }
            applyFraction(coastTarget, fan: fan, state: &state, minRPM: minRPM, maxRPM: maxRPM, profile: profile)
            return
        }

        // ── Above startTemp ─────────────────────────────────────────────────
        // Start sustained timer on first crossing.
        if state.sustainedSince == nil {
            state.sustainedSince = now
        }

        // Wait for sustained trigger before engaging.
        if !state.engaged {
            let elapsed = now.timeIntervalSince(state.sustainedSince!)
            if elapsed < curve.sustainedTriggerSec {
                NSLog("FanProfileEngine: fan %d waiting for sustained trigger (%.1f/%.0fs) at %.1f°C [%@]",
                      fan.id, elapsed, curve.sustainedTriggerSec, temp, profile.name)
                return
            }
            // Trigger met — engage.
            NSLog("FanProfileEngine: fan %d engaging after %.1fs sustained at %.1f°C [%@]",
                  fan.id, elapsed, temp, profile.name)
            state.engaged = true
        }

        // ── Compute raw target fraction via curve ───────────────────────────
        guard let rawFraction = curve.targetFraction(at: temp) else {
            // targetFraction returns nil only for handsOff or temp≤stopTemp,
            // both handled above. Defensive path: disengage.
            SMCHelper.shared.setFanMode(fan.id, mode: FanMode.automatic.rawValue)
            state = FanState()
            return
        }

        // Hysteresis sentinel: curve returned 0.0 meaning "stay at minimum"
        let minFraction = maxRPM > 0 ? minRPM / maxRPM : 0
        var targetFraction = rawFraction <= 0.0 ? minFraction : rawFraction

        // ── Rate-of-change boost (rising only) ──────────────────────────────
        // Add slope-proportional kick to target during fast climbs. Mirrors
        // ThermalForge's approach: factor scales 0.15→0.30 with urgency
        // (how close temp is to ceilingTemp). Boost only when:
        //   - already engaged (sustained timer passed)
        //   - slope > 0 (temp rising)
        //   - safety override not active (already at maxRPMPercent there)
        if state.engaged && !state.safetyActive && slope > 0 {
            let denom = max(1.0, curve.ceilingTemp - curve.startTemp)
            let urgency = max(0, min(1, (temp - curve.startTemp) / denom))
            let boostFactor = 0.15 + urgency * 0.15
            targetFraction += boostFactor * slope
        }

        // Clamp to [minFraction, maxRPMPercent]
        targetFraction = max(minFraction, min(curve.maxRPMPercent, targetFraction))

        // ── Ramp governor ───────────────────────────────────────────────────
        // Per-tick budget is (ratePerSec × dt). dt is ≥ minTickInterval (1s)
        // so at steady state this equals the config rate.
        let rampUpBudget  = curve.rampUpPerSec  * dt
        let rampDownBudget = curve.rampDownPerSec * dt

        if targetFraction > state.lastFraction {
            // instantEngage profiles bypass the ramp-UP governor on every
            // upward move (matches TF behaviour). Ramp-DOWN still governs.
            if !curve.instantEngage {
                targetFraction = min(targetFraction, state.lastFraction + rampUpBudget)
            }
        } else if targetFraction < state.lastFraction {
            targetFraction = max(targetFraction, state.lastFraction - rampDownBudget)
        }

        applyFraction(targetFraction, fan: fan, state: &state, minRPM: minRPM, maxRPM: maxRPM, profile: profile)
    }

    // MARK: - SMC write with hysteresis gate

    private func applyFraction(_ fraction: Double, fan: Fan, state: inout FanState,
                               minRPM: Double, maxRPM: Double, profile: FanProfile) {
        // Update lastFraction first — the ramp governor reads it next tick and
        // must see the latest target, even if the SMC write is hysteresis-skipped.
        // Otherwise small ramp steps that round to the same RPM never advance
        // the state, and the budget compounds incorrectly.
        state.lastFraction = fraction

        let targetRPM = max(minRPM, min(maxRPM, maxRPM * fraction))
        let targetRPMInt = Int(targetRPM.rounded())

        if abs(targetRPMInt - state.lastSetRPM) < hysteresisRPMThreshold { return }

        SMCHelper.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
        SMCHelper.shared.setFanSpeed(fan.id, speed: targetRPMInt)

        NSLog("FanProfileEngine: fan %d → %d RPM (%.3f fraction) [%@]",
              fan.id, targetRPMInt, fraction, profile.name)

        state.lastSetRPM  = targetRPMInt
        state.autoWritten = false
    }
}

#endif
