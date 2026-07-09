import Foundation

/// One of the catalog's groupings, used to section the Quick Log grid.
enum DrinkCategory: String, CaseIterable, Identifiable {
    case water = "Water & Infusions"
    case coffee = "Coffee"
    case tea = "Tea"
    case juice = "Juice & Smoothies"
    case soda = "Soda"
    case sports = "Sports & Energy"
    case dairy = "Dairy & Alternatives"
    case soup = "Soups & Broths"
    case alcohol = "Alcohol"

    var id: String { rawValue }
}

/// One drink type. `id` is a stable catalog key snapshotted onto every sip
/// (`SipRecord.typeID`) — never repurpose or remove an id once shipped,
/// only add new ones, or historical sips referencing it fall back to water.
struct DrinkType: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: DrinkCategory
    let systemImage: String
    /// Multiplies raw ml into "effective" hydration ml — see
    /// `SipRecord.effectiveGrams`. Scale: 1.0 = plain water. Above 1.0 means
    /// a drink retains fluid slightly BETTER than water (electrolytes/
    /// protein slow gastric emptying — real beverage-hydration-index
    /// research places milk and oral rehydration solutions here). Below 1.0
    /// means worse: caffeine's mild diuretic effect (coffee/tea/soda/
    /// energy drinks), high sugar concentration (juice), or alcohol's
    /// diuretic effect (wine/beer/spirits — the lowest of all, worsening
    /// with proof). These are conservative, self-consistent estimates for a
    /// consumer hydration app, not clinical dosing.
    let hydrationFactor: Double
}

