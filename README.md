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
- 📐 **Correct HTTP Semantics** - Automatic `405 Method Not Allowed` (with `Allow`), HEAD from GET, and OPTIONS responses
- 🗜️ **Conditional GET** - `response.etag` / `response.last_modified` helpers with automatic `304 Not Modified`
- 🔐 **Security Schemes** - Declare OpenAPI security schemes once; optionally enforce them at runtime
- 🧪 **Test Helpers** - `Raxon::Test` request helpers and an RSpec matcher that validates responses against your declared schemas
- 🔌 **ORM-Agnostic** - No persistence dependencies; OpenAPI schemas introspect through ActiveRecord, Sequel/ROM, or a custom adapter when available

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
Raxon.route do
  description "Health check endpoint"

  response 200, type: :object do
    property :success, type: :boolean, description: "Always true"
    property :timestamp, type: :string, description: "Current server time"
  end

  handler do |_request, response|
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

| File Path                              | HTTP Method | Route                |
| -------------------------------------- | ----------- | -------------------- |
| `routes/api/v1/users/get.rb`           | GET         | `/api/v1/users`      |
| `routes/api/v1/users/post.rb`          | POST        | `/api/v1/users`      |
| `routes/api/v1/users/__id__/get.rb`    | GET         | `/api/v1/users/{id}` |
| `routes/api/v1/users/__id__/put.rb`    | PUT         | `/api/v1/users/{id}` |
| `routes/api/v1/all.rb`                 | ALL         | `/api/v1/*`          |

**Supported HTTP methods:** `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `all`

**Special method:** `all.rb` files match all HTTP methods and are ideal for cross-cutting concerns like authentication, logging, and headers.

#### Path Parameters

Use double underscores (dunder syntax) to define dynamic path segments:

```
routes/api/v1/users/__id__/get.rb        → GET /api/v1/users/{id}
routes/api/v1/orgs/__org_id__/get.rb     → GET /api/v1/orgs/{org_id}
```

The `$param` syntax is also supported for backwards compatibility, but dunder style is recommended as it avoids shell expansion issues:

```
routes/api/v1/users/$id/get.rb           → GET /api/v1/users/{id}
```

Path parameters are automatically extracted and available in `request.path_params` and the merged `request.params` convenience hash:

```ruby
endpoint.handler do |request, response|
  user_id = request.path_params[:id]  # Extracted from URL path
  response.body = { user_id: user_id }
end
```

See [Path Parameters Documentation](docs/path_parameters.md) for more details.

### Request Handling

Access request data through the `request` object:

```ruby
endpoint.handler do |request, response|
  # Query string parameters only
  page = request.query_params[:page]

  # Path parameters from routing only
  user_id = request.path_params[:id]

  # JSON body object parameters only
  name = request.body_params[:name]

  # URL-encoded or multipart form body parameters only
  photo = request.form_params[:photo]

  # Merged convenience hash remains available and is validated/coerced
  # when endpoint parameter or request body schemas are configured.
  params = request.params

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
  # Convenience response helpers
  response.ok(success: true)
  response.created(user)
  response.no_content
  response.not_found(error: "User not found")
  response.error("Unauthorized", status: :unauthorized)

  # Set status code (symbol or integer)
  response.code = :created  # or response.code = 201

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
require "rack/utils"

module Raxon::HandlerHelpers
  def authenticate!(request)
    token = request.rack_request.get_header("HTTP_AUTHORIZATION")
    raise "Unauthorized" unless valid_token?(token)
  end

  def valid_token?(token)
    return false if token.nil? || token.empty?

    # Compare in constant time. A plain `token == ENV["API_TOKEN"]` leaks the
    # secret one byte at a time through timing; always use secure_compare for
    # tokens, API keys, signatures, and password hashes.
    Rack::Utils.secure_compare(token, ENV.fetch("API_TOKEN"))
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
Raxon.route do |endpoint|
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
Raxon.route do |endpoint|
  endpoint.before do |request, response|
    authenticate!(request)  # All v1 endpoints require auth
  end
end

