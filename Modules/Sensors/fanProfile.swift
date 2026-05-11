//
//  fanProfile.swift
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
import Kit

// MARK: - Curve Shape

/// How temperature position maps to fan speed in the proportional zone.
public enum CurveShape: String, Codable, Equatable {
    /// pos × max — direct proportional response
    case linear
    /// pos² × max — quiet start, accelerates with heat
    case easeIn
    /// √pos × max — fast initial response, levels off
    case easeOut
    /// pos²(3-2pos) × max — smooth at both ends
    case sCurve
}

// MARK: - Curve

/// Defines how a profile maps temperature to fan speed.
public struct Curve: Codable, Equatable {
    /// Below this temperature the engine returns fans to Apple auto.
    /// Must be at least 5°C below startTemp.
    public var stopTemp: Double

    /// Above this temperature fans engage (after sustainedTriggerSec elapses).
    public var startTemp: Double

    /// Temperature at which fan reaches maxRPMPercent.
    public var ceilingTemp: Double

    /// Maximum fan speed as fraction of fan's hardware maxRPM (0.0–1.0).
    public var maxRPMPercent: Double

    /// If true this profile doesn't issue SMC writes — stays in Apple auto mode.
    public var handsOff: Bool

    /// Shape of the temperature-to-speed mapping in the proportional zone.
    public var curveShape: CurveShape

    /// Max speed increase per second (fraction of full range per second).
    /// Ignored on instantEngage profiles at the engagement edge.
    public var rampUpPerSec: Double

    /// Max speed decrease per second (fraction of full range per second).
    /// Always applied, even on instantEngage profiles.
    public var rampDownPerSec: Double

    /// Seconds of continuous temperature ≥ startTemp before the engine engages.
    /// Filters short transient spikes.
    public var sustainedTriggerSec: Double

    /// If true, skip ramp-up governor at engagement edge — jump directly to
    /// the curve's target fraction. Ramp-down still governs deceleration.
    public var instantEngage: Bool

    public init(
        stopTemp: Double = 50,
        startTemp: Double = 55,
        ceilingTemp: Double = 70,
        maxRPMPercent: Double = 0.6,
        handsOff: Bool = false,
        curveShape: CurveShape = .linear,
        rampUpPerSec: Double = 0.05,
        rampDownPerSec: Double = 0.025,
        sustainedTriggerSec: Double = 8,
        instantEngage: Bool = false
    ) {
        self.stopTemp = stopTemp
        self.startTemp = startTemp
        self.ceilingTemp = ceilingTemp
        self.maxRPMPercent = maxRPMPercent
        self.handsOff = handsOff
        self.curveShape = curveShape
        self.rampUpPerSec = rampUpPerSec
        self.rampDownPerSec = rampDownPerSec
        self.sustainedTriggerSec = sustainedTriggerSec
        self.instantEngage = instantEngage
    }

    /// Returns the raw target fraction (0.0–maxRPMPercent) for the given
    /// temperature, or nil when the engine should be idle (Apple auto).
    /// Does NOT apply ramp governors — caller handles slew limiting.
    public func targetFraction(at temp: Double) -> Double? {
        // Hands-off: never touch SMC
        if handsOff { return nil }

        // Below stop: return to auto
        if temp <= stopTemp { return nil }

        // Above startTemp: proportional zone
        if temp >= startTemp {
            // At or above ceiling: full max fraction
            if temp >= ceilingTemp { return maxRPMPercent }

            // instantEngage profiles jump to max once triggered — no proportional
            if instantEngage { return maxRPMPercent }

            let position = (temp - startTemp) / (ceilingTemp - startTemp)
            let shaped: Double
            switch curveShape {
            case .linear:
                shaped = position
            case .easeIn:
                shaped = position * position
            case .easeOut:
                shaped = sqrt(position)
            case .sCurve:
                shaped = position * position * (3 - 2 * position)
            }
            return shaped * maxRPMPercent
        }

        // Hysteresis band (stopTemp < temp < startTemp): engine decides based
        // on engagement state — return a sentinel that engine interprets as
        // "stay at minimum if already engaged, else off".
        return 0.0
    }
}

// MARK: - Fan Profile

// A fan profile binding a curve to one fan (by id) or all fans (fanID == -1).
public struct FanProfile: Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// fanID == -1 means "all fans"
    public var fanID: Int
    public var curve: Curve

    public init(id: UUID = UUID(), name: String, fanID: Int, curve: Curve) {
        self.id = id
        self.name = name
        self.fanID = fanID
        self.curve = curve
    }

    // Whether this profile is currently controlling fans.
    // Stored in Store.shared so it survives restarts without rewriting JSON.
    public var enabled: Bool {
        get { Store.shared.bool(key: "fanProfile_\(self.id.uuidString)_enabled", defaultValue: false) }
        set { Store.shared.set(key: "fanProfile_\(self.id.uuidString)_enabled", value: newValue) }
    }
}

// MARK: - Built-in presets

public enum FanProfilePreset: CaseIterable {
    case smart, full, automatic

    public var profile: FanProfile {
        switch self {
        case .smart:
            // Tuned from real LLM-workload telemetry on Apple Silicon:
            //  - workload bursts hot/cold rapidly (+15°C / -19°C in 5s windows)
            //  - silicon-bound past ~80°C (more fan can't help further)
            //  - cool windows reach 58-65°C — must release fans there
            return FanProfile(
                name: "Smart",
                fanID: -1,
                curve: Curve(
                    stopTemp: 55, startTemp: 65, ceilingTemp: 80,
                    maxRPMPercent: 1.0,
                    curveShape: .sCurve,
                    rampUpPerSec: 0.15, rampDownPerSec: 0.10,
                    sustainedTriggerSec: 2
                )
            )
        case .full:
            // Always blast 100%. Engages immediately, never disengages while running.
            return FanProfile(
                name: "Full",
                fanID: -1,
                curve: Curve(
                    stopTemp: 0, startTemp: 0, ceilingTemp: 1,
                    maxRPMPercent: 1.0,
                    curveShape: .linear,
                    rampUpPerSec: 1.0, rampDownPerSec: 1.0,
                    sustainedTriggerSec: 0,
                    instantEngage: true
                )
            )
        case .automatic:
            // Hands-off: let Apple's firmware manage fans. Engine releases the
            // fan to .automatic once and then writes nothing.
            return FanProfile(
                name: "Automatic (Apple)",
                fanID: -1,
                curve: Curve(
                    stopTemp: 50, startTemp: 50, ceilingTemp: 50,
                    maxRPMPercent: 0,
                    handsOff: true
                )
            )
        }
    }
}

// MARK: - JSON persistence

// Profile bodies live in a JSON file in Application Support.
// Enabled flags live in Store.shared so they round-trip through Stats' prefs.
public class FanProfileStore {
    private static let fileName = "fan-profiles.json"

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Stats")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(fileName)
    }

    public static func load() -> [FanProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([FanProfile].self, from: data)) ?? []
    }

    public static func save(_ profiles: [FanProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

#endif
