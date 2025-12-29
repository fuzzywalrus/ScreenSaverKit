# Rain Screensaver

A classic rain animation screensaver using ScreenSaverKit's particle system with hardware-accelerated GPU rendering.

## Features

- **Classic retro rain effect** - Simple line-based rain drops for that nostalgic screensaver feel
- **Adjustable angle** - Control the rain direction from -45° to +45°
- **Variable speed** - Adjust rain speed from 500 to 10,000 pixels per second
- **Density control** - Spawn up to 1,000 particles per second for heavy downpours
- **Brightness adjustment** - Control rain brightness from dark grey to light/white
- **Width and length** - Customize drop width (1-20) and length multiplier (1-100)
- **Z-depth effect** - Optional perspective depth effect where distant drops move slower, appear shorter, and are darker, creating a realistic 3D depth illusion
- **Hardware acceleration** - GPU-accelerated particle spawning and simulation using Metal
- **FPS counter** - Optional on-screen FPS display for performance monitoring

## Building

```bash
cd Demos/Rain
make
make install
```

The screensaver will be installed to `~/Library/Screen Savers/`.

## Configuration

The screensaver includes a configuration panel with the following options:

- **Rain Angle**: Direction of rain (-45° to +45°, where 0° is straight down)
- **Rain Speed**: Velocity of rain drops (500-10,000 pixels/second)
- **Rain Density**: Number of particles spawned per second (50-1,000)
- **Brightness**: Greyscale brightness of rain drops (0.0 = dark grey, 1.0 = light/white)
- **Width**: Width of individual rain drops (1.0-20.0)
- **Length**: Length multiplier for rain drops (1.0-100.0)
- **Enable Z-Depth**: Toggle perspective depth effect. When enabled, distant drops will:
  - Move slower (creating parallax/perspective effect)
  - Appear shorter in length
  - Be darker (less visible)
  - This creates a realistic 3D depth illusion where closer rain appears faster and brighter
- **Z-Depth Scale**: Controls the depth variation range (0.1-100.0)
  - Lower values (0.1-1.0): Subtle depth effect, most drops appear closer
  - Medium values (1.0-10.0): Moderate depth variation
  - Higher values (10.0-100.0): Strong depth effect with more distant drops
  - The scale maps to a minimum z-depth: scale 1 → min ~0.5, scale 100 → min ~0.2 (floor)
  - Higher scales create more dramatic depth separation between near and far drops
- **Show FPS Counter**: Toggle on-screen FPS display

## Technical Details

- Uses `SSKParticleSystem` with Metal simulation enabled
- GPU-accelerated particle spawning via `spawnParticlesGPU:parameters:`
- **Z-depth implementation**:
  - Z-depth values calculated on GPU during particle initialization
  - Each particle gets a random z-depth value (0.2-1.0 by default, adjustable via scale)
  - Velocity is scaled by z-depth: `velocity *= zDepth` (far drops move slower)
  - Length is scaled by z-depth: `length = width * lengthMultiplier * zDepth` (far drops are shorter)
  - Color brightness is scaled by z-depth: `brightness *= (0.3 + zDepth * 0.7)` (far drops are darker)
  - All z-depth calculations performed on GPU for optimal performance
- Supports up to 1,000 simultaneous particles
- Falls back to CPU rendering if Metal is unavailable
- Particle capacity: 1,000 particles

## Z-Depth Effect Explained

The z-depth feature creates a realistic 3D perspective effect by simulating how objects appear at different distances from the viewer:

### How It Works

1. **Z-Depth Assignment**: Each rain drop is assigned a random z-depth value when spawned
   - Range: minimum (based on scale) to 1.0 (closest)
   - Scale 1.0 → minimum ~0.5 (subtle effect)
   - Scale 100.0 → minimum ~0.2 (strong effect, floor to prevent drops from being too slow)

2. **Velocity Scaling**: `velocity *= zDepth`
   - Far drops (z-depth = 0.2) move at 20% speed
   - Close drops (z-depth = 1.0) move at 100% speed
   - Creates the parallax effect where distant objects appear to move slower

3. **Length Scaling**: `length = width * lengthMultiplier * zDepth`
   - Far drops appear shorter (perspective foreshortening)
   - Close drops appear longer
   - Mimics how objects appear smaller when further away

4. **Color Darkening**: `brightness *= (0.3 + zDepth * 0.7)`
   - Far drops are 30% brightness (darker, less visible)
   - Close drops are 100% brightness (brighter, more visible)
   - Simulates atmospheric perspective and reduced visibility at distance

### Using Z-Depth Effectively

- **For subtle depth**: Use scale 1.0-5.0, most drops will appear relatively close
- **For moderate depth**: Use scale 5.0-20.0, good balance of near and far drops
- **For dramatic depth**: Use scale 20.0-100.0, creates strong separation with many distant drops
- **Combine with density**: Higher density (500-1000) works well with z-depth to create a rich, layered rain effect
- **Adjust brightness**: Lower brightness (0.3-0.5) can enhance the depth illusion by making distant drops less visible

## Performance

The screensaver is optimized for performance with:
- Hardware-accelerated particle spawning and simulation
- Efficient GPU-based z-depth calculations (all depth effects computed in parallel)
- Optimized particle rendering pipeline
- Support for high particle counts (up to 1,000)

For best performance, ensure Metal is available on your system. Z-depth adds minimal overhead since all calculations are performed on the GPU during particle initialization.