# routes/api/v1/users/get.rb - Inherits parent before hooks
Raxon.route do |endpoint|
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
Raxon.route do |endpoint|
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
Raxon.route do |endpoint|
  endpoint.handler do |request, response|
    # 1. Runs first (shallowest level)
    response.header "X-API-Version", "1.0"
  end
end

# routes/api/v1/all.rb
Raxon.route do |endpoint|
  endpoint.handler do |request, response|
    # 2. Runs second (deeper level)
    authenticate!(request)
  end
end

# routes/api/v1/users/post.rb
Raxon.route do |endpoint|
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
Raxon.route do |endpoint|
  endpoint.description "Require authentication for all v1 endpoints"

  endpoint.handler do |request, response|
    api_key = request.rack_request.get_header("HTTP_X_API_KEY")

    # Look the key up by a hashed/indexed column and compare in constant time
    # (see valid_token? above). Never interpolate the key into SQL or compare
    # secrets with ==.
    unless valid_api_key?(api_key)
      response.code = :unauthorized
      response.body = { error: "Invalid or missing API key" }
      response.halt
    end

    # Store authenticated user for later use
    request.context.current_user = authenticate_api_key(api_key)
  end
end
```

**2. Request Logging**

```ruby
# routes/api/all.rb
Raxon.route do |endpoint|
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
#
# SECURITY: Do NOT use `Access-Control-Allow-Origin: *` for an API that requires
# authentication — it lets any website on the internet make credentialed calls on
# your users' behalf. Echo back only origins you explicitly allow.
ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"].freeze

Raxon.route do |endpoint|
  endpoint.description "Set CORS headers for allowed origins"

  endpoint.handler do |request, response|
    origin = request.rack_request.get_header("HTTP_ORIGIN")

    if ALLOWED_ORIGINS.include?(origin)
      response.header "Access-Control-Allow-Origin", origin
      response.header "Vary", "Origin"
      response.header "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"
      response.header "Access-Control-Allow-Headers", "Content-Type, Authorization"
    end

    # Handle OPTIONS preflight requests
    if request.rack_request.request_method == "OPTIONS"
      response.code = :no_content
      response.halt
    end
  end
end
```

For anything beyond the basics, prefer the maintained [`rack-cors`](https://github.com/cyu/rack-cors) middleware over hand-rolled headers.

**4. Rate Limiting**

```ruby
# routes/api/v1/all.rb
Raxon.route do |endpoint|
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
Raxon.route do |endpoint|
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
Raxon.route do
  description "Dashboard page"

  handler do |_request, response|
    users = fetch_users
    response.html_body = response.html(users: users)
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
- Locals passed to `response.html(...)` are available in templates
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
endpoint.handler do |_request, response|
  response.html_body = response.html(users: fetch_users)
end
```

## HTTP Semantics

Raxon answers protocol-level requests correctly without any per-route code:

- **405 Method Not Allowed** — when a path exists but the requested method has no route, the router responds `405` with an `Allow` header listing the methods that would succeed (instead of a misleading 404). A configured catchall route or fallback app still takes precedence.
- **Automatic HEAD** — a `HEAD` request to a path with only a `get.rb` runs the GET handler and strips the body, per RFC 9110. An explicit `head.rb` or `all.rb` always wins.
- **Automatic OPTIONS** — an `OPTIONS` request to a known path with no `options.rb`/`all.rb` gets a `204` with the `Allow` header. Define your own `options.rb` (e.g. for CORS preflight) to take over.

### Custom 404 Responses

Override the default `{"error":"Not Found"}` body without defining a catchall route:

```ruby
Raxon.configure do |config|
  config.not_found do |request, response|
    response.body = {error: "No such endpoint", path: request.rack_request.path}
  end
end
```

The block receives the unmatched `Raxon::Request` and a `Raxon::Response` preloaded with the default 404; change the body, headers, or status as needed.

### Conditional GET (ETag / Last-Modified)

Handlers can make responses cacheable and skip work when the client is already up to date. Both helpers set the header and — for GET/HEAD requests — halt with `304 Not Modified` when the request's `If-None-Match` / `If-Modified-Since` indicates freshness:

```ruby
endpoint.handler do |request, response|
  user = find_user(request.params[:id])

  response.etag user.cache_key          # weak ETag (W/"...") by default
  response.last_modified user.updated_at

  # Only reached when the client's copy is stale
  response.ok user.as_json
