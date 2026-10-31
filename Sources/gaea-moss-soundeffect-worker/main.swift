import GaeaPluginKit
import MossSFXPlugin

// The plugin's worker: MossSFXPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(mossSFXPlugin)
