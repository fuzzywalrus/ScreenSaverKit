# ScreenSaverKit Architecture Documentation Index

This directory contains comprehensive documentation about the ScreenSaverKit effect chaining and Metal rendering architecture.

## Documentation Files

### 1. **ARCHITECTURE_ANALYSIS.md** (Primary Reference)
**Length**: ~750 lines | **Focus**: In-depth technical analysis

Comprehensive analysis covering:
- Current architecture overview (SSKMetalRenderer, SSKMetalPass hierarchy)
- Effect Passes (Particle, Trail, Blur, Bloom)
- Metal shader libraries (SSKParticleShaders + SSKSimulationShaders)
- Effect chaining implementation (including trail persistence)
- Particle system integration (curl noise, attractors, color gradient, ribbon mode)
- Texture cache strategy
- Design patterns for adding new effects
- Coupling and architectural issues
- Testing architecture (145 tests across 6 test suites)
- Recent optimizations and refactorings

**Best for**: Understanding how the system works, identifying design issues, planning improvements

### 2. **ARCHITECTURE_DIAGRAMS.md** (Visual Reference)
**Length**: ~550 lines | **Focus**: Visual component relationships

Includes diagrams for:
1. Component hierarchy (renderer + particle system simulation)
2. Frame rendering pipeline (with trail persistence + indirect rendering)
3. Texture flow in effect chain
4. Particle system architecture (simulation forces, behavior flags, render paths)
5. Metal shader organization (2 shader libraries: rendering + simulation)
6. Texture cache management
7. Dependency graph (renderer + particle system dependencies)
8. Recent changes timeline
9. Effect chain ordering (current vs desired)
10. Class relationships (including SSKMetalTrailPass)
11. Trail persistence data flow
12. Indirect rendering pipeline (GPU-only, single command buffer)

**Best for**: Quick visual understanding, presentations, identifying dependencies

### 3. **EFFECT_IMPLEMENTATION_GUIDE.md** (Practical Reference)
**Length**: ~615 lines | **Focus**: How-to and practical examples

Includes:
- Quick reference table of key files
- Frame rendering flow examples (minimal → full chain)
- Detailed explanation of each pass (Particle, Blur, Bloom)
- Texture cache explanation and usage patterns
- Step-by-step guide: Adding a new effect (Color Shift example)
- Common patterns and best practices
- Debugging tips and performance considerations
- Troubleshooting table

**Best for**: Learning by example, adding new effects, debugging issues

### 4. **PERFORMANCE_OPTIMIZATIONS.md** (Performance Reference)
**Location**: `../PERFORMANCE_OPTIMIZATIONS.md` (root directory)
**Length**: ~800 lines | **Focus**: Performance optimization guide

Includes:
- Three major particle system optimizations (December 2024):
  - Alive Particle Tracking (~100x speedup for sparse systems)
  - Async Rendering Mode (-0.1 to -0.3ms per frame)
  - Indirect Rendering (-0.2 to -0.5ms per frame)
- Implementation details and technical deep dive
- Usage examples and migration guide
- Performance benchmarking methodology
- Trade-off analysis and optimization strategy
- Troubleshooting guide

**Best for**: Maximizing performance, understanding GPU optimizations, choosing the right optimization strategy

---

## Quick Start by Use Case

### "I need to understand the current architecture"
1. Read: **ARCHITECTURE_ANALYSIS.md** (Overview section)
2. Reference: **ARCHITECTURE_DIAGRAMS.md** (Component Hierarchy, Frame Pipeline)
3. Code: `../ScreenSaverKit/SSKMetalRenderer.h`

### "I want to add a new effect"
1. Reference: **EFFECT_IMPLEMENTATION_GUIDE.md** (Adding New Effects section)
2. Code template: Same document includes Color Shift example (Steps 1-4)
3. Pattern: Look at `SSKMetalBlurPass.h/m` as reference implementation

### "I'm debugging a rendering issue"
1. Check: **ARCHITECTURE_DIAGRAMS.md** (Texture Flow diagram)
2. Read: **EFFECT_IMPLEMENTATION_GUIDE.md** (Debugging Tips, Troubleshooting)
3. Reference: **ARCHITECTURE_ANALYSIS.md** (Integration Points section)

### "I want to refactor or improve the system"
1. Read: **ARCHITECTURE_ANALYSIS.md** (Coupling and Architectural Issues section)
2. Review: **ARCHITECTURE_DIAGRAMS.md** (Dependency Graph)
3. Consider: Recommended Improvements section of ARCHITECTURE_ANALYSIS.md

### "I'm new to Metal or particle rendering"
1. Start: **EFFECT_IMPLEMENTATION_GUIDE.md** (Understanding the Frame Rendering Flow)
2. Study: Texture Cache section
3. Deep dive: **ARCHITECTURE_ANALYSIS.md** (Particle System Integration section)

### "I want to understand the test suite"
1. Read: **ARCHITECTURE_ANALYSIS.md** (Testing Architecture section)
2. Reference: `../Tests/README.md` for test organization and running tests
3. Code: `../Tests/SSKParticleSystemTests.m` for example test patterns

