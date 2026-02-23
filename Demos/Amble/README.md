# Amble Screensaver

A Metal-accelerated screensaver that simulates 2D fluid dynamics using the Stable Fluids algorithm (Jos Stam) and visualizes the velocity field as a grid of flowing line particles. Inspired by [Flux](https://github.com/sandydoo/flux).

## Features

- **Stable Fluids simulation** - Full Navier-Stokes solver on GPU (advection, diffusion, pressure projection)
- **MacCormack advection** - Higher-order advection with error correction for sharper fluid detail
- **3-layer curl noise** - Organic, divergence-free forcing at multiple spatial scales
- **Line particle visualization** - Grid of oriented lines that flow with the velocity field
- **Color presets** - Four palettes (Original, Plasma, Poolside, Freedom)
- **Additive blending + bloom** - Creates a glowing, energetic visual aesthetic
- **GPU-accelerated** - All simulation and rendering runs on the GPU via Metal compute and render shaders
- **Configurable** - Full preferences panel for tuning simulation, rendering, and post-processing

## Building

```bash
cd Demos/Amble
make
make install
```

The screensaver will be installed to `~/Library/Screen Savers/`.

## Configuration

Open System Settings > Screen Saver, select Amble, and click Options to access:

### Simulation
- **Viscosity** (0.1-20.0) - Fluid viscosity; higher values produce smoother, more diffused flow
- **Noise Multiplier** (0-2.0) - Strength of the curl noise forcing that drives the fluid
- **Dissipation** (0.99-1.0) - Velocity decay per step; lower values make flow fade faster

### Rendering
- **Grid Spacing** (5-30) - Pixels between line particles; smaller = denser grid
- **Line Length** (2-20) - Base half-length of each line in pixels
- **Line Width** (0.5-5) - Base half-width of each line in pixels
- **Color Palette** - Choose from Original, Plasma, Poolside, or Freedom

### Post-Processing
- **Bloom Intensity** (0-1.0) - Glow effect strength
- **Bloom Threshold** (0-1.0) - Brightness threshold for bloom extraction

## Technical Details

- Uses custom Metal compute shaders for the Stable Fluids pipeline (7 kernels)
- Custom Metal render shaders for instanced line particle rendering
- Fluid simulation runs at 256-wide grid resolution (aspect-ratio matched)
- MacCormack advection with neighbor-clamped correction
- Jacobi iteration: 3 passes for diffusion, 19 passes for pressure
- Does not use SSKParticleSystem; fully custom GPU pipeline
- Falls back to a static message on systems without Metal
