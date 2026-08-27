# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Not yet released. The published `raxon` 0.1.0 gem contains only the
[0.1.0](#010---2025-11-08) section below; everything here lands in the next
release.

### Added

- Comprehensive README documentation with deployment guide, performance benchmarks, and framework comparisons
- Global error handler middleware (`Raxon::ErrorHandler`) for production safety
  - Catches unhandled exceptions and returns secure JSON responses
  - Optional logging with full error details
  - Optional error notification callbacks for services like Sentry
- Security hardening for route loading
  - HTTP method validation (only allows valid HTTP verbs)
  - Case-insensitive method normalization
- JSON parsing error handling
  - Returns 400 Bad Request for invalid JSON with `content-type: application/json`
  - Prevents malformed JSON from reaching handlers
- Code complexity analysis tool (flog) with rake task
- Enhanced Server middleware support for keyword arguments

### Changed

- Registering a route no longer rebuilds the prepared-route table for every
  path already registered. That was quadratic: each of an application's N
  registrations re-prepared all N entries. One application registering 675
  routes made 173,165 `prepare_entry_routes` calls and built 404,329
  `EffectiveEndpoint` objects — 599 per route — which was 72% of its route
  loading, plus 16% of boot spent in GC collecting them.

  Registration now marks the table dirty and `RouteLoader.load!` builds it once
  via the new `Routes#prepare!`. Readers (`find`, `all`, `allowed_methods`)
  build it on demand too, so a caller that skips `prepare!` pays latency on one
  request rather than getting a wrong answer. In that same application route
  loading went from 5.56s to 0.91s and `EffectiveEndpoint` allocations from
  404,329 to 1,062.
- Response body validation is now opt-in, off by default in every environment
  (was `:error_response` outside production and `:log` in production)
  - Running the response schema over every body was the single most expensive
    thing Raxon did per request: ~58% of a small JSON response (20.5us to 8.6us)
  - Opt in globally with `config.response_validation = :error_response` (or
    `:raise` / `:log`), or per endpoint with `endpoint.validate_response true`,
    which works regardless of the global setting
  - `endpoint.validate_response false` still opts an endpoint out when the
    global setting is on
- Param resolution merges only the sources a request actually carries, and no
  longer allocates a closure per deferred source
  - The lenient merge allocated three intermediate hashes even when a request
    carried only a query string and a path parameter; empty sources are skipped
    and the common case allocates one
  - Headers and cookies are fetched from the request itself rather than through
    a per-request lambda each
  - `Request#params` 5.6us to 4.9us on a path-parameter request, 5 fewer objects
    per request wherever params are resolved
- Param resolution skips the form and JSON sources for a request that provably
  has no body
  - A GET reads both on every request that resolves params — `Rack::Request#POST`
    parses the input, and both sources consult the content type — to learn there
    is nothing there
  - Only requests declaring no content type, no `Transfer-Encoding`, and either
    no `Content-Length` or a length of zero are treated as empty; anything
    describing a body reads its sources as before
  - `Request#params` 6.3us to 5.6us on a path-parameter request, and 5 fewer
    objects per request wherever params are resolved
- Dynamic route lookup no longer costs more as an application declares more
  routes
  - Patterns were matched by asking each in turn, so every request paid for
    every dynamic route ever declared. A 100-resource API (800 routes) spent
    72us resolving `/api/v1/x/{id}` and 162us resolving
    `/api/v1/x/{id}/archive` — more than the rest of those requests together
  - Patterns are now indexed by their segments, and only the entries whose
    shape admits a path are asked. Lookup is flat: ~2.9us and ~3.2us at 800
    routes, and unchanged at 8
  - The index narrows; Mustermann still matches and extracts params, and
    candidates are still tried in registration order, so which pattern answers
    an ambiguous path is unchanged
- Two per-request costs removed from the path every response pays
  - `RAXON_DEBUG` is read once when the router is built, not on every
    `debug_log` call. It must now be set before the router is constructed,
    which is how it was already used: a server builds one router at boot
  - An endpoint declaring no security no longer allocates an empty array per
    request to ask whether its requirements are empty
  - Together: a plaintext response 7.5us to 6.9us, 3 fewer objects per request
    on every endpoint
- Header and cookie request sources are materialized only when a parameter
  declares `in: :header` or `in: :cookie`
  - `Request#headers` allocates a hash of every `HTTP_*` env key; endpoints
    declaring neither no longer pay for it
  - Cuts source collection from 4.4us to 2.8us on a request with declared params
- Request validation now enforces declared `enum`/`allowable_values` constraints
  - Generates a dry-schema `included_in?` predicate for scalar fields, rejecting values outside the enum
  - For array fields the enum constrains each element (matching the OpenAPI items schema)
  - Reads the enum lazily, so deferred (callable) enums are resolved at request time
  - Previously the enum was advertised in the OpenAPI document but never enforced, letting out-of-enum values reach handlers
- README expanded from 160 to 632 lines with production-ready documentation
- Improved error messages for validation failures
- Better security practices throughout codebase

### Removed

- `Raxon::RouteLoader.register(__FILE__)` route registration interface. Route
  files now use the `Raxon.route` shorthand, which infers the path from the
  route file location.

### Fixed

- `Endpoint#exception_error` now documents the body `Raxon::Response#error`
  actually produces (`{error: string}`); it previously declared an `errors`
  array that no response helper emits, which surfaced as false validation
  failures once symbol-status response validation was fixed (below)
- Response body validation now runs for responses declared with a symbol status
  - `Endpoint#response_schemas` keyed schemas by the declared status (a symbol for
    `exception_error` / `response :unprocessable_entity`), but the lookup used the
    integer `Response#status_code`, so the schema was never found and validation
    was silently skipped for every symbol-declared response
  - Keys are now normalized to integer status codes via `DSL.status_to_code`

### Security

- Prevent information disclosure in error responses
- Validate HTTP methods to prevent injection attacks
- Sanitize JSON parsing errors

## [0.1.0] - 2025-11-08

### Added

- File-based routing system
  - Automatic route registration from file paths
  - Convention: `routes/api/v1/users/get.rb` → `GET /api/v1/users`
  - Support for GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS
- Integrated OpenAPI DSL for documentation
  - Define API schemas alongside implementation
  - Automatic OpenAPI 3.0 specification generation
  - Swagger UI integration for interactive documentation
- Automatic request validation with dry-schema
  - Parameter type coercion and validation
  - Request body validation with nested objects
  - Automatic 400 Bad Request responses for invalid input
- Response validation
  - Schema-based response validation
  - Type checking and property validation
  - Automatic error responses for validation failures
- Clean DSL for endpoint definitions
  - `Raxon::RouteLoader.register(__FILE__)` for route registration
  - Intuitive parameter and response definitions
  - Handler blocks for request processing
- Rack 3 compatible server (`Api::Server`)
  - Middleware support
  - Development and production configurations
  - Hot reload support for development
- Request wrapper (`Api::Request`)
  - Comprehensive delegation to Rack::Request
  - JSON body parsing
  - Parameter validation integration
  - Access to query params, path params, and JSON body
- Response wrapper (`Api::Response`)
  - Status code symbols (`:ok`, `:created`, `:not_found`, etc.)
  - Automatic JSON serialization
  - Cookie and header management
  - Redirect support
- Development tools
  - `rake routes` - Display all registered routes
  - `rake openapi:generate` - Generate OpenAPI documentation
  - StandardRB integration for code style
  - RSpec test suite with 55 passing examples
- Component schema support
  - Reusable schema definitions
  - Reference components in responses
  - Auto-generation from Alba resources and ActiveRecord models
- Comprehensive test coverage
  - Unit tests for all core components
  - Integration tests for full request/response cycle
  - Validation tests
  - Error handling tests

### Dependencies

- rack ~> 3.0 - Web server interface
- dry-schema ~> 1.13 - Request/response validation
- dry-initializer ~> 3.0 - Clean object initialization
- alba ~> 2.0 - JSON serialization
- activerecord ~> 7.0 - Database integration (optional)
- tty-table ~> 0.12 - CLI table output
- puma ~> 6.0 - Default web server (development)
- rspec ~> 3.0 - Testing framework (development)
- standardrb ~> 1.0 - Code style (development)
- flog - Code complexity analysis (development)

### Documentation

- Comprehensive README with examples
- OpenAPI 3.0 specification generation
- Swagger UI documentation viewer
- Inline code documentation with YARD
- Development setup instructions
- Deployment guide with production checklist

---

## Version History Format

Each version should follow this structure:

### Added

New features and capabilities

### Changed

Changes to existing functionality

### Deprecated

Features that will be removed in upcoming releases

### Removed

Features that have been removed

### Fixed

Bug fixes

### Security

Security improvements and vulnerability fixes

---

## Template for Future Releases

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added

- New feature description
- Another new feature

### Changed

- Modified existing feature
- Updated dependency versions

### Deprecated

- Feature marked for removal

### Removed

- Removed deprecated feature

### Fixed

- Bug fix description
- Another bug fix

### Security

- Security improvement description
```

---

## Commit Link Format

When published to GitHub, version numbers should link to release comparisons:

```markdown
## [1.0.0] - 2025-MM-DD

...

[Unreleased]: https://github.com/username/api/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/username/api/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/username/api/releases/tag/v0.1.0
```

---

**Note:** This changelog follows [Keep a Changelog](https://keepachangelog.com/) conventions and [Semantic Versioning](https://semver.org/) for version numbers.
