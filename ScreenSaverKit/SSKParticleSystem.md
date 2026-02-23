# SSKParticleSystem Cheat Sheet

Use `SSKParticleSystem` when you need lightweight glow trails or burst effects without wiring up your own entity pool. The class now drives both simulation *and* rendering data, and can run its integration step on the GPU when Metal is available.

## Core Concepts

- **CPU & GPU parity** – Each particle is stored in a struct that both Objective-C and Metal can read. When Metal is available (and you do not install a custom `updateHandler`) the system pushes the array through a compute kernel each frame.
- **Automatic behaviours** – Fade logic that previously lived in ad-hoc blocks can be described with `SSKParticleBehaviorOptions`. This keeps the GPU path in sync with the CPU fallback.
- **Shared buffer** – When Metal simulation is enabled the particle array lives in a shared `MTLBuffer`. You *must* configure particles inside the supplied initializer block so the system can sync those writes before the compute pass.
- **Fallbacks** – If Metal is unavailable, or you attach an `updateHandler`, the system drops back to the previous CPU integration path with no additional work.

## Quick Start

```objective-c
SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:1024];
system.blendMode = SSKParticleBlendModeAdditive;
system.globalDamping = 0.12;

[system spawnParticles:32 initializer:^(SSKParticle *p) {
    p.position = spawnPoint;
    p.velocity = direction;
    p.maxLife = 1.5;
    p.color = paletteColor;
    p.size = 14.0;
    p.baseSize = 14.0;
    p.sizeOverLifeRange = SSKScalarRangeMake(1.0, 0.25);
    p.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha | SSKParticleBehaviorOptionFadeSize;
}];
```

Inside your saver’s frame loop, call `advanceBy:` and either `drawInContext:` (CPU rendering) or pass the particles to `SSKMetalParticleRenderer` to take advantage of the instanced Metal renderer already bundled with the kit.

## Important Properties

| Property | Purpose |
| --- | --- |
| `blendMode` | Switch between alpha compositing and additive bloom rendering. |
| `gravity` | Global acceleration applied every update (`NSPoint` in points/sec²). |
| `globalDamping` | Per-second damping factor applied on top of each particle's `damping`. Useful for quick global tuning. |
| `metalSimulationEnabled` | Toggles the compute path. Defaults to `YES` when a device and pipeline could be created. Automatically falls back to `NO` if you install an `updateHandler`. |
| `renderHandler` | Custom Core Graphics renderer executed for each particle when you are drawing on the CPU. Leave `nil` to use the default blurred disc. |
| `noiseScale` | Spatial frequency for curl noise (default 0.003). Smaller = larger swirls. |
| `noiseStrength` | Force magnitude for curl noise (default 0.0 — opt-in). Set > 0 to enable. |
| `noiseSpeed` | Animation speed for curl noise (default 0.5). |
| `ribbonModeEnabled` | When `YES`, particles render as connected trail strips instead of isolated quads. |

### Per-particle Fields

Every `SSKParticle` exposes direct setters/getters backed by the shared struct:

- `position`, `velocity` – measured in view points, integrated every frame.
- `life`, `maxLife` – seconds. The particle is recycled once `life >= maxLife`.
- `size` / `baseSize` – diameter in points. `baseSize` is used by the fade helpers so you can scale relative to the original value.
- `sizeVelocity` – points-per-second. Handy for “expanding spark” effects even on the GPU path.
- `sizeOverLifeRange` – scalar range applied when `SSKParticleBehaviorOptionFadeSize` is set (e.g. `1.0 → 0.2`).
- `behaviorOptions` – bitmask that enables the built-in behaviours (see table below).
- `endColor` – target colour for lifetime gradient. Set via spawn parameters `endColorMin`/`endColorMax`. Stored as half-float packed in the shared struct.
- `rotation`, `rotationVelocity` – radians and radians/sec. Rotation is integrated on the GPU and applied in the vertex shader to orient the quad.
- `userVector`, `userScalar` – scratch space for your renderer or palette logic.
- `color` – stored as linear/extended sRGB in the shared buffer; the fade behaviour automatically mixes alpha when enabled.

> **Note:** Configure these fields while you are inside the `spawnParticles:initializer:` block. The system syncs the underlying Metal buffer immediately after the block returns so the compute kernel sees the latest values.

## Behaviour Options

All behaviours are opt-in via a bitmask on `behaviorOptions`. They work on both the CPU and GPU simulation paths.

