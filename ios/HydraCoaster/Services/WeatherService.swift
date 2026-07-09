import Foundation
import os

/// OWM credentials/location, read from Info.plist keys that resolve to
/// `Secrets.xcconfig` build settings (see ios/Secrets.xcconfig.example).
/// `nil` when the key is missing or still the placeholder from the example
/// file — that's the "weather quietly disabled" path, not an error.
struct WeatherConfig {
    private static let placeholderAPIKey = "YOUR_OWM_API_KEY_HERE"

    let apiKey: String
    let lat: Double
    let lon: Double

    init?(bundle: Bundle = .main) {
        guard
            let apiKey = bundle.object(forInfoDictionaryKey: "OWMAPIKey") as? String,
            !apiKey.isEmpty, apiKey != Self.placeholderAPIKey,
            let latString = bundle.object(forInfoDictionaryKey: "OWMLat") as? String,
            let lonString = bundle.object(forInfoDictionaryKey: "OWMLon") as? String,
            let lat = Double(latString),
            let lon = Double(lonString)
        else { return nil }
        self.apiKey = apiKey
        self.lat = lat
        self.lon = lon
    }
}

/// Fetches current temperature/humidity and turns them into the D005
/// interval — the SAME rules the firmware/Python POC use, minus the
/// behavior factor (the coaster adds its own on top; the phone's mirrored
/// reminder adds its own separately in ReminderScheduler). Disabled
/// entirely — no network calls, no writes — when `WeatherConfig` is nil.
@Observable
@MainActor
final class WeatherService {
    struct Reading: Equatable {
        let tempC: Double
        let humidity: Double
    }

    // Last successful fetch, for the debug panel.
    private(set) var lastReading: Reading?
    private(set) var lastFactor: Double?
    private(set) var lastInterval: UInt16?
    private(set) var lastFetchAt: Date?
    var isEnabled: Bool { config != nil }

    private let config: WeatherConfig?
    private let logger = Logger(subsystem: "com.ronav.HydraCoaster", category: "WeatherService")
    private var loopTask: Task<Void, Never>?

    /// Fires with the freshly computed, behavior-free D005 interval after
    /// each successful fetch. The caller (AppServices) writes it to the
    /// coaster and reschedules the mirrored reminder.
    var onWeatherUpdate: ((UInt16) -> Void)?

    init(bundle: Bundle = .main) {
        config = WeatherConfig(bundle: bundle)
        if config == nil {
            logger.info("weather disabled: OWM_API_KEY missing or placeholder")
        } else {
            logger.info("weather enabled")
        }
    }

    /// Fetches immediately, then every 30 minutes, until `stop()`. No-op
    /// when disabled or already running — safe to call on every connect.
    func start() {
        guard let config, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(config: config)
                try? await Task.sleep(for: weatherRefreshInterval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func tick(config: WeatherConfig) async {
        guard let data = await Self.fetchData(config: config), let reading = Self.decode(data) else {
            // ponytail: keep the last-written interval and just retry next
            // cycle — a transient network blip shouldn't touch D005 or spam
            // logs beyond one line.
            logger.error("weather fetch failed, keeping last interval")
            return
        }
        let factor = Self.factor(tempC: reading.tempC, humidity: reading.humidity)
        let interval = Self.intervalSeconds(factor: factor)
        lastReading = reading
        lastFactor = factor
        lastInterval = interval
        lastFetchAt = Date()
        onWeatherUpdate?(interval)
    }

    private nonisolated static func fetchData(config: WeatherConfig) async -> Data? {
        var components = URLComponents(string: weatherEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(config.lat)),
            URLQueryItem(name: "lon", value: String(config.lon)),
            URLQueryItem(name: "appid", value: config.apiKey),
            URLQueryItem(name: "units", value: "metric"),
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        } catch {
            return nil
        }
    }

    /// Pulls only `main.temp` and `main.humidity` — everything else in the
    /// OWM response is ignored (and Decodable ignores unknown keys, so
    /// there's nothing else to opt out of).
    nonisolated static func decode(_ data: Data) -> Reading? {
        struct Response: Decodable {
            struct Main: Decodable {
                let temp: Double
                let humidity: Double
            }
            let main: Main
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return Reading(tempC: response.main.temp, humidity: response.main.humidity)
    }

    /// Same thresholds as firmware/Python: hot cuts the interval hard, dry
    /// cuts it further on top.
    nonisolated static func factor(tempC: Double?, humidity: Double?) -> Double {
        var factor = 1.0
        if let tempC {
            if tempC >= 30 {
                factor = 0.5
            } else if tempC >= 25 {
                factor = 0.75
            }
        }
        if let humidity, humidity < 30 {
            factor *= 0.85
        }
        return factor
    }

    nonisolated static func intervalSeconds(factor: Double) -> UInt16 {
        let seconds = (1200.0 * factor).rounded()
        return UInt16(seconds.clamped(to: 60...14400))
    }
}

private let weatherRefreshInterval: Duration = .seconds(30 * 60)
private let weatherEndpoint = "https://api.openweathermap.org/data/2.5/weather"

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