### "I need to optimize particle system performance"
1. Start: **PERFORMANCE_OPTIMIZATIONS.md** (Overview and Usage sections)
2. Enable: Async rendering mode and indirect rendering (Quick Start examples)
3. Measure: Use benchmark tools in `../Tools/Benchmark/` to verify improvements
4. Troubleshoot: Performance Characteristics sections for each optimization

---

## Key Concepts Summary

### Effect Chain Architecture
- **Coordinator**: `SSKMetalRenderer` manages all effects
- **Base Class**: `SSKMetalPass` defines interface for all effects
- **Implementations**: `SSKMetalParticlePass`, `SSKMetalSpritePass`, `SSKMetalTrailPass`, `SSKMetalBlurPass`, `SSKMetalBloomPass`
- **Chain Pattern**: `drawParticles()` / `drawSprites()` → [trail] → applyBlur() → applyBloom() → endFrame()

### Rendering Pipeline
```
Particles (CPU/GPU) → [Trail Persist] → Render to drawable → Optional blur → Optional bloom → Present
```

### Key Design Patterns
1. **FX Pass Pattern**: Each effect is independent, testable pass
2. **Texture Pooling**: Cache reuses intermediate textures (reduces allocation overhead)
3. **Separable Blur**: 2D blur done as 2x 1D passes (faster)
4. **In-Place Processing**: Effects write back to same texture they read from
5. **Optional Effects**: All post-processing effects are optional (can be disabled)
6. **Feature-Flagged Simulation**: GPU simulation uses bitmask to enable/disable forces per-particle
7. **Indirect Rendering**: GPU-side instance buffer building eliminates CPU readback

### Recent Improvements
- **Curl Noise Force Field**: Divergence-free 2D simplex noise for organic swirling motion
- **Attractor Points**: Up to 4 configurable attractors with inverse-square falloff
- **Trail Persistence**: Persistent offscreen texture for long luminous trails (`SSKMetalTrailPass`)
- **Color Gradient**: Half-float packed `endColor` for smooth lifetime color transitions
- **Per-Particle Rotation**: Rotation velocity integrated on GPU, applied in vertex shader
- **Ribbon Mode**: Connected trail strips via fully GPU-driven pipeline (no CPU readback)
- **Indirect Rendering**: GPU-side instance building for large particle counts
- **Simulation Shader Library**: Moved GPU simulation to dedicated `SSKSimulationShaders.metal`
- **Flux Demo**: Showcases all new features (curl noise + attractors + trails + bloom)
- **GPU Z-Depth**: Hardware-accelerated perspective depth effects in particle spawning
- **Optimized Thread Groups**: Dynamic sizing based on GPU architecture
- **Thread-Safe Free-List**: Serial queue for particle index management

---

## File Cross-Reference

### By Component

#### SSKMetalRenderer
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Current Architecture Overview" → "SSKMetalRenderer"
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Component Hierarchy", "Dependency Graph"
- **Guide**: EFFECT_IMPLEMENTATION_GUIDE.md → "Adding a New Effect" (Step 3)

#### SSKMetalParticlePass
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Effect Passes" → "SSKMetalParticlePass"
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Frame Rendering Pipeline"
- **Guide**: EFFECT_IMPLEMENTATION_GUIDE.md → "Understanding Each Pass" → "Particle Pass"

#### SSKMetalSpritePass
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Testing Architecture" (SSKSpriteTests); renderer exposes `spritePass`
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Component Hierarchy" (added below)
- **Guide**: Main README → "Using Metal-Accelerated Sprites"; `Demos/DVDLogoMetal/README.md`
- **Code**: `../ScreenSaverKit/SSKMetalSpritePass.h/m`, `../ScreenSaverKit/Shaders/SSKSpriteShaders.metal`

#### SSKMetalBlurPass
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Effect Passes" → "SSKMetalBlurPass"
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Texture Flow", "Metal Shader Organization"
- **Guide**: EFFECT_IMPLEMENTATION_GUIDE.md → "Understanding Each Pass" → "Blur Pass"

#### SSKMetalBloomPass
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Effect Passes" → "SSKMetalBloomPass"
- **Coupling Issue**: ARCHITECTURE_ANALYSIS.md → "Coupling and Architectural Issues" → Issue #1
- **Guide**: EFFECT_IMPLEMENTATION_GUIDE.md → "Understanding Each Pass" → "Bloom Pass"

#### SSKMetalTextureCache
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Texture Cache Strategy"
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Texture Cache Management"
- **Guide**: EFFECT_IMPLEMENTATION_GUIDE.md → "Texture Cache: The Hidden Hero"

#### SSKMetalTrailPass
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Effect Passes" → "SSKMetalTrailPass"
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Trail Persistence Data Flow", "Component Hierarchy"
- **Code**: `../ScreenSaverKit/SSKMetalTrailPass.h/m`

#### SSKMetalPass (Abstract Base)
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Current Architecture Overview" → "SSKMetalPass"
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Class Relationships"
- **Guide**: EFFECT_IMPLEMENTATION_GUIDE.md → "Adding a New Effect" (Step 1)

