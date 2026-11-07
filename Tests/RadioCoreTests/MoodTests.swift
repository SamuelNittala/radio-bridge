import Foundation
import Testing
@testable import RadioCore

@Suite struct Moods {
    @Test func casesAreInMoodOrder() {
        #expect(Mood.allCases == [.chill, .feelGood, .energetic, .party, .romantic, .sad])
    }

    @Test func titles() {
        #expect(Mood.allCases.map(\.title)
                == ["Chill", "Feel good", "Energetic", "Party", "Romantic", "Sad"])
    }

    @Test func ytFilters() {
        #expect(Mood.chill.ytFilters == ["Chill", "Relax"])
        #expect(Mood.feelGood.ytFilters == ["Feel good", "Upbeat"])
        #expect(Mood.energetic.ytFilters == ["Workout", "Energy", "Pump-up"])
        #expect(Mood.party.ytFilters == ["Party"])
        #expect(Mood.romantic.ytFilters == ["Romance", "Romantic"])
        #expect(Mood.sad.ytFilters == ["Sad"])
    }

    @Test func rawValuesMatchTheClaudeEnum() {
        #expect(Mood.allCases.map(\.rawValue)
                == ["chill", "feelGood", "energetic", "party", "romantic", "sad"])
    }
}
