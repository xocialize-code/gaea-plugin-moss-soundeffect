import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXMossSoundEffect
import MLXToolKit

// gaea-plugin-moss-soundeffect: OpenMOSS's MOSS-SoundEffect v2.0 (Apache-2.0; the MLX port, moss-soundeffect-mlx-swift,
// is Apache-2.0) on MES Audio 0.1's audio.generate (media-engine-spec v0.7.0, Gaea AB-T-0398). One model: non-verbal
// sounds from a description (foley, ambience, creatures, actions), 48 kHz mono, 0.5 to 30 s (Audio §3.4):
//
// - duration_s is exact to the frame. The model is told the duration in its prompt, to a tenth of a second, and always
//   denoises a full 30 s latent; the worker asks for the duration rounded up to a tenth and keeps round(d × 48 000)
//   frames.
// - count runs the model once per sound at seed + i. The package seeds MLX's random state with the seed, so the same
//   request gives the same WAV, here and in moss-sfx-inproc.
// - quality picks the denoise steps (CFG 4.0 throughout), so clients never send diffusion settings.
//
// Two lanes, the DiT's quant: bf16 (the default) and int4, with the package's measured footprints.

public let modelID = "moss-soundeffect"
public let sampleRate = 48000
public let minSeconds = 0.5, maxSeconds = 30.0, defaultSeconds = 10.0
public let maxCount = 8, maxPromptChars = 2000
/// Denoise steps per quality tier. `best` is the reference's 100.
public let stepsByQuality = ["draft": 25, "standard": 50, "best": 100]
public let defaultQuality = "standard"

/// What a generate job asks of the package, validated.
public struct SoundPlan: Sendable, Equatable {
    public var prompt: String
    public var negativePrompt: String?
    /// What the client asked for, exactly.
    public var seconds: Double
    /// What the model is told: `seconds` rounded up to a tenth.
    public var modelSeconds: Double
    /// The frames each sound keeps.
    public var frames: Int
    public var count: Int
    public var steps: Int
    public var quality: String
    public var seed: UInt64
    public var effective: [String: JSONValue]
}

func refuse(_ message: String, _ param: String) -> GPPError {
    GPPError(.invalidRequest, message, detail: ["param": .string(param)])
}

public func soundPlan(prompt: String?, negativePrompt: String?, seconds: Double?, count: Int?, quality: String?,
                      seed: UInt64) throws -> SoundPlan {
    guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
        throw refuse("audio.generate needs a prompt.", "prompt")
    }
    guard prompt.count <= maxPromptChars else { throw refuse("A prompt is at most \(maxPromptChars) characters.", "prompt") }
    let seconds = seconds ?? defaultSeconds
    guard seconds >= minSeconds, seconds <= maxSeconds else {
        throw refuse("MOSS-SoundEffect makes sounds of \(minSeconds) to \(Int(maxSeconds)) s.", "duration_s")
    }
    let count = count ?? 1
    guard (1...maxCount).contains(count) else { throw refuse("MOSS-SoundEffect makes 1–\(maxCount) sounds at a time.", "count") }
    let quality = quality ?? defaultQuality
    guard let steps = stepsByQuality[quality] else { throw refuse("No quality \(quality).", "quality") }
    let negative = negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    // A hair of slack, so 1.5 isn't read as 1.5000000001 and asked as 1.6.
    let modelSeconds = min(maxSeconds, ((seconds * 10) - 1e-9).rounded(.up) / 10)
    let frames = Int((seconds * Double(sampleRate)).rounded())
    var effective: [String: JSONValue] = ["seed": .int(Int64(seed)), "duration_s": .double(seconds), "count": .int(Int64(count)),
                                          "quality": .string(quality), "x-moss.steps": .int(Int64(steps))]
    if let negative, !negative.isEmpty { effective["negative_prompt"] = .string(negative) }
    return SoundPlan(prompt: prompt, negativePrompt: negative?.isEmpty == false ? negative : nil, seconds: seconds,
                     modelSeconds: modelSeconds, frames: frames, count: count, steps: steps, quality: quality, seed: seed,
                     effective: effective)
}

/// The engine request for sound `i` of a plan, at seed + i.
public func request(_ plan: SoundPlan, sound i: Int) -> SoundEffectRequest {
    SoundEffectRequest(prompt: plan.prompt, durationSeconds: plan.modelSeconds, negativePrompt: plan.negativePrompt,
                       steps: plan.steps, seed: plan.seed + UInt64(i))
}

