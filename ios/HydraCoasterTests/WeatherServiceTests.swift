import Foundation
import Testing

@testable import HydraCoaster

struct WeatherServiceTests {

    // MARK: - factor(tempC:humidity:)

    @Test func factor_noReadings_isOne() {
        #expect(WeatherService.factor(tempC: nil, humidity: nil) == 1.0)
    }

    @Test func factor_justBelowHotThreshold_isUnaffectedByHotBand() {
        #expect(WeatherService.factor(tempC: 29.9, humidity: nil) == 0.75)
    }

    @Test func factor_atHotThreshold_isHalf() {
        #expect(WeatherService.factor(tempC: 30.0, humidity: nil) == 0.5)
    }

    @Test func factor_justBelowWarmThreshold_isBaseline() {
        #expect(WeatherService.factor(tempC: 24.9, humidity: nil) == 1.0)
    }

    @Test func factor_atWarmThreshold_isThreeQuarters() {
        #expect(WeatherService.factor(tempC: 25.0, humidity: nil) == 0.75)
    }

    @Test func factor_justAboveDryThreshold_isUnaffectedByDryMultiplier() {
        #expect(WeatherService.factor(tempC: nil, humidity: 29.9) == 0.85)
    }

    @Test func factor_atDryThreshold_isBaseline() {
        #expect(WeatherService.factor(tempC: nil, humidity: 30.0) == 1.0)
    }

    @Test func factor_hotAndDry_multipliesBothCuts() {
        #expect(WeatherService.factor(tempC: 30.0, humidity: 29.9) == 0.5 * 0.85)
    }

    @Test func factor_warmAndDry_multipliesBothCuts() {
        #expect(WeatherService.factor(tempC: 25.0, humidity: 20.0) == 0.75 * 0.85)
    }

    // MARK: - intervalSeconds(factor:)

    @Test func intervalSeconds_baselineFactor_is1200() {
        #expect(WeatherService.intervalSeconds(factor: 1.0) == 1200)
    }

    @Test func intervalSeconds_roundsToNearestSecond() {
        // 1200 * 0.75 = 900 exactly; 1200 * (0.75 * 0.85) = 765 exactly —
        // pick a factor that forces a genuine rounding decision.
        #expect(WeatherService.intervalSeconds(factor: 0.10004) == UInt16((1200.0 * 0.10004).rounded()))
    }

    @Test func intervalSeconds_belowFloor_clampsTo60() {
        #expect(WeatherService.intervalSeconds(factor: 0.01) == 60)
    }

    @Test func intervalSeconds_aboveCeiling_clampsTo14400() {
        #expect(WeatherService.intervalSeconds(factor: 100) == 14400)
    }

    // MARK: - decode(_:) JSON fixture

    @Test func decode_ownsOnlyTempAndHumidityFromRealisticResponse() throws {
        let json = """
        {
          "coord": {"lon": -122.42, "lat": 37.77},
          "weather": [{"id": 800, "main": "Clear", "description": "clear sky", "icon": "01d"}],
          "main": {"temp": 21.5, "feels_like": 20.9, "temp_min": 18.0, "temp_max": 24.0, "pressure": 1015, "humidity": 42},
          "name": "San Francisco"
        }
        """
        let data = Data(json.utf8)
        let reading = try #require(WeatherService.decode(data))
        #expect(reading == WeatherService.Reading(tempC: 21.5, humidity: 42))
    }

    @Test func decode_malformedPayload_returnsNil() {
        #expect(WeatherService.decode(Data("not json".utf8)) == nil)
        #expect(WeatherService.decode(Data("{}".utf8)) == nil)
    }
}
