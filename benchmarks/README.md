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

The Raxon-only runners (`bin/profile`, `bin/allocations`, `bin/compare`) add a
fourth:

- `GET /search?limit=10&status=active&cursor=abc123` (`validated_params`) -
  typed and constrained query parameters

It exists to keep validation in view. `/users/123` declares one unconstrained
string parameter, so on its own it measures routing and response building more
than it measures validation — and validation is the expensive part of a
validating framework. `/search` gives dry-schema real work: a type that needs
coercion, an enum, and a length bound. It costs roughly 2.5x what `/users/123`
does, and nearly all of the difference is `Dry::Schema::Processor#call`.

It is not in `bin/run`: that compares frameworks, and Rack, Roda, and Sinatra do
no schema validation, so an endpoint whose cost is almost entirely validation
would not be comparing like with like.

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

## Profiler benchmark

To find slow paths inside Raxon, run the same endpoint shapes in-process under the
[Vernier](https://github.com/jhawthorn/vernier) profiler:

```bash
ruby benchmarks/bin/profile
```

This drives `plaintext`, `json`, and `path_param` through `Raxon::Server#call` without
starting a server, so the samples cover routing, request parsing, validation, and response
building rather than Puma and socket work. Rack env hashes are prebuilt outside the profiled
window, and each endpoint gets its own warmup pass so JIT/inline caches are settled.

Profiles are written to `benchmarks/tmp/profiles/raxon-<endpoint>-<mode>.vernier.json` and the
hottest frames by self time are printed inline. Open a profile with
[vernier.prof](https://vernier.prof) or `bundle exec vernier view <file>`.

Each run also writes `raxon-<endpoint>-<mode>.folded` — folded stacks, one line per
root-to-leaf path as `frame;frame;frame <samples>`. That is what speedscope,
`flamegraph.pl`, and inferno read, and unlike the JSON it is legible on its own and
diffable between two runs, which is what makes a flame graph useful for judging a change
rather than only for looking at one:

```bash
ruby benchmarks/bin/profile --endpoints path_param
diff <(sort tmp/before/raxon-path_param-wall.folded) \
     <(sort tmp/profiles/raxon-path_param-wall.folded)
```

Pass `--no-folded` to skip them. The benchmark harness sits at the base of every stack
(`<main>` → `Object#drive` → `Object#call_app`); the request itself starts at
`Raxon::Server#call`, which is where a viewer is worth zooming to.

Useful options:

```bash
ruby benchmarks/bin/profile --endpoints json,path_param
ruby benchmarks/bin/profile --iterations 50000 --warmup 5000
ruby benchmarks/bin/profile --mode cpu            # wall (default), cpu, or retained
ruby benchmarks/bin/profile --allocations 100     # also sample every 100th allocation
ruby benchmarks/bin/profile --top 25              # more inline frames (0 disables)
ruby benchmarks/bin/profile --output-dir tmp/before
```

Comparing a `--output-dir tmp/before` run against `tmp/after` is the quickest way to check
whether an optimization actually moved the hot path.

## Route lookup as an application grows

```bash
ruby benchmarks/bin/routing
ruby benchmarks/bin/routing --resources 1,10,100 --iterations 100000
```

The other benchmarks measure one request against a handful of routes, which says
nothing about the cost that scales with the size of the application rather than
the size of the request. This one models a REST resource as they usually come —
list, create, show, update, delete, two state changes, a copy: eight routes, six
of them dynamic — and grows the number of resources.

```
resources      routes        static       dynamic  deep dynamic
1                   8        0.19us        1.52us        2.17us
100               800        0.20us        2.90us        3.16us
```

It is here because this cost was invisible for a long time. The benchmark app
declares one dynamic route, so route lookup measured ~1.5us and looked like a
rounding error; a real API with 800 routes was spending 162us per request
resolving a path.

## Comparing two revisions

To measure whether a change actually helped:

```bash
ruby benchmarks/bin/compare                     # working tree vs main
ruby benchmarks/bin/compare --base HEAD~1
ruby benchmarks/bin/compare --endpoints json,path_param --reps 15
```

```
endpoint                   main working tree     change
plaintext                7.26us       6.74us      -7.2%
json                    23.63us       8.43us     -64.3%
path_param              48.12us      19.12us     -60.3%
```

Use this rather than running `bin/profile` before and after and comparing the
numbers. That approach is not reliable enough here to resolve the size of change
optimization work produces: a sub-microsecond difference in a 20us request is
inside this machine's GC and scheduler noise. Measuring several endpoints in one
process compounds it, because whichever runs first is measured against a
different heap than the one that runs last.

Two changes in this repository's history were mismeasured that way — one
appeared to make a request 11% faster by wall clock and 18% slower by CPU time
in the same session, and another was recorded in the changelog as a 23%
improvement that a controlled comparison put at 9%. `bin/compare` runs one
endpoint per process, measures CPU time rather than wall clock, takes the median
of several repetitions, and alternates revisions so a drifting machine moves
both numbers together.

For a change too small for even that to resolve, time the specific operation in
a tight loop and check `bin/allocations`, which is deterministic.

## Environment

All three runners force `RAXON_ENV=production` and `RACK_ENV=production`, and
ignore whatever is in your shell. This is not a fairness nicety, it is the
difference between measuring the framework and measuring something else: in
development Raxon defaults to hot reloading, which runs a `Dir.glob` over the
routes directory and a `File.mtime` per file on **every request**. Benchmarked
in development, `Dir.glob` is 70% of the profile and a plaintext response takes
~400us instead of ~7us.

`bin/profile` and `bin/allocations` also abort if route reloading is somehow
still on, rather than reporting numbers that look plausible and mean nothing.

To measure development-mode cost deliberately, change the env vars at the top of
the runner — it should be an edit you make on purpose, not a shell variable you
forgot about.

## Notes on fairness

These benchmarks are intentionally small and local. They are useful for quick iteration, but they are not a substitute for a controlled environment or the TechEmpower FrameworkBenchmarks suite.

Keep comparisons fair by using the same:

- Ruby version
- rackup/Puma versions
- thread and connection counts
- hardware and power settings
- production environment settings

The `rack` app is a lower-level baseline, not a web framework comparison point.
