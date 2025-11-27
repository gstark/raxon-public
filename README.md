# Raxon

A lightweight, Rack 3 compatible JSON API framework for Ruby with file-based routing, automatic OpenAPI documentation generation, and built-in request/response validation.

## Features

- ✨ **File-Based Routing** - Routes automatically mapped from file paths (`routes/api/v1/users/get.rb` → `GET /api/v1/users`)
- 📝 **Integrated OpenAPI DSL** - Define API documentation alongside implementation
- ✅ **Automatic Validation** - Request parameter and response validation using dry-schema
- 🛡️ **Security Hardening** - Built-in error handling, input sanitization, and JSON parsing protection
- 🚀 **Rack 3 Compatible** - Modern Rack interface with middleware support
- 🔧 **Developer Friendly** - Clean DSL, comprehensive error messages, and development tools
- 🎯 **Handler Helpers** - Reusable methods available in all endpoint handlers
- 🔗 **Before Hooks** - Hierarchical request lifecycle hooks for authentication and validation
- 🌐 **Multi-Format** - JSON APIs and HTML rendering with ERB templates
- ⚡ **Response Control** - Early termination with `halt`, custom headers, and status codes
- 🔄 **All-Method Routes** - `all.rb` files handle all HTTP methods for cross-cutting concerns

## Quick Start

### Installation

Add to your Gemfile:

```ruby
gem 'raxon'
```

Or install locally:

```bash
bundle install
```

### Basic Example

Create a route file at `routes/api/v1/ping/get.rb`:

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Health check endpoint"

  endpoint.response 200, type: :object do |response|
    response.property :success, type: :boolean, description: "Always true"
    response.property :timestamp, type: :string, description: "Current server time"
  end

  endpoint.handler do |request, response|
    response.code = :ok
    response.body = {
      success: true,
      timestamp: Time.now.iso8601
    }
  end
end
```

### Running the Server

```bash
# Development server (default port 9292)
bundle exec raxon server

