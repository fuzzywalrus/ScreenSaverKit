# Performance Benchmark Screensaver

A screensaver plugin that displays real-time performance metrics and runs configurable test scenarios to evaluate ScreenSaverKit performance.

## Features

- **Real-time Performance Metrics**: FPS, frame time, particle counts, memory usage
- **Configurable Test Scenarios**: 5 different benchmark scenarios
- **Visual Comparison**: GPU vs CPU performance comparison
- **Frame Time Histogram**: Visual representation of frame time consistency
- **Data Export**: Export performance data to JSON for analysis

## Test Scenarios

### 1. Spawn Stress Test
Gradually increases particle count to find the maximum sustainable particle count. Tests how the system handles increasing load.

### 2. GPU vs CPU Comparison
Toggles between GPU and CPU simulation paths every 5 seconds with the same particle count. Compare performance differences.

### 3. Bloom Impact
Toggles bloom post-processing on/off to measure the performance impact of bloom effects.

### 4. Batch Spawn
Tests batch particle spawning performance by spawning 100 particles at once every second.

### 5. Memory Leak Detection
Continuously spawns particles to detect memory leaks over time. Monitor memory usage trends.

## Metrics Displayed

- **FPS**: Current, average, min, max frames per second
- **Frame Time**: Time to render one frame in milliseconds
- **Particle Count**: Alive particles and total spawned
- **Simulation Time**: Time spent updating particles (CPU vs GPU)
- **Render Time**: Time spent rendering particles
- **Bloom Time**: Time spent on bloom post-processing (if enabled)
- **Memory Usage**: Current memory footprint in MB
- **Spawn Time**: Time to spawn particles

## Usage

### Building
```bash
cd Demos/PerformanceBenchmark
make
```

### Installing
```bash
make install
```

### Running
1. Open System Settings → Screen Saver
2. Select "Performance Benchmark"
3. Click "Screen Saver Options" to configure scenarios
4. Start the screensaver to see real-time metrics

### Configuration

Right-click the screensaver preview and select "Screen Saver Options" to:
- Select test scenario
- Start/stop data recording
- Export recorded data to JSON

### Exporting Data

1. Start recording in the configuration sheet
2. Let the screensaver run for your desired duration
3. Stop recording
4. Click "Export Data" to save JSON file
5. Analyze the data with your preferred tools

## Interpreting Results

- **FPS > 55**: Excellent performance
- **FPS 30-55**: Good performance
- **FPS < 30**: Performance issues, consider optimizations
- **Frame Time < 16.67ms**: Maintains 60fps
- **Frame Time > 33.33ms**: Below 30fps threshold

### GPU vs CPU Comparison
- GPU should show 3-5x faster simulation times
- GPU path may have slightly higher memory usage
- Both should produce visually identical results

### Bloom Impact
- Bloom typically adds 2-5ms per frame
- Half-resolution bloom reduces cost by ~75%
- Consider disabling bloom if FPS is below target

## Troubleshooting

- **Low FPS**: Reduce particle count, disable bloom, check Metal availability
- **Memory Growing**: Check for memory leaks in scenario 5
- **Metrics Not Updating**: Ensure screensaver is active (not just preview)


