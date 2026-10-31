import Foundation
import GaeaProtocol
import MLXMossSoundEffect
import MLXServeCore
import MLXToolKit
import MossSFXPlugin

// The in-process reference for the plugin: MOSS-SoundEffect loaded by MLXServeEngine in this process, with the lane
// configuration, the requests and the cut the worker uses (MossSFXPlugin). The sounds are written to --out-dir as
// sounds-<i>.wav, and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   moss-sfx-inproc --prompt <text> [--negative <text>] [--duration 10] [--count 1] [--quality standard] [--seed 42]
//                   [--lane bf16 | int4] [--models-root <dir>] [--out-dir <dir>]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let laneID = option("--lane") ?? "bf16"
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
guard let lane = lanes().first(where: { $0.id == laneID }) else { fatalError("no lane \(laneID)") }
let plan = try soundPlan(prompt: option("--prompt"), negativePrompt: option("--negative"), seconds: option("--duration").flatMap(Double.init),
                         count: option("--count").flatMap(Int.init), quality: option("--quality"),
                         seed: UInt64(option("--seed") ?? "") ?? 42)

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID)
_ = try await engine.register(MossSoundEffectPackage.registration, configuration: lane.configuration, id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.soundEffect, package: id)
var result: [String: Any] = ["model": modelID, "lane": laneID, "seed": plan.seed, "prepare_s": seconds(since: clock),
                             "steps": plan.steps, "duration_s": plan.seconds, "frames": plan.frames]
let dir = URL(fileURLWithPath: option("--out-dir") ?? ".", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var runs: [Double] = []
for i in 0..<plan.count {
    clock = ContinuousClock.now
    guard let response = try await engine.run(request(plan, sound: i), package: id) as? SoundEffectResponse else {
        fatalError("MOSS-SoundEffect returned no sound")
    }
    try cut(response.audio.data, frames: plan.frames).write(to: dir.appending(path: "sounds-\(i).wav"))
    runs.append(seconds(since: clock))
}
result["run_s"] = runs
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
