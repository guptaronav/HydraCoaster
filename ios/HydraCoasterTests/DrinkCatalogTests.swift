import Foundation
import Testing

@testable import HydraCoaster

struct DrinkCatalogTests {
    @Test func all_hasAroundSixtyEntries() {
        #expect(DrinkCatalog.all.count >= 55)
        #expect(DrinkCatalog.all.count <= 70)
    }

    @Test func all_idsAreUnique() {
        let ids = DrinkCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func all_namesAreNonEmpty() {
        #expect(DrinkCatalog.all.allSatisfy { !$0.name.isEmpty })
    }

    @Test func all_factorsAreWithinPlausibleRange() {
        // Scale documented on DrinkType.hydrationFactor: 1.0 == water,
        // bounded above by real beverage-hydration-index research (nothing
        // hydrates meaningfully better than 1.5x water) and above zero
        // since every drink contributes SOME fluid.
        #expect(DrinkCatalog.all.allSatisfy { $0.hydrationFactor > 0 && $0.hydrationFactor <= 1.5 })
    }

    @Test func all_everyCategoryIsRepresented() {
        let representedCategories = Set(DrinkCatalog.all.map(\.category))
        #expect(representedCategories == Set(DrinkCategory.allCases))
    }

    @Test func water_hydrationFactorIsExactlyOne() {
        #expect(DrinkCatalog.water.hydrationFactor == 1.0)
        #expect(DrinkCatalog.water.id == "water")
    }

    @Test func drink_knownID_returnsMatchingEntry() {
        let coffee = DrinkCatalog.drink(for: "coffee.black")
        #expect(coffee.id == "coffee.black")
        #expect(coffee.category == .coffee)
    }

    @Test func drink_unknownID_fallsBackToWater() {
        #expect(DrinkCatalog.drink(for: "not.a.real.id") == DrinkCatalog.water)
    }

    @Test func alcohol_hydratesWorseThanWater() {
        // Pinned in the spec: beer ~0.6, wine ~0.4 — every alcohol entry
        // should read as "hydrates worse than water," not better.
        let alcohol = DrinkCatalog.all.filter { $0.category == .alcohol }
        #expect(!alcohol.isEmpty)
        #expect(alcohol.allSatisfy { $0.hydrationFactor < 1.0 })
    }
}