| Flag | Value | Effect |
| --- | --- | --- |
| `FadeAlpha` | `1 << 0` | Linearly fade alpha from 1 → 0 over lifetime. |
| `FadeSize` | `1 << 1` | Scale size from `sizeOverLifeRange.start` → `.end` over lifetime. |
| `ColorGradient` | `1 << 2` | Interpolate `color` → `endColor` over lifetime (half-float packed). |
| `CurlNoise` | `1 << 3` | Apply a divergence-free curl noise force field each frame. |
| `Attractors` | `1 << 4` | Apply up to 4 point attractor forces with inverse-square falloff. |
| `VelocityHue` | `1 << 5` | Map velocity magnitude to HSV hue (dynamic colour). |
| `RibbonMode` | `1 << 6` | Render as connected trail strips (GPU-driven pipeline). |

Flags combine freely: `FadeAlpha | ColorGradient | CurlNoise` is a common combination for luminous flowing streams.

## Force Fields

### Curl Noise

Curl noise produces divergence-free swirling motion (particles never converge to a point). Configure it with three properties on the system, then enable `SSKParticleBehaviorOptionCurlNoise` per particle.

```objective-c
system.noiseScale    = 0.002;   // spatial frequency (smaller = bigger swirls)
system.noiseStrength = 300.0;   // force magnitude (0 = disabled)
system.noiseSpeed    = 0.3;     // animation speed
```

### Attractor Points

Up to 4 point attractors pull particles with inverse-square falloff. Useful for vortex patterns.

```objective-c
[system setAttractorAtIndex:0 position:NSMakePoint(cx, cy) strength:5000.0];
[system setAttractorAtIndex:1 position:NSMakePoint(cx + 200, cy) strength:3000.0];
// Remove all:
[system clearAttractors];
```

Enable `SSKParticleBehaviorOptionAttractors` on the particles that should be affected.

## Behaviours vs. Custom Updates

- Prefer the built-in behaviour flags for effects like fading, colour gradients, and force fields. They run identically on CPU and GPU.
- If you attach `updateHandler`, Metal simulation is disabled automatically. Use this when you truly need per-frame custom math in Objective-C (e.g. collision callbacks).

## When Things Go Wrong

- **Black screen with Metal** – Ensure you are running on macOS 11+ with a Metal-capable GPU. You can force the CPU path by toggling `system.metalSimulationEnabled = NO;`.
- **Particles never appear** – Double-check that `spawnParticles:` is called regularly and that `maxLife` is > 0. Also confirm you are setting `color` to something non-transparent inside the initializer block.
- **Visual mismatch between Metal and CPU** – Keep custom logic inside the behaviour system or maintain equivalent code paths for CPU and GPU. If behaviour flags don’t cover your effect, consider setting a tiny `updateHandler` only when Metal is unavailable.

## Trail Persistence

Trail persistence lives on the renderer, not the particle system, but pairs naturally with it. When enabled, each frame's particles are composited onto a persistent offscreen texture that fades slowly over time.

```objective-c
renderer.trailPersistenceEnabled = YES;
renderer.trailFadeRate = 0.02;  // 0.0 = no fade, 1.0 = instant fade
```

## Integration Tips

1. Reuse a single `SSKParticleSystem` instance; the capacity parameter is fixed for the lifetime of the object.
2. When you rebuild or reset entire effects, call `reset` on the system—this clears internal bookkeeping and, in GPU mode, synchronises the contents back to the compute buffer.
3. Pair the system with `SSKMetalParticleRenderer` for very cheap instanced rendering. If Metal is unavailable the CPU `drawInContext:` path still works.
4. Want palette-driven colours? Store your palette index/progress in `userScalar` or `userVector` and resolve the actual `NSColor` when you spawn new particles.
5. For flowing energy streams, combine curl noise + trail persistence + additive blending + bloom. See `Demos/Flux/FluxView.m`.
6. For connected trail strips (ribbon mode), enable `ribbonModeEnabled` on the system and set `SSKParticleBehaviorOptionRibbonMode` on particles. See `Demos/RibbonFlow/RibbonFlowView.m`.

That should give both humans and tooling (including LLMs) enough context to use the particle system effectively. Refer to `Demos/Flux`, `Demos/RibbonFlow`, and `Demos/DVDLogoMetal` in the repository for concrete usage patterns.