/// The package's 16-bit mono WAV cut to `frames` (the model's own crop is to a tenth of a second, at least as long).
public func cut(_ wav: Data, frames: Int) throws -> Data {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8),
          wav[wav.startIndex + 36..<wav.startIndex + 40] == Data("data".utf8) else {
        throw GPPError(.modelError, "MOSS-SoundEffect returned something other than a 16-bit WAV.")
    }
    var pcm = wav.subdata(in: (wav.startIndex + 44)..<wav.endIndex)
    // The package crops at Int(48 000 × seconds), which floating point can leave a frame short (2.3 s is 110 399):
    // a frame or two is made up by holding the last sample. More than that is the model's fault.
    let short = frames - pcm.count / 2
    guard short <= 2 else {
        throw GPPError(.modelError, "MOSS-SoundEffect returned \(pcm.count / 2) frames; \(frames) were asked for.")
    }
    if short > 0, let last = pcm.suffix(2) as Data? { for _ in 0..<short { pcm.append(last) } }
    pcm = pcm.prefix(frames * 2)
    var out = Data(capacity: 44 + pcm.count)
    func w32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func w16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); w32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); w32(16); w16(1); w16(1); w32(UInt32(sampleRate)); w32(UInt32(sampleRate * 2)); w16(2); w16(16)
    out.append(contentsOf: Array("data".utf8)); w32(UInt32(pcm.count))
    out.append(pcm)
    return out
}

public func seed(_ job: Job) -> UInt64 { job.seed.map { $0 & 0xFFFF_FFFF } ?? UInt64.random(in: 0..<(1 << 32)) }

let generateOperation = EngineOperation("audio.generate") { job, session in
    let plan = try soundPlan(prompt: try job.text("prompt"), negativePrompt: job.param("negative_prompt")?.stringValue,
                             seconds: job.param("duration_s")?.doubleValue, count: job.param("count")?.intValue,
                             quality: job.param("quality")?.stringValue, seed: seed(job))
    var outputs: [Output] = []
    for i in 0..<plan.count {
        guard let response = try await session.run(request(plan, sound: i)) as? SoundEffectResponse else {
            throw GPPError(.modelError, "MOSS-SoundEffect returned no sound.")
        }
        let url = session.outputDir.appending(path: "sounds-\(i).wav")
        try cut(response.audio.data, frames: plan.frames).write(to: url)
        outputs.append(.file("sounds", url, mediaType: "audio/wav"))
    }
    return RunResult(outputs: outputs, effective: plan.effective)
}

// MARK: - The plugin

public func lanes() -> [LaneDefinition] {
    [LaneDefinition(id: "bf16", default: true, configuration: MossSoundEffectConfiguration()),
     LaneDefinition(id: "int4", configuration: MossSoundEffectConfiguration(repo: "mlx-community/MOSS-SoundEffect-v2.0-4bit"))]
}

let generateModel = ModelDefinition.engine(MossSoundEffectPackage.self, id: modelID, title: "MOSS-SoundEffect",
                                           lanes: lanes(), operations: [generateOperation])

let generateOffer = PluginManifest.Offer(
    operation: "audio.generate", profile: "audio",
    model: [
        "id": .string(modelID), "title": "MOSS-SoundEffect",
        "license": ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://huggingface.co/OpenMOSS-Team/MOSS-SoundEffect"],
        "memory_class": "large", "speed_class": "slow", "quality_tiers": ["draft", "standard", "best"],
        "notes": "Sound effects from a description: foley, ambience, creatures, actions, machines and weather, 0.5 to 30 s at 48 kHz. Describe the sound, not a scene (\"heavy rain on a tin roof, distant thunder\"). Write in English or Chinese. A negative prompt steers away from what you name.",
        "supports": ["languages": ["en", "zh"], "sample_rate": .int(Int64(sampleRate)), "channels": 1],
        "limits": ["max_duration_s": .double(maxSeconds), "min_duration_s": .double(minSeconds), "max_count": .int(Int64(maxCount)),
                   "max_text_chars": .int(Int64(maxPromptChars))],
    ])

public let mossSFXPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.moss-soundeffect", version: "0.1.0", minGaea: "0.9.2", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-moss-soundeffect", title: "MOSS-SoundEffect",
    summary: "MOSS-SoundEffect v2.0: sound effects from a description (MES audio.generate): foley, ambience, creatures and actions, 0.5 to 30 s at 48 kHz, exact to the frame.",
    license: "Apache-2.0", executable: "gaea-moss-soundeffect-worker",
    models: [generateModel], offers: [generateOffer])