end
```

Use `response.etag value, weak: false` for byte-identical (strong) validators. On non-GET/HEAD requests only the headers are set; no 304 is issued.

## Validation

### Request Parameter Validation

Define parameters with automatic validation and type coercion:

```ruby
endpoint.path_param :id, type: :string, description: "User ID"
endpoint.query_param :email, type: :string, required: true
endpoint.query_param :age, type: :number
endpoint.query_param :role, type: :string
endpoint.header_param :authorization, type: :string, required: true
endpoint.cookie_param :session_id, type: :string
```

The existing explicit parameter interface remains supported. Parameter defaults are location-aware: `in: :path` is required by default, while `in: :query`, `in: :header`, and `in: :cookie` are optional by default. Explicit `required:` values always take precedence.

```ruby
endpoint.parameters do |params|
  params.define :id, type: :string, in: :path          # required by default
  params.define :email, type: :string, required: true  # query param, explicitly required
  params.define :age, type: :number                    # optional query param by default
  params.define :authorization, type: :string, in: :header # optional by default
end
```

Compatibility note: older versions defaulted every `params.define` parameter to required. Add `required: true` to query/header/cookie definitions that must remain required.

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
endpoint.body type: :object, description: "User data", required: true do |body|
  body.property :name, type: :string, required: true, min_length: 2, max_length: 100
  body.property :email, type: :string, required: true, format: :email, pattern: "^[^@]+@[^@]+$", example: "user@example.com"
  body.property :age, type: :integer, required: false, minimum: 0, maximum: 130
  body.property :created_at, type: :datetime, required: false  # OpenAPI: string/date-time
  body.property :birthday, type: :date, required: false       # OpenAPI: string/date
  body.property :account_id, type: :uuid, required: false     # OpenAPI: string/uuid
  body.property :tags, type: :array, of: :string, required: false, min_items: 1, max_items: 10, unique_items: true
  body.property :profile, type: :object, required: false do |profile|
    profile.property :bio, type: :string
    profile.property :website, type: :string
  end
end
```

### File Uploads

Handle file uploads by declaring properties with `type: :file`. Raxon automatically wraps Rack multipart hashes into `Raxon::UploadedFile` objects:

```ruby
endpoint.body type: :multipart do |body|
  body.property :photo, type: :file, required: true
  body.property :caption, type: :string, required: false
end

endpoint.handler do |request, response, metadata|
  photo = request.params[:photo]

  # photo is a Raxon::UploadedFile — no conversion needed
  photo.original_filename  # => "photo.jpg"
  photo.content_type       # => "image/jpeg"
  photo.tempfile.path      # => "/tmp/RackMultipart..."
  photo.read               # => file contents
end
```

`Raxon::UploadedFile` duck-types `ActionDispatch::Http::UploadedFile`, so downstream code (ActiveStorage, image processing libraries) works without changes.

See [File Uploads Documentation](docs/file_uploads.md) for more details.

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

Standard error response helpers are available for common API responses:

```ruby
endpoint.validation_error_response
endpoint.unauthorized_response
endpoint.not_found_response
endpoint.error_response 500
```

These generate object response schemas with a required `error` string and, where appropriate, optional `details` object.

Response validation failures are configurable:

```ruby
Raxon.configure do |config|
  config.response_validation = :error_response # default outside production
  config.response_validation = :log            # default in production
  config.response_validation = :raise
  config.response_validation = false
  config.expose_validation_details = false     # default in production
end

# Per endpoint override
endpoint.validate_response false
endpoint.validate_response true
```

## OpenAPI Documentation

### Automatic Generation

Generate the OpenAPI specification from your route definitions:

```bash
bundle exec rake openapi:generate
```

This creates:

- `doc/apidoc/api.json` - OpenAPI specification
- `doc/apidoc/api.html` - Swagger UI documentation

The document is OpenAPI **3.1** by default (nullable fields are emitted as `type: ["string", "null"]` arrays per JSON Schema). Set `config.openapi_spec_version = "3.0"` to emit OpenAPI 3.0.0 with the legacy `nullable: true` keyword instead.

