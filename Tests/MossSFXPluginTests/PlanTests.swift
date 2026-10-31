import Foundation
import GaeaProtocol
import MossSFXPlugin
import Testing

@Suite struct PlanTests {
    func plan(_ seconds: Double?, count: Int? = nil, quality: String? = nil) throws -> SoundPlan {
        try soundPlan(prompt: "Rain on a tin roof.", negativePrompt: nil, seconds: seconds, count: count, quality: quality, seed: 7)
    }

    @Test func theModelIsToldTheDurationRoundedUpToATenthAndKeepsTheExactFrames() throws {
        #expect(try plan(1.5).modelSeconds == 1.5)
        #expect(try plan(1.5).frames == 72000)
        #expect(try plan(1.55).modelSeconds == 1.6)
        #expect(try plan(1.55).frames == 74400)
        #expect(try plan(2.3).frames == 110400)
        #expect(try plan(30).modelSeconds == 30)
        #expect(try plan(nil).seconds == 10)
    }

    @Test func qualityPicksTheSteps() throws {
        #expect(try plan(1, quality: "draft").steps == 25)
        #expect(try plan(1).steps == 50)
        #expect(try plan(1, quality: "best").steps == 100)
        #expect(try plan(1, quality: "best").effective["x-moss.steps"] == .int(100))
    }

    @Test func countRunsSeedPlusI() throws {
        let p = try plan(1, count: 3)
        #expect((0..<3).map { request(p, sound: $0).seed } == [7, 8, 9])
    }

    @Test func refusals() {
        #expect(throws: GPPError.self) { try plan(0.4) }
        #expect(throws: GPPError.self) { try plan(30.1) }
        #expect(throws: GPPError.self) { try plan(1, count: 9) }
        #expect(throws: GPPError.self) { try plan(1, quality: "ultra") }
        #expect(throws: GPPError.self) { try soundPlan(prompt: " ", negativePrompt: nil, seconds: 1, count: 1, quality: nil, seed: 1) }
    }

    @Test func theCutKeepsTheFramesAndMakesUpAFrameTheCropDropped() throws {
        func wav(_ frames: Int) -> Data {
            var d = Data("RIFF".utf8) + Data(count: 4) + Data("WAVEfmt ".utf8) + Data(count: 20) + Data("data".utf8) + Data(count: 4)
            for i in 0..<frames { withUnsafeBytes(of: Int16(i).littleEndian) { d.append(contentsOf: $0) } }
            return d
        }
        #expect(try cut(wav(110), frames: 100).count == 44 + 200)
        let padded = try cut(wav(99), frames: 100)
        #expect(padded.count == 44 + 200 && padded.suffix(4) == Data([98, 0, 98, 0]))
        #expect(throws: GPPError.self) { try cut(wav(90), frames: 100) }
    }
}