# Custom port
bundle exec raxon server -p 3000
```

Test your endpoint:

```bash
curl http://localhost:9292/api/v1/ping
# Response: {"success":true,"timestamp":"2025-11-08T11:00:00Z"}
```

## Core Concepts

### File-Based Routing

Routes are automatically registered based on file paths and names:

| File Path                         | HTTP Method | Route                |
| --------------------------------- | ----------- | -------------------- |
| `routes/api/v1/users/get.rb`      | GET         | `/api/v1/users`      |
| `routes/api/v1/users/post.rb`     | POST        | `/api/v1/users`      |
| `routes/api/v1/users/{id}/get.rb` | GET         | `/api/v1/users/{id}` |
| `routes/api/v1/users/{id}/put.rb` | PUT         | `/api/v1/users/{id}` |
| `routes/api/v1/all.rb`            | ALL         | `/api/v1/*`          |

**Supported HTTP methods:** `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `all`

**Special method:** `all.rb` files match all HTTP methods and are ideal for cross-cutting concerns like authentication, logging, and headers.

### Request Handling

Access request data through the `request` object:

```ruby
endpoint.handler do |request, response|
  # Query parameters
  page = request.params[:page]

  # Path parameters (from routing)
  user_id = request.params[:id]

  # JSON body (automatically parsed)
  name = request.params[:name]

  # Request metadata
  ip_address = request.ip
  user_agent = request.user_agent

  response.code = :ok
  response.body = { user_id: user_id, name: name }
end
```

### Response Building

Build responses using the clean DSL:

```ruby
endpoint.handler do |request, response|
  # Set status code (symbol or integer)
  response.code = :created  # or response.code 201

  # Set body (automatically serialized to JSON)
  response.body = { id: 123, name: "John" }

  # Set custom headers
  response.header "X-Rate-Limit", "100"

  # Set cookies
  response.set_cookie "session_id", value: "abc123", httponly: true

  # Redirect
  response.redirect "/api/v1/users/123", 302
end
```

Available status code symbols: `:ok`, `:created`, `:accepted`, `:no_content`, `:bad_request`, `:unauthorized`, `:forbidden`, `:not_found`, `:unprocessable_entity`, `:internal_server_error`, and [many more](lib/raxon/response.rb#L22-L89).

### Early Response Termination

Use `response.halt` to immediately stop processing and return a response:

```ruby
endpoint.handler do |request, response|
  unless authorized?(request)
    response.code = :unauthorized
    response.body = { error: "Unauthorized" }
    response.halt  # Stop processing immediately
  end

  # This code won't execute if halt was called
  response.code = :ok
  response.body = { data: "sensitive information" }
end
```

### Handler Helpers

Define reusable helper methods that are available within all endpoint handlers:

```ruby
# Configure helpers directory
Raxon.configure do |config|
  config.routes_directory = "routes"
  config.helpers_path = "app/handlers/concerns"
end

# app/handlers/concerns/authentication_helpers.rb
module Raxon::HandlerHelpers
  def authenticate!(request)
    token = request.rack_request.get_header("HTTP_AUTHORIZATION")
    raise "Unauthorized" unless valid_token?(token)
  end

  def current_user(request)
    # Extract user from token
  end
end

# Use in any endpoint
endpoint.handler do |request, response|
  authenticate!(request)  # Helper method available directly
  user = current_user(request)

  response.code = :ok
  response.body = { user: user }
end
```

**Benefits:**

- Extract common logic (authentication, validation, formatting)
- Keep handlers clean and focused
- Share code across all endpoints
- Easy to test independently

### Before Hooks

Execute code before the main handler, useful for authentication, logging, and setup:

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  # Before hook runs first
  endpoint.before do |request, response|
    authenticate!(request)
    log_request(request)

    # Can halt early if needed
    unless user_has_permission?(request)
      response.code = :forbidden
      response.body = { error: "Forbidden" }
      response.halt
    end
  end

  # Handler only runs if before hook doesn't halt
  endpoint.handler do |request, response|
    response.code = :ok
    response.body = { data: "protected resource" }
  end
end
```

**Before hook features:**

- Multiple before hooks can be defined per endpoint
- Before hooks run in order of definition
- Can call `response.halt` to prevent handler execution
- Shared request and response objects throughout lifecycle
- Combine with handler helpers for maximum reusability

**Hierarchical before hooks:**

Before hooks can be defined at parent route levels and automatically apply to all child routes:

```ruby
# routes/api/v1/before.rb - Applies to all /api/v1/* routes
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.before do |request, response|
    authenticate!(request)  # All v1 endpoints require auth
  end
end

# routes/api/v1/users/get.rb - Inherits parent before hooks
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.before do |request, response|
    check_rate_limit!(request)  # Additional check for this endpoint
  end

  endpoint.handler do |request, response|
    # Both parent and local before hooks run first
    response.body = { users: fetch_users }
  end
end
```

### All-Method Routes (all.rb)

The `all.rb` file type allows you to define handlers that execute for **all HTTP methods** (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS). These files are perfect for cross-cutting concerns that apply regardless of the request method.

**Key characteristics:**

- Matches all HTTP methods at the specified path
- Executes before method-specific handlers in the hierarchy
- Processes from shallowest to deepest nesting
- Ideal for authentication, authorization, logging, and request preprocessing

#### Basic Usage

```ruby
# routes/api/v1/all.rb - Handles all methods for /api/v1/*
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Authentication for all API v1 endpoints"

  endpoint.handler do |request, response|
    # This runs for GET, POST, PUT, DELETE, etc.
    unless authenticated?(request)
      response.code = :unauthorized
      response.body = { error: "Authentication required" }
      response.halt
    end
  end
end
```

#### Execution Order

When both `all.rb` and method-specific files exist, they form a hierarchy:

```ruby
# routes/api/all.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.handler do |request, response|
    # 1. Runs first (shallowest level)
    response.header "X-API-Version", "1.0"
  end
end

# routes/api/v1/all.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.handler do |request, response|
    # 2. Runs second (deeper level)
    authenticate!(request)
  end
end

# routes/api/v1/users/post.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.handler do |request, response|
    # 3. Runs last (final endpoint)
    response.code = :created
    response.body = create_user(request.params)
  end
end
```

For a `POST /api/v1/users` request, the execution order is:

1. `/api/all.rb` handler (adds header)
2. `/api/v1/all.rb` handler (checks authentication)
3. `/api/v1/users/post.rb` handler (creates user)

#### Common Use Cases

**1. API Authentication**

```ruby
# routes/api/v1/all.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Require authentication for all v1 endpoints"

  endpoint.handler do |request, response|
    api_key = request.rack_request.get_header("HTTP_X_API_KEY")

    unless valid_api_key?(api_key)
      response.code = :unauthorized
      response.body = { error: "Invalid or missing API key" }
      response.halt
    end

    # Store authenticated user for later use
    request.env["current_user"] = User.find_by_api_key(api_key)
  end
end
```

**2. Request Logging**

```ruby
# routes/api/all.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Log all API requests"

  endpoint.handler do |request, response|
    logger.info(
      method: request.rack_request.request_method,
      path: request.rack_request.path,
      ip: request.ip,
      timestamp: Time.now.iso8601
    )
  end
end
```

**3. CORS Headers**

```ruby
# routes/api/all.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Set CORS headers for all API endpoints"

  endpoint.handler do |request, response|
    response.header "Access-Control-Allow-Origin", "*"
    response.header "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"
    response.header "Access-Control-Allow-Headers", "Content-Type, Authorization"

    # Handle OPTIONS preflight requests
    if request.rack_request.request_method == "OPTIONS"
      response.code = :no_content
      response.halt
    end
  end
end
```

**4. Rate Limiting**

```ruby
# routes/api/v1/all.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Rate limiting for all v1 endpoints"

  endpoint.handler do |request, response|
    client_ip = request.ip

    if rate_limit_exceeded?(client_ip)
      response.code = :too_many_requests
      response.header "Retry-After", "60"
      response.body = { error: "Rate limit exceeded. Try again in 60 seconds." }
      response.halt
    end

    increment_rate_limit(client_ip)
  end
end
```

**5. Request ID Tracking**

```ruby
# routes/api/all.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Add request ID to all responses"

  endpoint.handler do |request, response|
    request_id = SecureRandom.uuid
    response.header "X-Request-ID", request_id
    request.env["request_id"] = request_id
  end
end
```

#### Interaction with Method-Specific Files

When a directory contains both `all.rb` and a method-specific file (e.g., `post.rb`):

- **Same directory level**: Method-specific file becomes the final handler, `all.rb` executes as a before handler
- **Different levels**: Both execute in hierarchical order (parent to child)

```ruby
# Directory: routes/api/v1/users/
#   - all.rb
#   - post.rb

# For POST /api/v1/users:
# 1. all.rb handler executes (before block behavior)
# 2. post.rb handler executes (final endpoint)

# For DELETE /api/v1/users (no delete.rb exists):
# 1. all.rb handler executes (final endpoint)
```

#### Best Practices

✅ **Do:**

- Use `all.rb` for authentication and authorization
- Use `all.rb` for logging and monitoring
- Use `all.rb` for setting common headers
- Call `response.halt` when you need to stop processing
- Combine with handler helpers for cleaner code

❌ **Don't:**

- Mix business logic in `all.rb` files
- Create `all.rb` when you only need one or two methods
- Forget that `all.rb` runs for ALL methods (including OPTIONS)
- Use `all.rb` as a replacement for proper middleware

#### Testing all.rb Files

```ruby
RSpec.describe "API Authentication (all.rb)" do
  it "requires valid API key for all methods" do
    %w[GET POST PUT PATCH DELETE].each do |method|
      env = Rack::MockRequest.env_for("/api/v1/users", method: method)
      status, headers, body = server.call(env)

      expect(status).to eq(401)
      expect(JSON.parse(body.first)["error"]).to eq("Invalid or missing API key")
    end
  end

  it "allows requests with valid API key" do
    env = Rack::MockRequest.env_for(
      "/api/v1/users",
      method: "GET",
      "HTTP_X_API_KEY" => "valid-key"
    )
    status, headers, body = server.call(env)

    expect(status).to eq(200)
  end
end
```

### HTML Rendering

Raxon supports ERB-templated HTML responses alongside JSON:

```ruby
# routes/dashboard/get.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Dashboard page"

  endpoint.handler do |request, response|
    users = fetch_users
    response.render_html(users: users)
  end
end
```

Create a template file with the same path but `.html.erb` extension:

```erb
<!-- routes/dashboard/get.html.erb -->
<!DOCTYPE html>
<html>
<head>
  <title>Dashboard</title>
</head>
<body>
  <h1>Users</h1>
  <ul>
    <% users.each do |user| %>
      <li><%= user[:name] %> (<%= user[:email] %>)</li>
    <% end %>
  </ul>
</body>
</html>
```

**HTML rendering features:**

- Templates are pre-compiled at load time for performance
- Variables passed to `render_html` are available in templates
- Templates are located alongside route files with `.html.erb` extension
- Automatically sets `Content-Type: text/html`
- ERB syntax supports all standard Ruby code

**Mix JSON and HTML in the same application:**

```ruby
# JSON API endpoint
# routes/api/v1/users/get.rb
endpoint.handler do |request, response|
  response.code = :ok
  response.body = { users: fetch_users }
end

# HTML page
# routes/dashboard/get.rb
endpoint.handler do |request, response|
  response.render_html(users: fetch_users)
end
```

## Validation

### Request Parameter Validation

Define parameters with automatic validation and type coercion:

```ruby
endpoint.parameters do |params|
  params.define :email, type: :string, required: true
  params.define :age, type: :number, required: false
  params.define :role, type: :string, in: :query, required: false
end
```

Invalid requests automatically return 400 Bad Request with error details:

```json
{
  "error": "Validation failed",
  "details": {
    "email": ["is missing"],
    "age": ["must be a number"]
  }
}
```

### Request Body Validation

Define request body schemas with nested validation:

```ruby
endpoint.request_body type: :object, description: "User data", required: true do |body|
  body.property :name, type: :string, required: true
  body.property :email, type: :string, required: true
  body.property :profile, type: :object, required: false do |profile|
    profile.property :bio, type: :string
    profile.property :website, type: :string
  end
end
```

### Response Validation

Define response schemas for automatic validation and documentation:

```ruby
endpoint.response 200, type: :object do |response|
  response.property :id, type: :number
  response.property :name, type: :string
  response.property :created_at, type: :string
end

endpoint.response 404, type: :object do |response|
  response.property :error, type: :string
end
```

## OpenAPI Documentation

### Automatic Generation

Generate OpenAPI 3.0 specification from your route definitions:

```bash
bundle exec rake openapi:generate
```

This creates:

- `doc/apidoc/api.json` - OpenAPI specification
- `doc/apidoc/api.html` - Swagger UI documentation

### Component Schemas

Define reusable schemas:

```ruby
Raxon::OpenApi::DSL.component(:User, type: :object) do |c|
  c.property :id, type: :number
  c.property :name, type: :string
  c.property :email, type: :string
end

# Reference in responses
endpoint.response 200, type: :object, as: :User
endpoint.response 200, type: :array, of: :User  # Array of users
```

### Viewing Documentation

Open `doc/apidoc/api.html` in your browser to view interactive Swagger UI documentation with:

- All endpoints organized by path
- Request/response schemas
- Try-it-out functionality
- Example requests and responses

## Configuration

### Basic Setup

Configure your application and start the server:

```ruby
# config/app.rb
require "raxon"

Raxon.configure do |config|
  # Set the directory where your route files are located
  config.routes_directory = "routes"
  # Can also use environment variable: RAXON_ROUTES_DIR=routes

  # Optional: Set directory for handler helper files
  config.helpers_path = "app/handlers/concerns"

  # Optional: Configure global error handler callback
  config.on_error = ->(error, env) {
    # Send to error tracking service
    Sentry.capture_exception(error) if defined?(Sentry)

    # Custom logging
    logger.error("Request failed: #{error.message}")
    logger.error(error.backtrace.join("\n"))
  }
end
```

**Configuration options:**

- `root` - Root directory of the application as a Pathname (required, raises error if not set when accessed via `Raxon.root`)
- `routes_directory` - Directory containing route files (default: `"routes"`)
- `helpers_path` - Directory for handler helper modules (default: `nil`)
- `on_error` - Callback proc for error handling (receives error and Rack env)
- `openapi_title` - Title for OpenAPI documentation
- `openapi_description` - Description for OpenAPI documentation
- `openapi_version` - API version for OpenAPI documentation

**Accessing the root path:**

```ruby
Raxon.configure do |config|
  config.root = __dir__  # Set to current directory
end

# Access as Pathname
Raxon.root              # => #<Pathname:/path/to/app>
Raxon.root.join("lib")  # => #<Pathname:/path/to/app/lib>
```

Note: `Raxon.root` raises `Raxon::Error` if accessed before configuration.

### Global Request Lifecycle Blocks

Raxon supports global before, after, and around blocks that execute for every request. These are useful for cross-cutting concerns like logging, authentication, database connection management, and request timing.

```ruby
Raxon.configure do |config|
  config.routes_directory = "routes"

  # Global before block - runs before every request
  config.before do |request, response, metadata|
    metadata[:request_start] = Time.now
    metadata[:request_id] = SecureRandom.uuid
  end

  # Multiple before blocks can be registered
  config.before do |request, response, metadata|
    Rails.logger.info "Request #{metadata[:request_id]} started"
  end

  # Global after block - runs after every request
  config.after do |request, response, metadata|
    elapsed = Time.now - metadata[:request_start]
    response.header "X-Request-Id", metadata[:request_id]
    response.header "X-Response-Time", "#{(elapsed * 1000).round}ms"
  end

  # Global around block - wraps entire request lifecycle
  config.around do |request, response, metadata, &inner|
    ActiveRecord::Base.connection_pool.with_connection do
      inner.call
    end
  end
end
```

#### Before Blocks

Before blocks execute before any route-specific logic. They can halt processing early:

```ruby
config.before do |request, response, metadata|
  unless valid_api_key?(request)
    response.code = :unauthorized
    response.body = { error: "Invalid API key" }
    response.halt  # Stops further processing
  end
end
```

**Use cases:** Request logging, setting up request context, global authentication, rate limiting

#### After Blocks

After blocks execute after the handler and route-specific after blocks complete:

```ruby
config.after do |request, response, metadata|
  Rails.logger.info "Request completed: #{response.status}"
  response.header "X-Powered-By", "Raxon"
end
```

**Use cases:** Response logging, adding common headers, cleanup, metrics collection

#### Around Blocks

Around blocks wrap the entire request lifecycle. They must call the inner block to continue:

```ruby
# Database connection management
config.around do |request, response, metadata, &inner|
  ActiveRecord::Base.connection_pool.with_connection do
    inner.call
  end
end

# Error handling
config.around do |request, response, metadata, &inner|
  inner.call
rescue => e
  Rails.logger.error "Request failed: #{e.message}"
  response.code = :internal_server_error
  response.body = { error: "Internal server error" }
end

# Maintenance mode (skip processing entirely)
config.around do |request, response, metadata, &inner|
  if ENV["MAINTENANCE_MODE"] == "true"
    response.code = :service_unavailable
    response.body = { error: "System under maintenance" }
  else
    inner.call
  end
end
```

**Use cases:** Database connection management, transaction wrapping, error handling, request timing with cleanup guarantees

#### Execution Order

The complete execution order for a request:

1. **Global around blocks** (outermost to innermost)
2. **Global before blocks** (in registration order)
3. **Route hierarchy metadata blocks** (parent to child)
4. **Route hierarchy before blocks** (parent to child)
5. **Handler**
6. **Route hierarchy after blocks** (child to parent)
7. **Global after blocks** (in registration order)

Multiple around blocks nest with first registered being outermost:

```ruby
config.around do |request, response, metadata, &inner|
  puts "1. outer before"
  inner.call
  puts "4. outer after"
end

config.around do |request, response, metadata, &inner|
  puts "2. inner before"
  inner.call
  puts "3. inner after"
end
# Prints: 1, 2, handler, 3, 4
```

### Server Setup

Create a custom `config.ru`:

```ruby
require_relative "config/app"

server = Raxon::Server.new do |app|
  # Error handling (recommended for production)
  app.use Raxon::ErrorHandler, logger: Logger.new($stdout)

  # Logging
  app.use Rack::Logger
  app.use Rack::CommonLogger

  # CORS (if needed)
  # app.use Rack::Cors do
  #   allow do
  #     origins '*'
  #     resource '*', headers: :any, methods: [:get, :post, :put, :delete]
  #   end
  # end
end

run server
```

### Error Handling

The framework includes comprehensive error handling:

```ruby
# Basic usage
use Raxon::ErrorHandler

# With logging
use Raxon::ErrorHandler, logger: Logger.new($stdout)

# With error tracking service (Sentry, Bugsnag, etc.)
# Option 1: Via middleware
use Raxon::ErrorHandler,
  logger: Logger.new($stdout),
  on_error: ->(error, env) {
    Sentry.capture_exception(error)
  }

# Option 2: Via global configuration (applies to all error handlers)
Raxon.configure do |config|
  config.on_error = ->(error, env) {
    Sentry.capture_exception(error)
  }
end
use Raxon::ErrorHandler, logger: Logger.new($stdout)
```

**Error handler features:**

- Catches all unhandled exceptions
- Returns secure 500 JSON response: `{"error": "Internal Server Error"}`
- Never leaks exception details to clients
- Optionally logs full error details server-side
- Supports custom error notification callbacks

### Middleware Examples

Common middleware configurations:

```ruby
# config/app.rb
Raxon.configure do |config|
  config.routes_directory = "routes"
end

# config.ru
server = Raxon::Server.new do |app|
  # Request ID tracking
  app.use Rack::RequestId

  # Compression
  app.use Rack::Deflater

  # Rate limiting (using rack-attack or custom)
  # app.use Rack::Attack

  # Authentication
  # app.use AuthenticationMiddleware

  # Error handling (should be outermost)
  app.use Raxon::ErrorHandler, logger: Logger.new($stdout)
end
```

## Development

### Running Tests

```bash
# Run all tests
bundle exec rake spec
# or
bundle exec rspec

# Run specific test file
bundle exec rspec spec/raxon/server_spec.rb

# Run with documentation format
bundle exec rspec --format documentation
```

Current test coverage: **437 examples, 0 failures** with 93.57% line coverage

### Code Linting

Uses [Standard Ruby](https://github.com/standardrb/standard) for consistent code style:

```bash
# Check code style
bundle exec standardrb

# Auto-fix issues
bundle exec standardrb --fix

# Or use rake tasks
bundle exec rake standard
bundle exec rake standard:fix
```

### Viewing Routes

Display all registered routes using the CLI or rake task:

```bash
# Using CLI command (recommended)
bundle exec raxon routes

# Or using rake task
bundle exec rake routes

# Show routes from custom directory
ROUTES_DIR=routes bundle exec raxon routes
```

**Output format:**

```
GET    /api/v1/ping          Health check endpoint
POST   /api/v1/users         Create a new user
GET    /api/v1/users         List all users
GET    /api/v1/users/{id}    Get user by ID
PUT    /api/v1/users/{id}    Update user
DELETE /api/v1/users/{id}    Delete user
```

### Code Complexity Analysis

Analyze code complexity using flog:

```bash
bundle exec rake flog
```

### Default Development Task

Run tests and linting together:

```bash
bundle exec rake  # runs: spec + standard
```

## Deployment

### Production Checklist

- [ ] Enable error handler middleware with logging
- [ ] Configure error tracking service (Sentry, Bugsnag)
- [ ] Set up rate limiting
- [ ] Enable request compression (`Rack::Deflater`)
- [ ] Configure CORS if needed
- [ ] Set appropriate logging levels
- [ ] Use environment variables for sensitive configuration
- [ ] Set up health check endpoint (`/api/v1/ping`)
- [ ] Generate and deploy OpenAPI documentation

### Environment Variables

Recommended environment variables:

```bash
RACK_ENV=production           # Production environment
PORT=3000                     # Server port
LOG_LEVEL=info               # Logging level
SENTRY_DSN=https://...       # Error tracking
API_VERSION=v1               # API version
```

### Example Production Setup

```ruby
# config/app.rb (production)
require "raxon"

Raxon.configure do |config|
  config.routes_directory = ENV.fetch("RAXON_ROUTES_DIR", "routes")
end
```

```ruby
# config.ru (production)
require_relative "config/app"

logger = Logger.new($stdout)
logger.level = ENV.fetch("LOG_LEVEL", "info").upcase

server = Raxon::Server.new do |app|
  # Error handling with Sentry
  app.use Raxon::ErrorHandler,
    logger: logger,
    on_error: ->(error, env) {
      Sentry.capture_exception(error) if defined?(Sentry)
    }

  # Performance
  app.use Rack::Deflater

  # Security
  app.use Rack::Protection

  # Logging
  app.use Rack::CommonLogger, logger
end

run server
```

## Advanced Usage

### Fallback Applications

Raxon can act as a router in front of an existing Rack application, handling specific routes while falling back to the main app:

```ruby
# Serve API routes with Raxon, fall back to Rails for everything else
rails_app = Rails.application

Raxon.configure do |config|
  config.routes_directory = "api/routes"
end

router = Raxon::Router.new(fallback: rails_app)
server = Raxon::Server.new(fallback: rails_app)

run server
```

**Use cases:**

- Add API routes to an existing Rails/Sinatra app
- Incrementally migrate from another framework
- Serve static assets with a different handler
- Mix different Rack applications in one server

When a request doesn't match any Raxon route, it's forwarded to the fallback app. If no fallback is configured, unmatched routes return 404.

### Custom Middleware

Create custom middleware:

```ruby
class CustomMiddleware
  def initialize(app, **options)
    @app = app
    @options = options
  end

  def call(env)
    # Before request
    start_time = Time.now

    # Process request
    status, headers, body = @app.call(env)

    # After request
    duration = Time.now - start_time
    headers['X-Response-Time'] = "#{duration}ms"

    [status, headers, body]
  end
end

# Use it
Raxon.configure { |config| config.routes_directory = "routes" }

server = Raxon::Server.new do |app|
  app.use CustomMiddleware, option: "value"
end
```

### Testing Endpoints

```ruby
# spec/api/users_spec.rb
require "spec_helper"

RSpec.describe "GET /api/v1/users" do
  it "returns list of users" do
    routes_dir = File.join(__dir__, "..", "fixtures", "routes")
    Raxon.configure { |config| config.routes_directory = routes_dir }

    server = Raxon::Server.new

    env = Rack::MockRequest.env_for("/api/v1/users", method: "GET")
    status, headers, body = server.call(env)

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")

    parsed = JSON.parse(body.first)
    expect(parsed).to have_key("users")
  end
end
```

## Contributing

This is a personal project but feedback and suggestions are welcome via GitHub issues.

### Development Setup

```bash
git clone <repository>
cd raxon
bundle install
bundle exec rake  # Run tests and linter
```

### Running Examples

```bash
bundle exec raxon server
curl http://localhost:9292/api/v1/ping
```

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

Built with:

- [Rack 3](https://github.com/rack/rack) - Web server interface
- [dry-schema](https://dry-rb.org/gems/dry-schema) - Validation
- [dry-initializer](https://dry-rb.org/gems/dry-initializer) - Clean initialization
- [Alba](https://github.com/okuramasafumi/alba) - Serialization
- [StandardRB](https://github.com/standardrb/standard) - Code style

## Support

- 📚 [API Documentation](doc/apidoc/api.html)
- 🐛 [Issue Tracker](https://github.com/yourusername/api/issues)
- 💬 Questions? Open an issue or discussion

---

**Status:** Active Development | **Version:** 0.1.0 | **Ruby:** >= 3.4.7
