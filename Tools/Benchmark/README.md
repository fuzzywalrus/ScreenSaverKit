# ScreenSaverKit Benchmark Tool

Command-line tool for automated performance benchmarking of ScreenSaverKit particle system.

## Building

```bash
cd Tools/Benchmark
make
```

The executable will be created at `Build/ssk-benchmark`.

## Usage

### Basic Usage

Run all benchmark scenarios and output JSON:
```bash
./Build/ssk-benchmark
```

### Output Formats

**JSON (default):**
```bash
./Build/ssk-benchmark --format json
```

**CSV:**
```bash
./Build/ssk-benchmark --format csv
```

### Save to File

```bash
./Build/ssk-benchmark --format json --output results.json
./Build/ssk-benchmark --format csv --output results.csv
```

### Run Specific Scenario

```bash
./Build/ssk-benchmark --scenario spawn_100_particles_gpu
```

### List Available Scenarios

```bash
./Build/ssk-benchmark --list-scenarios
```

## Available Scenarios

- `spawn_100_particles_cpu` - Spawn 100 particles, CPU simulation
- `spawn_100_particles_gpu` - Spawn 100 particles, GPU simulation
- `spawn_500_particles_cpu` - Spawn 500 particles, CPU simulation
- `spawn_500_particles_gpu` - Spawn 500 particles, GPU simulation
- `spawn_1000_particles_cpu` - Spawn 1000 particles, CPU simulation
- `spawn_1000_particles_gpu` - Spawn 1000 particles, GPU simulation

## Output Format

### JSON Output

```json
{
  "timestamp": 1702645200.0,
  "device": "Apple M4 Pro",
  "lowPower": false,
  "scenarios": [
    {
      "name": "spawn_100_particles_cpu",
      "duration_ms": 25.5,
      "particles_spawned": 100,
      "particles_alive": 100,
      "path": "CPU",
      "memory_mb": 45,
      "spawnTime_ms": 2.1,
      "simulationTime_ms": 18.3,
      "avgSimulationTime_ms": 0.305,
      "iterations": 60
    }
  ]
}
```

### CSV Output

```csv
Scenario,Path,Particles Spawned,Particles Alive,Duration (ms),Spawn Time (ms),Avg Sim Time (ms),Memory (MB)
spawn_100_particles_cpu,CPU,100,100,25.50,2.10,0.31,45
spawn_100_particles_gpu,GPU,100,100,8.20,0.50,0.12,48
```

## Interpreting Results

### Performance Metrics

- **duration_ms**: Total time for the benchmark
- **spawnTime_ms**: Time to spawn all particles
- **simulationTime_ms**: Total simulation time for all iterations
- **avgSimulationTime_ms**: Average time per simulation step
- **memory_mb**: Peak memory usage during benchmark

### Expected Performance

**CPU Path:**
- 100 particles: ~0.3ms per step
- 500 particles: ~1.5ms per step
- 1000 particles: ~3.0ms per step

**GPU Path:**
- 100 particles: ~0.1ms per step (3x faster)
- 500 particles: ~0.3ms per step (5x faster)
- 1000 particles: ~0.5ms per step (6x faster)

### Regression Detection

Compare results across builds:
```bash
# Baseline
./Build/ssk-benchmark --output baseline.json

# After changes
./Build/ssk-benchmark --output current.json

# Compare (requires jq or similar)
diff baseline.json current.json
```

## CI/CD Integration

Example GitHub Actions workflow:
```yaml
- name: Run Benchmarks
  run: |
    cd Tools/Benchmark
    make
    ./Build/ssk-benchmark --format json --output benchmark-results.json
    
- name: Upload Results
  uses: actions/upload-artifact@v3
  with:
    name: benchmark-results
    path: Tools/Benchmark/benchmark-results.json
```

## Troubleshooting

- **"Metal not available"**: Benchmark will still run using CPU path
- **Slow results**: Normal for first run (cold start), subsequent runs are more accurate
- **Memory spikes**: Expected during particle spawning, should stabilize


