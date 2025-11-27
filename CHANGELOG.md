# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Comprehensive README documentation with deployment guide, performance benchmarks, and framework comparisons
- Global error handler middleware (`Api::ErrorHandler`) for production safety
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

- README expanded from 160 to 632 lines with production-ready documentation
- Improved error messages for validation failures
- Better security practices throughout codebase

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