#### SSKSimulationShaders
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Metal Shader Libraries" → "SSKSimulationShaders"
- **Diagram**: ARCHITECTURE_DIAGRAMS.md → "Metal Shader Organization"
- **Code**: `../ScreenSaverKit/Shaders/SSKSimulationShaders.metal`

#### Testing Infrastructure (145 tests)
- **Analysis**: ARCHITECTURE_ANALYSIS.md → "Testing Architecture"
- **Tests**: `../Tests/` directory with XCTest-based test suite
- **Coverage**: Unit tests for all major components including trail pass, curl noise, attractors, rotation
- **Performance**: See `PERFORMANCE_TESTING.md` for performance benchmarking tools

---

## Issues and Improvements

### Current Architectural Issues (with fix recommendations)

| Issue | Severity | Location in Docs | Recommendation |
|-------|----------|------------------|-----------------|
| Bloom-Blur coupling | Medium | ARCHITECTURE_ANALYSIS.md:244-251 | Decouple or use internal blur |
| Renderer-centric design | Medium | ARCHITECTURE_ANALYSIS.md:253-258 | Pass registry/dependency injection |
| No effect ordering | Low | ARCHITECTURE_ANALYSIS.md:260-265 | Configuration-based ordering |
| Limited texture support | Low | ARCHITECTURE_ANALYSIS.md:267-269 | Enhance setRenderTarget: |

---

## Code Examples in Documentation

### EFFECT_IMPLEMENTATION_GUIDE.md Examples

1. **Minimal particle rendering**: Particles Only example
2. **Particles + Blur**: Motion blur setup
3. **Particles + Bloom**: Glow effect setup
4. **Full chain**: All effects together
5. **Custom effect**: Color Shift implementation (4 steps with full code)
6. **Common patterns**: 4 reusable patterns

All examples include:
- Complete code listings
- Explanations of what each step does
- Relevant parameter ranges
- Integration instructions

---

## References for Further Reading

### Within ScreenSaverKit
- `README.md` - Project overview and getting started
- `tutorial.md` - End-to-end screensaver creation guide
- `SSKParticleSystem.md` - Detailed particle system documentation

### Metal Resources
- Apple's Metal documentation
- Metal Shading Language (MSL) reference
- Metal Performance Optimization guides

### Related Source Files
- `../ScreenSaverKit/SSKMetalRenderer.h` - Public API reference (trail persistence, indirect rendering, drawSprites)
- `../ScreenSaverKit/SSKMetalTrailPass.h` - Trail persistence pass API
- `../ScreenSaverKit/SSKMetalParticlePass.h` - Particle pass API (ribbon mode, indirect)
- `../ScreenSaverKit/SSKMetalSpritePass.h` - Sprite pass API (instanced 2D sprites)
- `../ScreenSaverKit/Shaders/SSKParticleShaders.metal` - Rendering shaders (indirect, ribbon, trail fade)
- `../ScreenSaverKit/Shaders/SSKSpriteShaders.metal` - Sprite vertex/fragment shaders
- `../ScreenSaverKit/Shaders/SSKSimulationShaders.metal` - GPU simulation (curl noise, attractors, color gradient)
- `../ScreenSaverKit/SSKParticleSystem.h` - Particle system API (noise, attractors, spawn parameters)
- `../ScreenSaverKit/SSKSprite.h` - Sprite model (position, size, animation, etc.)
- `../Demos/Flux/FluxView.m` - Advanced usage (curl noise + attractors + trails + bloom)
- `../Demos/RibbonFlow/RibbonFlowView.m` - Ribbon mode usage example
- `../Demos/Rain/RainView.m` - Z-depth implementation example
- `../Demos/DVDLogoMetal/` - Sprite rendering example

---

## Document Maintenance Notes

These documents were last updated: **2026-02-21**. Architecture validated **2025-01-09**: component list, renderer properties, shader files, test count (145 tests, 6 suites), Demos (Flux, RibbonFlow, Rain, DVDLogoMetal), and sprite pass added to diagrams/index/guide.

Based on codebase state:
- Current branch: `main`
- Latest features: Curl noise, attractors, trail persistence, ribbon mode, indirect rendering
- Key refactors: `2a174b8` (FX Passes architecture), 8-phase particle system expansion

The documentation covers:
- All effect passes currently in the system (particle, trail, blur, bloom)
- Simulation shader library (curl noise, attractors, color gradient)
- Current architectural patterns and issues
- Implementation patterns and examples (including Flux-style advanced usage)
- Recent optimizations and improvements
- GPU-accelerated z-depth support for perspective effects
- Particle spawn optimizations (thread groups, async spawn, fallback compilation)
- Indirect rendering and ribbon mode GPU pipelines
- 145 tests across 6 test suites

If you modify the rendering system, please update:
1. Relevant diagram in ARCHITECTURE_DIAGRAMS.md
2. New coupling relationships in ARCHITECTURE_ANALYSIS.md
3. Usage examples in EFFECT_IMPLEMENTATION_GUIDE.md

