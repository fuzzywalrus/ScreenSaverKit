# Luminaire Screensaver

A Metal-accelerated screensaver that produces flowing, luminous particle streams driven by curl noise and attractor points.

## Features

- **Curl noise flow field** - Divergence-free 2D noise creates organic, swirling particle motion
- **Orbiting attractors** - Two attractor points slowly orbit the screen center, pulling particle streams into vortex patterns
- **Trail persistence** - Particles leave long, luminous trails that slowly fade over time
- **Color palettes** - Six built-in palettes (Rainbow Cycle, Ocean, Fire, Aurora, Neon, Monochrome)
- **Additive blending + bloom** - Creates a glowing, energetic visual aesthetic
- **GPU-accelerated** - All simulation and rendering runs on the GPU via Metal
- **Configurable** - Full preferences panel for tuning visuals, colors, and physics

## Building

```bash
cd Demos/Luminaire
make
make install
```

The screensaver will be installed to `~/Library/Screen Savers/`.

## Configuration

Open System Settings > Screen Saver, select Luminaire, and click Options to access:

### Core Visuals
- **Particle Count** (1024-8192) - Number of particles in the system
- **Trail Persistence** - Toggle persistent particle trails
- **Trail Fade Rate** (0.005-0.1) - How quickly trails fade
- **Bloom Intensity** (0-2.0) - Glow effect strength

### Colors
- **Color Palette** - Choose from Rainbow Cycle, Ocean, Fire, Aurora, Neon, or Monochrome
- **Cycle Speed** (0-0.2) - How fast colors cycle through the palette
- **Background** - Background color picker

### Physics
- **Noise Strength** (0-500) - Curl noise force magnitude
- **Noise Scale** (0.001-0.01) - Spatial frequency (smaller = larger swirls)
- **Damping** (0.9-1.0) - Velocity damping per frame
- **Attractor Force** (0-10000) - Strength of the orbiting attractor points

## Technical Details

- Uses `SSKParticleSystem` with Metal compute simulation
- GPU-accelerated particle spawning via `spawnParticlesGPU:parameters:`
- Behavior flags: `FadeAlpha | ColorGradient | CurlNoise | Attractors`
- Trail rendering via `SSKMetalTrailPass` (persistent offscreen texture with fade kernel)
- Bloom post-processing via `SSKMetalBloomPass`
- Falls back to a static message on systems without Metal
