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
| `globalDamping` | Per-second damping factor applied on top of each particle’s `damping`. Useful for quick global tuning. |
| `metalSimulationEnabled` | Toggles the compute path. Defaults to `YES` when a device and pipeline could be created. Automatically falls back to `NO` if you install an `updateHandler`. |
| `renderHandler` | Custom Core Graphics renderer executed for each particle when you are drawing on the CPU. Leave `nil` to use the default blurred disc. |

### Per-particle Fields

Every `SSKParticle` exposes direct setters/getters backed by the shared struct:

- `position`, `velocity` – measured in view points, integrated every frame.
- `life`, `maxLife` – seconds. The particle is recycled once `life >= maxLife`.
- `size` / `baseSize` – diameter in points. `baseSize` is used by the fade helpers so you can scale relative to the original value.
- `sizeVelocity` – points-per-second. Handy for “expanding spark” effects even on the GPU path.
- `sizeOverLifeRange` – scalar range applied when `SSKParticleBehaviorOptionFadeSize` is set (e.g. `1.0 → 0.2`).
- `behaviorOptions` – bitmask that enables the built-in fade behaviours.
- `userVector`, `userScalar` – scratch space for your renderer or palette logic.
- `color` – stored as linear/extended sRGB in the shared buffer; the fade behaviour automatically mixes alpha when enabled.

> **Note:** Configure these fields while you are inside the `spawnParticles:initializer:` block. The system syncs the underlying Metal buffer immediately after the block returns so the compute kernel sees the latest values.

## Behaviours vs. Custom Updates

- Prefer `SSKParticleBehaviorOptionFadeAlpha` and `SSKParticleBehaviorOptionFadeSize` + `sizeOverLifeRange` for time-based falloff. This path works identically on CPU and GPU.
- If you attach `updateHandler`, Metal simulation is disabled automatically. Use this when you truly need per-frame custom math in Objective-C (e.g. collision callbacks).

## When Things Go Wrong

- **Black screen with Metal** – Ensure you are running on macOS 11+ with a Metal-capable GPU. You can force the CPU path by toggling `system.metalSimulationEnabled = NO;`.
- **Particles never appear** – Double-check that `spawnParticles:` is called regularly and that `maxLife` is > 0. Also confirm you are setting `color` to something non-transparent inside the initializer block.
- **Visual mismatch between Metal and CPU** – Keep custom logic inside the behaviour system or maintain equivalent code paths for CPU and GPU. If behaviour flags don’t cover your effect, consider setting a tiny `updateHandler` only when Metal is unavailable.

## Integration Tips

1. Reuse a single `SSKParticleSystem` instance; the capacity parameter is fixed for the lifetime of the object.
2. When you rebuild or reset entire effects, call `reset` on the system—this clears internal bookkeeping and, in GPU mode, synchronises the contents back to the compute buffer.
3. Pair the system with `SSKMetalParticleRenderer` for very cheap instanced rendering. If Metal is unavailable the CPU `drawInContext:` path still works.
4. Want palette-driven colours? Store your palette index/progress in `userScalar` or `userVector` and resolve the actual `NSColor` when you spawn new particles.

That should give both humans and tooling (including LLMs) enough context to use the particle system effectively. Refer to `Demos/RibbonFlow` and `Demos/DVDlogo` in the repository for concrete usage patterns.