The generated document describes the real API surface:

- Route-file endpoints and DSL-declared endpoints (e.g. documentation for routes served elsewhere) are emitted together into one document.
- Middleware-only route files — an `all.rb` that registers only `before`/`metadata` blocks and has no handler — are excluded, as is the programmatic catchall.
- When a route file and a DSL-declared endpoint document the same path and method, the route wins: it is the enforced implementation.
- A response declared without a `description:` gets the standard HTTP reason phrase for its status code ("OK", "Not Found", …), since OpenAPI requires the field.

### Operation Metadata

Add common OpenAPI operation metadata alongside your route definition:

```ruby
endpoint.summary "List users"
endpoint.description "Fetches users visible to the current API key"
endpoint.operation_id "listUsers"
endpoint.tags "Users", "Admin"
endpoint.deprecated false
endpoint.security :api_key
endpoint.security :oauth2, scopes: ["users:read"]
```

The concise `Raxon.route` DSL supports the same methods without the `endpoint.` prefix.

### Security Schemes

Declare reusable security schemes once; they are emitted under `components.securitySchemes` and referenced by `endpoint.security`:

```ruby
# config/app.rb (or anywhere loaded at boot)
Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header)
Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer, bearer_format: "JWT")

# In a route file
endpoint.security :api_key
```

Supported types: `:apiKey`, `:http`, `:oauth2` (pass `flows:`), and `:openIdConnect` (pass `open_id_connect_url:`).

**Runtime enforcement.** Give a scheme an authenticator block and every endpoint that declares it is enforced automatically — the block runs after metadata blocks and before `before` blocks, and a falsy return produces `401 {"error":"Unauthorized"}` without running the handler:

```ruby
Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) do |request, metadata, scopes|
  key = request.header("HTTP_X_API_KEY").to_s
  user = User.find_by_api_key(key)
  metadata[:current_user] = user if user
  user # truthy grants access
end
```

Standard OpenAPI semantics apply: `endpoint.security [{api_key: []}, {bearer: []}]` grants access when **any** requirement passes, and all schemes within one requirement must pass. Schemes without an authenticator block are documentation-only, so existing `endpoint.security` declarations keep working unchanged.

### Specification Isolation

The global `Raxon::OpenApi::DSL` remains available for compatibility and delegates to a default specification object. For tests, engines, or multiple APIs in one process, create isolated specifications:

```ruby
spec = Raxon::OpenApi::Specification.new
spec.component(:User, type: :object)
spec.endpoint do |endpoint|
  endpoint.path "/users"
  endpoint.operation :get
end
spec.to_open_api
```

Reset the compatible global DSL state when needed:

```ruby
Raxon::OpenApi::DSL.reset!
```

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

### Specification Extensions

