import Foundation
import Testing
@testable import PetEngine

@Test func manifestDecodesIkun() throws {
    let json = #"{ "id": "ikun", "displayName": "IKUN", "description": "x", "spritesheetPath": "spritesheet.webp" }"#
        .data(using: .utf8)!
    let m = try JSONDecoder().decode(PetManifest.self, from: json)
    #expect(m.id == "ikun")
    #expect(m.spritesheetPath == "spritesheet.webp")
}

@Test func manifestDecodesWithoutDescription() throws {
    let json = #"{ "id": "p", "displayName": "P", "spritesheetPath": "s.png" }"#
        .data(using: .utf8)!
    let m = try JSONDecoder().decode(PetManifest.self, from: json)
    #expect(m.description == nil)
}

@Test func moodRowMappingMatchesPlan() {
    #expect(PetMood.idle.rowIndex == 0)
    #expect(PetMood.sleep.rowIndex == 8)
    #expect(PetMood.allCases.count == 9)
}

@Test func atlasDefaultsAreCodexConvention() {
    let a = Atlas()
    #expect(a.cols == 8)
    #expect(a.rows == 9)
}
