# Performance Testing Guide for ScreenSaverKit

This guide explains how to use the performance testing and benchmarking tools in ScreenSaverKit.

## Overview

ScreenSaverKit includes three performance testing components:

1. **Unit Tests** (`Tests/`) - Functional correctness tests
2. **Performance Benchmark Screensaver** (`Demos/PerformanceBenchmark/`) - Real-time metrics visualization
3. **Standalone Benchmark Tool** (`Tools/Benchmark/`) - Automated performance regression testing

## Quick Start

### Run Unit Tests
```bash
cd Tests
make test
```

### Use Benchmark Screensaver
```bash
cd Demos/PerformanceBenchmark
make install
# Then select in System Settings → Screen Saver
```

### Run Benchmark Tool
```bash
cd Tools/Benchmark
make
./Build/ssk-benchmark --format json --output results.json
```

## Performance Metrics Explained

### FPS (Frames Per Second)
- **Target**: 60 FPS for smooth animation
- **Acceptable**: 30-60 FPS
- **Problem**: < 30 FPS indicates performance issues

### Frame Time
- **Target**: < 16.67ms (60fps)
- **Acceptable**: 16.67-33.33ms (30-60fps)
- **Problem**: > 33.33ms (below 30fps)

### Particle Spawn Time
- **Small batches (1-100)**: < 1ms
- **Medium batches (100-500)**: < 5ms
- **Large batches (500-1000)**: < 10ms

### Simulation Time
- **CPU path**: ~0.003ms per particle
- **GPU path**: ~0.0005ms per particle (6x faster)
- **Target**: < 5ms total for 1000 particles

### Memory Usage
- **Base**: ~20-30 MB
- **Per 1000 particles**: +5-10 MB
- **Watch for**: Continuous growth (memory leak)

## Benchmark Scenarios

### 1. Spawn Stress Test
**Purpose**: Find maximum sustainable particle count

**How to interpret**:
- Watch FPS as particle count increases
- Note the particle count where FPS drops below 60
- This is your system's practical limit

**Expected results**:
- M4 Pro: ~2000-3000 particles at 60fps
- Older hardware: ~500-1000 particles at 60fps

### 2. GPU vs CPU Comparison
**Purpose**: Measure GPU acceleration benefit

**How to interpret**:
- Compare simulation times between GPU and CPU
- GPU should be 3-5x faster
- Both should produce identical visual results

**Expected results**:
- GPU simulation: 0.1-0.5ms per step
- CPU simulation: 0.3-2.0ms per step

### 3. Bloom Impact
**Purpose**: Measure post-processing cost

**How to interpret**:
- Compare FPS with bloom on vs off
- Bloom typically costs 2-5ms per frame
- Half-resolution bloom reduces cost by ~75%

**Expected results**:
- Full-res bloom: -5-10 FPS
- Half-res bloom: -1-3 FPS

### 4. Batch Spawn Performance
**Purpose**: Test optimized batch spawning

**How to interpret**:
- Spawn time should be < 5ms for 100 particles
- Batch spawn should be faster than individual spawns

**Expected results**:
- 100 particles: < 2ms
- 500 particles: < 5ms
- 1000 particles: < 10ms

### 5. Memory Leak Detection
**Purpose**: Detect memory leaks over time

**How to interpret**:
- Memory should stabilize after initial allocation
- Continuous growth indicates a leak
- Watch for memory growth > 10MB per minute

**Expected results**:
- Initial: 20-30 MB
- After 1 minute: 30-40 MB (stabilized)
- Problem: Continuous growth beyond 50 MB

## Regression Testing

### Automated Regression Detection

1. **Establish Baseline**:
   ```bash
   cd Tools/Benchmark
   make
   ./Build/ssk-benchmark --output baseline.json
   ```

2. **After Changes**:
   ```bash
   ./Build/ssk-benchmark --output current.json
   ```

3. **Compare Results**:
   - Use `jq` or similar tool to compare JSON
   - Look for > 10% performance degradation
   - Check for memory usage increases

### Performance Regression Checklist

- [ ] FPS decreased by > 10%
- [ ] Frame time increased by > 10%
- [ ] Spawn time increased significantly
- [ ] Memory usage increased unexpectedly
- [ ] GPU path no longer faster than CPU

## Best Practices

1. **Run benchmarks on clean system**: Close other apps
2. **Warm up**: Run benchmarks twice, use second result
3. **Multiple runs**: Average 3-5 runs for accuracy
4. **Consistent conditions**: Same resolution, same hardware
5. **Document baselines**: Save baseline results for comparison

## Troubleshooting Performance Issues

### Low FPS
1. Check particle count - reduce if too high
2. Disable bloom/post-processing
3. Verify Metal simulation is enabled
4. Check for memory pressure
5. Reduce spawn rate

### High Memory Usage
1. Run Memory Leak Detection scenario
2. Check for particle system capacity too high
3. Verify particles are expiring correctly
4. Look for retained references

### GPU Not Faster Than CPU
1. Verify Metal simulation is enabled
2. Check Metal device availability
3. Ensure sufficient particle count (GPU overhead for small counts)
4. Check for synchronization issues

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Performance Tests

on: [push, pull_request]

jobs:
  benchmark:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build Benchmark Tool
        run: |
          cd Tools/Benchmark
          make
      - name: Run Benchmarks
        run: |
          cd Tools/Benchmark
          ./Build/ssk-benchmark --format json --output results.json
      - name: Check Performance
        run: |
          # Add your regression detection logic here
          # Compare against baseline or threshold
```

## Additional Resources

- `Tests/README.md` - Unit test documentation
- `Demos/PerformanceBenchmark/README.md` - Benchmark screensaver guide
- `Tools/Benchmark/README.md` - Command-line tool documentation
- `PERFORMANCE_ANALYSIS.md` - Performance optimization analysis


