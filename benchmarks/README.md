# Raxon framework benchmarks

This directory contains a small local benchmark suite for comparing Raxon with a few existing Ruby Rack frameworks under the same Puma/rackup setup.

Included apps:

- `rack` - tiny hand-written Rack baseline
- `roda`
- `sinatra`
- `raxon`
- `zap` - Zig implementation using [zigzap/zap](https://github.com/zigzap/zap)

Endpoints benchmarked for each app:

- `GET /plaintext` - plain text response
- `GET /json` - small JSON response
- `GET /users/123` - dynamic/path-parameter route with JSON response

## Setup

Install `wrk`:

```bash
brew install wrk
```

Install benchmark gems:

```bash
cd benchmarks
bundle install
```

To include the Zap benchmark, install Zig 0.16.0. The runner builds the Zap app automatically on first use:

```bash
ruby benchmarks/bin/run --frameworks zap
```

## Run

From the repository root:

```bash
ruby benchmarks/bin/run
```

Or from `benchmarks/`:

```bash
ruby bin/run
```

Results are written to `benchmarks/results.csv`.

Useful options:

```bash
ruby benchmarks/bin/run --frameworks rack,roda,sinatra,raxon,zap --endpoints plaintext,json,path_param
ruby benchmarks/bin/run --duration 10s --connections 50 --threads 4
ruby benchmarks/bin/run --frameworks raxon --endpoints json
```

## Allocation benchmark

To measure Ruby object allocations for Raxon request handling without starting a server:

```bash
ruby benchmarks/bin/allocations
```

This uses the same endpoint shapes as the speed benchmark (`plaintext`, `json`, and `path_param`). Rack env hashes are prebuilt outside the measured window so the reported count focuses on objects allocated while Raxon handles each request.

Results are written to `benchmarks/allocations.csv`.

Useful options:

```bash
ruby benchmarks/bin/allocations --endpoints json,path_param
ruby benchmarks/bin/allocations --iterations 50000 --warmup 5000
ruby benchmarks/bin/allocations --output tmp/allocations.csv
```

## Notes on fairness

These benchmarks are intentionally small and local. They are useful for quick iteration, but they are not a substitute for a controlled environment or the TechEmpower FrameworkBenchmarks suite.

Keep comparisons fair by using the same:

- Ruby version
- rackup/Puma versions
- thread and connection counts
- hardware and power settings
- production environment settings

The `rack` app is a lower-level baseline, not a web framework comparison point.