Attach [OpenAPI specification extensions](https://spec.openapis.org/oas/v3.1.0#specification-extensions) (`x-…` keys) to any schema — components, properties, parameters, responses, and request bodies all accept an `extensions:` option. Keys must start with `x-`; anything else raises at definition time. A common use is steering client-code generators, e.g. `swagger-typescript-api`'s `x-ts-type`:

```ruby
c.property :published_at, type: :datetime, nullable: true,
  extensions: {"x-ts-type" => "Dayjs"}
```

To apply an extension to **every** schema of a given DSL type — including properties generated by `from_resource`/`from_table`, where there is no call site to pass `extensions:` — configure it once by type name. Explicit `extensions:` win on key conflicts:

```ruby
Raxon.configure do |config|
  config.openapi_type_extensions = {
    datetime: {"x-ts-type" => "Dayjs"},
    date: {"x-ts-type" => "Dayjs"}
  }
end
```

Type-level extensions also apply to array items (`type: :array, of: :datetime`) and union members. Extensions are never emitted next to a `$ref` (siblings of `$ref` are ignored in OpenAPI 3.0).

### Viewing Documentation

Open `doc/apidoc/api.html` in your browser to view interactive Swagger UI documentation with:

- All endpoints organized by path
- Request/response schemas
- Try-it-out functionality
- Example requests and responses

## Database Integration

Raxon has **no runtime dependency on any ORM** — not ActiveRecord, not Sequel, not ROM. Database-backed features activate based on what your application has loaded and degrade to no-ops otherwise:

- **Schema introspection** (`from_resource` / `from_table` below) resolves an adapter per call: `config.schema_adapter` if you set one, otherwise ActiveRecord when it's loaded, otherwise Sequel when it's loaded (which covers ROM, since rom-sql connects through Sequel). With no adapter — or no reachable database, as in `rake openapi:generate` on CI — components emit only their block-declared properties.
- **Instrumentation** uses `ActiveSupport::Notifications` when present and yields straight through when it isn't.

### Generating Components from the Database

Instead of hand-writing component schemas, derive them from what the database already knows. With a model class (e.g. ActiveRecord), use `from_resource` with an [Alba](https://github.com/okuramasafumi/alba) resource:

```ruby
Raxon::OpenApi::DSL.from_resource(:User, UserResource, User) do |component|
  component.property :custom_field, type: :string  # block properties win over introspection
end
```

Each resource attribute becomes a property typed from its database column (nullability from the column, description from the column comment, enums from ActiveRecord inclusion validators; Alba associations become arrays referencing the associated component).

For tables with no model class — a ROM relation's table, for example — use `from_table` with the table name:

```ruby
Raxon::OpenApi::DSL.from_table(:ReleaseNote, ReleaseNoteResource, :release_notes) do |component|
  component.property :status, type: :string, allowable_values: %w[draft published]
end
```

Without a model class there are no validators to introspect, so declare enum-like properties in the block as shown.

### Using Raxon with ROM

rom-sql rides a Sequel connection, so once your ROM container is set up, Raxon's Sequel adapter is detected automatically — no Raxon configuration needed.

```ruby
# Gemfile
gem "raxon"
gem "rom"
gem "rom-sql"
```

```ruby
# config/app.rb — set up ROM as usual
require "rom"

rom_config = ROM::Configuration.new(:sql, ENV.fetch("DATABASE_URL"))

class ReleaseNotes < ROM::Relation[:sql]
  schema(:release_notes, infer: true)
end

rom_config.register_relation(ReleaseNotes)
ROM_CONTAINER = ROM.container(rom_config)
```

Define an Alba resource for serialization, generate the component from the table, and query ROM in handlers:

```ruby
# app/resources/release_note_resource.rb
class ReleaseNoteResource
  include Alba::Resource

  attributes :id, :title, :body, :created_at
end

Raxon::OpenApi::DSL.from_table(:ReleaseNote, ReleaseNoteResource, :release_notes)
```

```ruby
# routes/api/v1/release_notes/get.rb
Raxon.route do
  description "List release notes"

  response 200, type: :array, of: :ReleaseNote

  handler do |_request, response, _metadata|
    notes = ROM_CONTAINER.relations[:release_notes].with(auto_struct: true).to_a
    response.ok ReleaseNoteResource.new(notes).serializable_hash
  end
end
```

Two things Sequel's schema parsing cannot provide, compared to ActiveRecord introspection:

- **Column comments** are not exposed, so property descriptions default to `""` — declare `description:` in the component block where it matters.
- **Enums** cannot be derived (no model validators) — declare `allowable_values:` in the block.

If your app runs ROM *alongside* ActiveRecord (e.g. via `sequel-activerecord_connection`), the ActiveRecord adapter is detected first and introspects the same tables through the shared connection — `from_table` works identically, and column comments come back.

### Custom Schema Adapters

Any object implementing three methods can replace detection — return `nil` from any of them to mean "nothing introspectable":

```ruby
class StaticSchemaAdapter
  Column = Raxon::OpenApi::SchemaIntrospection::Column

  # => Hash of column name (String) to Column, or nil
  def table_columns(table_name)
    {
      "id" => Column.new(name: "id", sql_type: "bigint", comment: nil, null: false, array: false),
      "title" => Column.new(name: "title", sql_type: "text", comment: "Display title", null: true, array: false)
    }
  end

  # Same shape, for from_resource model classes
  def model_columns(model) = nil

  # => Array of allowed values for the attribute, or nil
  def enum_values(model, attribute_name) = nil
end

Raxon.configure do |config|
  config.schema_adapter = StaticSchemaAdapter.new
end
```

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
- `routes_directory` / `routes_directories` - Directory or array of directories containing route files (default: `"routes"`). Multiple directories are unioned together, and duplicate method/path endpoints raise `Raxon::Error`.
- `helpers_path` - Directory for handler helper modules (default: `nil`)
- `on_error` - Callback proc for error handling (receives error and Rack env)
- `openapi_title` - Title for OpenAPI documentation
- `openapi_description` - Description for OpenAPI documentation
- `openapi_version` - API version for OpenAPI documentation (the `info.version` field)
- `openapi_spec_version` - OpenAPI document version to emit: `"3.1"` (default) or `"3.0"`
- `openapi_type_extensions` - Hash mapping DSL type names to specification-extension hashes applied to every schema of that type, e.g. `{datetime: {"x-ts-type" => "Dayjs"}}` (default: `{}`). See [Specification Extensions](#specification-extensions).
- `logger` - Application logger (default: `nil`). When set, `Raxon::Server` logs every request through `Rack::CommonLogger` and `Raxon::ErrorHandler` (when used) logs unhandled exceptions to it.
- `not_found` - Block customizing the 404 response for unmatched requests (see [HTTP Semantics](#http-semantics))
- `reload_routes` - Route hot reloading: `nil` (default) enables it in development only; `true`/`false` force it on or off (see [Hot Reloading](#hot-reloading))
- `filter_parameters` - Array of name fragments (strings/symbols) or `Regexp`s whose values are redacted from instrumentation/APM payloads. Defaults to common secret names (`password`, `token`, `secret`, `api_key`, `authorization`, `cookie`, `access_token`, `refresh_token`, …). Add your app's sensitive field names here.
- `trust_proxy_headers` - Whether `request.remote_ip` may honor the client-supplied `X-Forwarded-For` / `X-Real-IP` headers (default: `false`). Leave `false` unless Raxon runs behind a reverse proxy you control that overwrites these headers — otherwise any client can spoof its IP. See [Security](#security).
- `max_request_body_size` - Reject requests whose `Content-Length` exceeds this many bytes with `413 Payload Too Large`, before the body is read into memory (default: `nil`, no limit). This is a cheap first guard; for untrusted traffic also cap body size at your proxy/load balancer.
- `schema_adapter` - Schema introspection source for `from_resource`/`from_table` (default: `nil`, auto-detects ActiveRecord then Sequel). Set to a custom adapter object to introspect another source (see [Database Integration](#database-integration)).

### Security

Raxon is an unopinionated micro-framework: it gives you the primitives but does not silently add protections, so a few things are your responsibility. The defaults are chosen to fail safe.

- **Client IP** — `request.remote_ip` returns the non-forgeable connection peer by default. Only set `trust_proxy_headers = true` when a trusted proxy overwrites the forwarding headers; otherwise `X-Forwarded-For` is attacker-controlled and must not be used for rate limiting, allowlists, or audit logs.
- **Secrets in telemetry** — the Rails-compatible instrumentation payload is scrubbed via `filter_parameters` before it reaches APM tools. Extend the list with any sensitive fields specific to your API.
- **Request size** — set `max_request_body_size` (and a proxy-level limit) to bound memory use from large bodies.
- **HTML output** — `response.html`/`.html_body` render templates with Erubi and **escape `<%= %>` by default**; use `<%== %>` only for values you have already sanitized.
- **Auth** — compare tokens/API keys with `Rack::Utils.secure_compare` (constant time), never `==`. See the Authentication example under Common Patterns.
- **CORS** — never send `Access-Control-Allow-Origin: *` on an authenticated API; echo back only allowlisted origins (or use `rack-cors`).
- **Transport & headers** — terminate TLS and add security headers (HSTS, `X-Content-Type-Options`, CSP for HTML endpoints) at your proxy or via Rack middleware; Raxon does not set them for you.

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

Raxon supports global before, after, and around blocks that execute for every request. These are useful for cross-cutting concerns like logging, authentication, database connection management, and request timing. Prefer `request.context` for request-scoped application state shared across lifecycle blocks; the `metadata` argument remains available for compatibility.

```ruby
Raxon.configure do |config|
  config.routes_directory = "routes"

  # Global before block - runs before every request
  config.before do |request, response, metadata|
    request.context[:request_start] = Time.now
    request.context[:request_id] = SecureRandom.uuid
  end

  # Multiple before blocks can be registered
  config.before do |request, response, metadata|
    Rails.logger.info "Request #{request.context.request_id} started"
  end

  # Global after block - runs after every request
  config.after do |request, response, metadata|
    elapsed = Time.now - request.context[:request_start]
    response.header "X-Request-Id", request.context[:request_id]
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

See the canonical [Request Lifecycle guide](docs/lifecycle.md) for the complete execution order, route hierarchy behavior, `all.rb`, halt behavior, and catchall routes.

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

  # CORS (if needed) — list only the origins you trust, never '*' on an
  # authenticated API.
  # app.use Rack::Cors do
  #   allow do
  #     origins 'https://app.example.com'
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

### Hot Reloading

In the development environment, route files reload automatically — edit a route, its `.html.erb` template, or a helper under `helpers_path`, and the next request serves the new code. No server restart needed.

Raxon watches the configured routes directories (and `helpers_path`) and performs a full route reload when any watched file is added, changed, or removed. Programmatic boot state survives: the catchall endpoint, OpenAPI components, security schemes, and configuration blocks are all preserved, and the generated OpenAPI document does not accumulate duplicates. A syntax error in a changed file surfaces on the request that triggered the reload; fix the file and the next request recovers.

Reloading is on only when `Raxon.env` is `development`. Override in either direction:

```ruby
Raxon.configure do |config|
  config.reload_routes = false  # opt out in development
  config.reload_routes = true   # force on elsewhere (not recommended in production)
end
```

Because a reload re-evaluates every route file, keep route files self-contained (which the isolated per-file execution context already encourages).

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

### Generating Routes

Scaffold route files with the CLI (also available as `raxon g`):

```bash
# GET route (default method)
bundle exec raxon generate route api/v1/users

# Multiple methods at once
bundle exec raxon generate route api/v1/users get post

# Path parameters ({id}, :id, and $id are normalized to dunder style)
bundle exec raxon generate route api/v1/users/__id__ get
```

Each generated file contains a `Raxon.route` block with a description stub, `path_param` declarations for any parameter segments, a 200 response schema stub, and a handler. Existing files are never overwritten.

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

Raxon ships test helpers (not loaded by `require "raxon"`). RSpec users get request helpers plus a matcher that validates response bodies against the schemas declared in your route files:

```ruby
# spec/spec_helper.rb
require "raxon/test/rspec"

RSpec.configure do |config|
  config.include Raxon::Test::Methods

  config.before(:each) do
    Raxon.configure { |c| c.routes_directory = "routes" }
    Raxon::RouteLoader.reset!
    Raxon::RouteLoader.load!
  end
end
```

```ruby
# spec/api/users_spec.rb
RSpec.describe "users API" do
  it "lists users" do
    get "/api/v1/users", params: {page: 2}, headers: {"X-API-Key" => "secret"}

    expect(last_response.status).to eq(200)
    expect(last_response.json).to eq({"users" => [], "page" => 2})
    expect(last_response).to conform_to_response_schema(200)
  end

  it "creates a user" do
    post "/api/v1/users", json: {name: "Alice"}

    expect(last_response).to conform_to_response_schema(201)
  end
end
```

- `get`/`post`/`put`/`patch`/`delete`/`head`/`options` accept `params:` (query or form), `json:` (JSON body + content type), `body:` (raw body), and `headers:` (friendly `"X-API-Key"` names or raw `"HTTP_X_API_KEY"` keys).
- `last_response` exposes `status`, `headers`, `body`, `json(symbolize_names: false)`, and case-insensitive header lookup via `last_response["Content-Type"]`.
- `conform_to_response_schema(status = nil)` fails with a precise message when the status differs, no route matches, the endpoint declares no schema for that status, or the body violates the declared schema.
- The app under test defaults to `Raxon::Server.new`; define your own `app` method to customize.

Non-RSpec frameworks can `require "raxon/test"` for the helpers without the matcher, or drive the server directly with `Rack::MockRequest.env_for` + `server.call(env)`.

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