/// Static ~60-entry drink catalog (V2-T2). No persistence, no network —
/// just a lookup table keyed by `DrinkType.id`.
enum DrinkCatalog {
    static let all: [DrinkType] = [
        // MARK: Water & Infusions
        DrinkType(id: "water", name: "Water", category: .water, systemImage: "drop.fill", hydrationFactor: 1.0),
        DrinkType(id: "water.sparkling", name: "Sparkling Water", category: .water, systemImage: "bubbles.and.sparkles", hydrationFactor: 1.0),
        DrinkType(id: "water.mineral", name: "Mineral Water", category: .water, systemImage: "bubbles.and.sparkles", hydrationFactor: 1.0),
        DrinkType(id: "water.flavored", name: "Flavored Water", category: .water, systemImage: "drop.fill", hydrationFactor: 1.0),
        DrinkType(id: "water.infused", name: "Fruit-Infused Water", category: .water, systemImage: "leaf.fill", hydrationFactor: 1.0),
        DrinkType(id: "water.coconut", name: "Coconut Water", category: .water, systemImage: "drop.triangle.fill", hydrationFactor: 1.1),
        DrinkType(id: "water.electrolyte", name: "Electrolyte Water", category: .water, systemImage: "bolt.fill", hydrationFactor: 1.2),

        // MARK: Coffee
        DrinkType(id: "coffee.black", name: "Black Coffee", category: .coffee, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.9),
        DrinkType(id: "coffee.espresso", name: "Espresso", category: .coffee, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.85),
        DrinkType(id: "coffee.americano", name: "Americano", category: .coffee, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.9),
        DrinkType(id: "coffee.latte", name: "Latte", category: .coffee, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.95),
        DrinkType(id: "coffee.cappuccino", name: "Cappuccino", category: .coffee, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.95),
        DrinkType(id: "coffee.coldBrew", name: "Cold Brew", category: .coffee, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.85),
        DrinkType(id: "coffee.decaf", name: "Decaf Coffee", category: .coffee, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.95),

        // MARK: Tea
        DrinkType(id: "tea.black", name: "Black Tea", category: .tea, systemImage: "leaf.fill", hydrationFactor: 0.9),
        DrinkType(id: "tea.green", name: "Green Tea", category: .tea, systemImage: "leaf.fill", hydrationFactor: 0.95),
        DrinkType(id: "tea.oolong", name: "Oolong Tea", category: .tea, systemImage: "leaf.fill", hydrationFactor: 0.9),
        DrinkType(id: "tea.herbal", name: "Herbal Tea", category: .tea, systemImage: "leaf.fill", hydrationFactor: 1.0),
        DrinkType(id: "tea.chai", name: "Chai Latte", category: .tea, systemImage: "leaf.fill", hydrationFactor: 0.9),
        DrinkType(id: "tea.matcha", name: "Matcha", category: .tea, systemImage: "leaf.fill", hydrationFactor: 0.9),
        DrinkType(id: "tea.iced", name: "Iced Tea", category: .tea, systemImage: "leaf.fill", hydrationFactor: 0.9),

        // MARK: Juice & Smoothies
        DrinkType(id: "juice.orange", name: "Orange Juice", category: .juice, systemImage: "sun.max.fill", hydrationFactor: 0.85),
        DrinkType(id: "juice.apple", name: "Apple Juice", category: .juice, systemImage: "sun.max.fill", hydrationFactor: 0.85),
        DrinkType(id: "juice.cranberry", name: "Cranberry Juice", category: .juice, systemImage: "sun.max.fill", hydrationFactor: 0.85),
        DrinkType(id: "juice.grape", name: "Grape Juice", category: .juice, systemImage: "sun.max.fill", hydrationFactor: 0.8),
        DrinkType(id: "juice.vegetable", name: "Vegetable Juice", category: .juice, systemImage: "carrot.fill", hydrationFactor: 0.9),
        DrinkType(id: "smoothie.fruit", name: "Fruit Smoothie", category: .juice, systemImage: "takeoutbag.and.cup.and.straw.fill", hydrationFactor: 0.8),
        DrinkType(id: "smoothie.green", name: "Green Smoothie", category: .juice, systemImage: "takeoutbag.and.cup.and.straw.fill", hydrationFactor: 0.85),

        // MARK: Soda
        DrinkType(id: "soda.cola", name: "Cola", category: .soda, systemImage: "bubbles.and.sparkles", hydrationFactor: 0.85),
        DrinkType(id: "soda.diet", name: "Diet Soda", category: .soda, systemImage: "bubbles.and.sparkles", hydrationFactor: 0.85),
        DrinkType(id: "soda.lemonLime", name: "Lemon-Lime Soda", category: .soda, systemImage: "bubbles.and.sparkles", hydrationFactor: 0.85),
        DrinkType(id: "soda.rootBeer", name: "Root Beer", category: .soda, systemImage: "bubbles.and.sparkles", hydrationFactor: 0.85),
        DrinkType(id: "soda.gingerAle", name: "Ginger Ale", category: .soda, systemImage: "bubbles.and.sparkles", hydrationFactor: 0.88),
        DrinkType(id: "soda.tonic", name: "Tonic Water", category: .soda, systemImage: "bubbles.and.sparkles", hydrationFactor: 0.85),

        // MARK: Sports & Energy
        DrinkType(id: "sports.electrolyte", name: "Sports Drink", category: .sports, systemImage: "bolt.fill", hydrationFactor: 1.05),
        DrinkType(id: "sports.recovery", name: "Recovery Drink", category: .sports, systemImage: "bolt.fill", hydrationFactor: 1.05),
        DrinkType(id: "sports.proteinWater", name: "Protein Water", category: .sports, systemImage: "bolt.fill", hydrationFactor: 1.0),
        DrinkType(id: "sports.ors", name: "Oral Rehydration Solution", category: .sports, systemImage: "bolt.fill", hydrationFactor: 1.25),
        DrinkType(id: "energy.standard", name: "Energy Drink", category: .sports, systemImage: "bolt.fill", hydrationFactor: 0.9),
        DrinkType(id: "energy.preworkout", name: "Pre-Workout", category: .sports, systemImage: "bolt.fill", hydrationFactor: 0.85),
        DrinkType(id: "energy.shot", name: "Energy Shot", category: .sports, systemImage: "bolt.fill", hydrationFactor: 0.7),

        // MARK: Dairy & Alternatives
        DrinkType(id: "dairy.milkWhole", name: "Whole Milk", category: .dairy, systemImage: "cup.and.saucer.fill", hydrationFactor: 1.1),
        DrinkType(id: "dairy.milkSkim", name: "Skim Milk", category: .dairy, systemImage: "cup.and.saucer.fill", hydrationFactor: 1.1),
        DrinkType(id: "dairy.chocolateMilk", name: "Chocolate Milk", category: .dairy, systemImage: "cup.and.saucer.fill", hydrationFactor: 1.05),
        DrinkType(id: "dairy.buttermilk", name: "Buttermilk", category: .dairy, systemImage: "cup.and.saucer.fill", hydrationFactor: 1.05),
        DrinkType(id: "dairy.almondMilk", name: "Almond Milk", category: .dairy, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.95),
        DrinkType(id: "dairy.oatMilk", name: "Oat Milk", category: .dairy, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.95),
        DrinkType(id: "dairy.soyMilk", name: "Soy Milk", category: .dairy, systemImage: "cup.and.saucer.fill", hydrationFactor: 0.95),

        // MARK: Soups & Broths
        DrinkType(id: "broth.chicken", name: "Chicken Broth", category: .soup, systemImage: "flame.fill", hydrationFactor: 1.05),
        DrinkType(id: "broth.beef", name: "Beef Broth", category: .soup, systemImage: "flame.fill", hydrationFactor: 1.05),
        DrinkType(id: "broth.vegetable", name: "Vegetable Broth", category: .soup, systemImage: "flame.fill", hydrationFactor: 1.05),
        DrinkType(id: "broth.bone", name: "Bone Broth", category: .soup, systemImage: "flame.fill", hydrationFactor: 1.05),
        DrinkType(id: "soup.miso", name: "Miso Soup", category: .soup, systemImage: "flame.fill", hydrationFactor: 1.0),
        DrinkType(id: "soup.clear", name: "Clear Soup", category: .soup, systemImage: "flame.fill", hydrationFactor: 1.0),

        // MARK: Alcohol
        DrinkType(id: "alcohol.beer", name: "Beer", category: .alcohol, systemImage: "wineglass.fill", hydrationFactor: 0.6),
        DrinkType(id: "alcohol.cider", name: "Cider", category: .alcohol, systemImage: "wineglass.fill", hydrationFactor: 0.55),
        DrinkType(id: "alcohol.hardSeltzer", name: "Hard Seltzer", category: .alcohol, systemImage: "wineglass.fill", hydrationFactor: 0.65),
        DrinkType(id: "alcohol.wineRed", name: "Red Wine", category: .alcohol, systemImage: "wineglass.fill", hydrationFactor: 0.4),
        DrinkType(id: "alcohol.wineWhite", name: "White Wine", category: .alcohol, systemImage: "wineglass.fill", hydrationFactor: 0.4),
        DrinkType(id: "alcohol.cocktail", name: "Cocktail", category: .alcohol, systemImage: "wineglass.fill", hydrationFactor: 0.35),
        DrinkType(id: "alcohol.spirit", name: "Liquor (Straight)", category: .alcohol, systemImage: "wineglass.fill", hydrationFactor: 0.15),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The default for coaster sips and any unrecognized `typeID` (e.g. an
    /// id a future app version added that this build predates).
    static let water = byID["water"]!

    static func drink(for id: String) -> DrinkType {
        byID[id] ?? water
    }
}
