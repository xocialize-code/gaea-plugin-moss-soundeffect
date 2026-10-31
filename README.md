# gaea-plugin-moss-soundeffect

OpenMOSS's **MOSS-SoundEffect v2.0** (Apache-2.0) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: sound effects
from a description, on MES Audio 0.1's `audio.generate`. It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[mlx-moss-soundeffect-swift](https://github.com/xocialize/mlx-moss-soundeffect-swift), runs in its own process, and speaks
the Gaea Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-moss-soundeffect
```

## What it offers

One model, `moss-soundeffect`, on `audio.generate`: foley, ambience, creatures, actions, machines and weather.

- **Prompt.** Describe the sound, not a scene ("heavy rain on a tin roof, distant thunder"), in English or Chinese, up to
  2,000 characters. `negative_prompt` steers away from what it names.
- **`duration_s` is exact.** It runs from 0.5 to 30 s, 10 s when absent. Each sound has `round(duration_s × 48 000)` frames.
  - The model is told the duration in its prompt, to a tenth of a second, and always denoises a full 30 s latent.
  - So the worker asks for the duration rounded up to a tenth, and keeps exactly the frames asked for.
- **`count`** makes 1 to 8 sounds, sound `i` at `seed + i`. The same request gives the same WAVs.
- **`quality`** picks the denoise steps, with guidance 4.0 throughout. `effective` reports the count as `x-moss.steps`.

| `quality` | Steps | A sound, warm (M5 Max, bf16) |
|---|---|---|
| `draft` | 25 | about 9.5 s |
| `standard` (the default) | 50 | about 18 s |
| `best` | 100, the reference's | about 35 s |

  The time doesn't depend on the duration: every sound denoises the full 30 s latent.
- **Progress** reports each denoise step (`denoise`, `step` of `steps`), then `decode`.
- **Output:** a 48 kHz mono 16-bit WAV, converted by Gaea to the request's `output`.

## Lanes and memory

Two lanes, the DiT's quant: `bf16` (the default, 7.4 GB resident) and `int4` (5.4 GB). Each can peak 18 GB higher while
denoising, by the package's declaration. Through the plugin check, bf16 measured 6.8 GB after a draft sound and a 11.6 GB
peak.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default). The lanes read
`mlx-community/MOSS-SoundEffect-v2.0-bf16` (7.8 GB, with its Qwen3-1.7B text encoder) and
`mlx-community/MOSS-SoundEffect-v2.0-4bit` there, and download them on `prepare` or `materialize` when they're missing.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` makes one 1.5 s draft sound over GPP on the signed bundle, with every `.build` folder hidden. It then
shows that the bare worker, outside the bundle, finds no metallib.

`scripts/release.sh` builds, checks, notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release.
The release workflow does the same in CI when a `v<version>` tag is pushed.

`moss-sfx-inproc` (its header lists the options) is not part of the plugin. It runs the same lanes in-process through
MLXServeEngine, with the worker's requests and cut: the reference Gaea's runs are compared against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` makes seeded sounds over GPP on the signed bundle and through `moss-sfx-inproc`. It needs each pair to be
the same WAV byte for byte, and exact to the frame. The cases:
- rain at 1.5 s (draft);
- a door at 2.3 s (standard), where the package's own crop is a frame short;
- two barks (count 2), and a street with a negative prompt;
- glass at 1.0 s (best), and a Chinese prompt at 1.55 s.

## CI secrets

The release workflow signs with Developer ID and notarizes. It reads four organization secrets on xocialize-code:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD` (Gaea's
`Docs/Signing secrets.md`).

## Licence

The plugin is Apache-2.0 (Gaea G-21). MOSS-SoundEffect's weights are Apache-2.0 (OpenMOSS), and its Qwen3-1.7B text
encoder is Apache-2.0 (Alibaba Qwen). The ports, mlx-moss-soundeffect-swift and moss-soundeffect-mlx-swift, are
Apache-2.0.
