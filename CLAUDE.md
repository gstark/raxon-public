# CLAUDE.md - Project-Specific Guidance

This file provides guidance for working with this API codebase.

## openapi-dsl Library

This project uses a custom openapi-dsl library located in [lib/openapi-dsl/](lib/openapi-dsl/) for defining OpenAPI 3.0 metadata. **Always use this library when defining endpoint metadata. If functionality is missing, extend the library rather than working around it.**

### Core Philosophy

- **Reuse over reinvention**: Use existing openapi-dsl classes and methods
- **Extend when needed**: If a feature is missing, add it to openapi-dsl
- **Follow existing patterns**: Match the style and structure of existing endpoint definitions

### Library Structure

The library is located at `lib/openapi-dsl/` and consists of:

**Core Files:**

- `lib/openapi-dsl/lib/openapi-dsl.rb` - Main module loader (v0.1.0)
- `lib/openapi-dsl/lib/openapi-dsl/open_api.rb` - Core DSL implementation (all main classes)
- `lib/openapi-dsl/lib/openapi-dsl/error.rb` - Error class
- `lib/openapi-dsl/lib/openapi-dsl/version.rb` - Version definition
- `lib/openapi-dsl/lib/openapi-dsl/tasks/generate.rake` - Rake task for generating OpenAPI docs

**Main Classes:**

- `OpenApi` - Module with entry points and utilities
- `OpenApi::Component` - Reusable schema components
- `OpenApi::Endpoint` - API endpoint definitions
- `OpenApi::Response` - Response definitions by status code
- `OpenApi::Parameters` - Container for parameters
- `OpenApi::Parameter` - Individual parameter definitions
- `OpenApi::Property` - Property/field definitions (supports nesting)

### Available Metadata Capabilities

#### Endpoint-level Metadata

```ruby
OpenApi.endpoint do |endpoint|
  endpoint.path "/users/{id}"
  endpoint.operation [:get, :put]  # Single or array of HTTP verbs
  endpoint.description "Manage users"
  endpoint.parameters { |params| params.define :id, type: :string, in: :path }
  endpoint.response 200, type: :object, as: :User
end
```

**Supported attributes:**

- `path` - URL path with parameter placeholders
- `operation` - HTTP verbs (:get, :post, :put, :delete, :patch, etc.)
- `description` - Endpoint documentation
- `parameters` - Parameter definitions
- `response` - Multiple responses by status code

#### Parameter-level Metadata

```ruby
endpoint.parameters do |params|
  params.define :id, type: :string, in: :path, description: "Resource ID", required: true
  params.define :filter, type: :string, in: :query, required: false
end
```

**Supported attributes:**

- `name` - Parameter name
- `type` - :string, :number, :boolean, :object, :array
- `in` - :path, :query, :header, :cookie (default: :query)
- `required` - Boolean (default: true)
- `description` - Parameter documentation

#### Response-level Metadata

```ruby
endpoint.response 200, type: :object, as: :User, description: "User details" do |response|
  response.property :error, type: :string  # Custom inline properties
end

endpoint.response 404, type: :object do |response|
  response.property :error, type: :string, description: "Error message"
end
```

**Supported attributes:**

- Status code (200, 404, 500, etc.)
- `type` - Response type (:object, :array, etc.)
- `as` - Reference to a component schema
- `of` - For array types, the element type
- `description` - Response documentation
- `nullable` - Whether response can be null
- Inline `property` definitions

#### Property-level Metadata

```ruby
response.property :name, type: :string, description: "User name", required: true
response.property :tags, type: :array, of: :string
response.property :status, type: :string, enum: ["active", "inactive"]
response.property :metadata, type: :object, nullable: true do |meta|
  meta.property :created_at, type: :string
  meta.property :updated_at, type: :string
end
```

**Supported attributes:**

- `type` - :string, :number, :boolean, :object, :array, or array of types for anyOf
- `of` - For array types, element type
- `description` - Property documentation
- `required` - Boolean (default: true)
- `as` - Reference to component schema
- `enum` or `allowable_values` - Array of allowed values
- `nullable` - Whether property can be null
- Nested `property` definitions (for objects)

#### Component Schema Definitions

```ruby
Raxon::OpenApi::DSL.component(:User, type: :object, description: "A user in the system") do |c|
  c.property :id, type: :number, description: "User ID"
  c.property :name, type: :string, description: "Full name"
  c.property :email, type: :string, description: "Email address"
  c.property :roles, type: :array, of: :string
end
```

**Then reference in responses:**

```ruby
endpoint.response 200, type: :object, as: :User
endpoint.response 200, type: :array, of: :User  # Array of users
```

#### Auto-Generation from Resources

```ruby
OpenApi.from_resource(:User, UserResource, User) do |component|
  component.property :custom_field, type: :string  # Override/extend
end
```

This introspects Alba resources and ActiveRecord models to auto-generate components:

- Maps database column types to OpenAPI types
- Handles nullable columns, arrays, JSONB
- Extracts inclusion validators as enum values
- Uses column comments as descriptions
- Supports Alba associations

### Current Usage Pattern

All routes use the `Raxon::RouteLoader.register` helper pattern. Example from `examples/routes/api/v1/ping/get.rb`:

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Returns an affirmative ping to validate the API is up and your API key is valid"

  endpoint.response 200, type: :object do |response|
    response.property :success, type: :boolean, description: "true if ping was successful"
  end

  endpoint.handler do |request, response, metadata|
    response.code = :ok
    response.body = { success: true }
  end
end
```

**Key points:**

- Endpoint definition and handler are in the same file
- OpenAPI metadata (description, responses) comes before handler
- Path is derived from file location via `Raxon::RouteLoader.register(__FILE__)`
- OpenAPI generation happens via the `openapi:generate` Rake task
- Handler receives three arguments: `request`, `response`, and `metadata`

### Request Metadata

Endpoints can define metadata blocks that build request-specific context. Metadata flows hierarchically from parent to child routes, with later blocks able to override earlier values.

#### Defining Metadata Blocks

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.metadata do |request, response, metadata|
    metadata[:api_version] = "v1"
    metadata[:request_id] = SecureRandom.uuid
  end

  endpoint.handler do |request, response, metadata|
    # metadata[:api_version] and metadata[:request_id] are available here
    response.code = :ok
    response.body = { version: metadata[:api_version] }
  end
end
```

#### Hierarchical Metadata

Metadata blocks are executed from parent to child in the route hierarchy. Parent routes can set defaults that child routes can read or override:

**Parent route (`routes/api/v1/endpoint.rb`):**
```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.metadata do |request, response, metadata|
    metadata[:api_version] = "v1"
    metadata[:authenticated] = false
  end
end
```

**Child route (`routes/api/v1/users/get.rb`):**
```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.metadata do |request, response, metadata|
    # Can read parent metadata
    metadata[:resource] = "users"
    # Can override parent values
    metadata[:authenticated] = true
  end

  endpoint.handler do |request, response, metadata|
    # Has access to all accumulated metadata
    # metadata[:api_version] = "v1" (from parent)
    # metadata[:resource] = "users" (from this endpoint)
    # metadata[:authenticated] = true (overridden)
  end
end
```

#### Metadata Execution Order

1. **Metadata blocks** execute first (parent to child)
2. **Before blocks** execute next (parent to child), receiving the metadata
3. **Handler** executes with the accumulated metadata
4. **After blocks** execute last (child to parent), receiving the metadata

#### Before/After Blocks with Metadata

Before and after blocks also receive metadata as a third argument:

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.metadata do |request, response, metadata|
    metadata[:start_time] = Time.now
  end

  endpoint.before do |request, response, metadata|
    # Can read/modify metadata before handler runs
    metadata[:user] = authenticate(request)
  end

  endpoint.handler do |request, response, metadata|
    response.code = :ok
    response.body = { user: metadata[:user].name }
  end

  endpoint.after do |request, response, metadata|
    # Can access metadata set by earlier stages
    elapsed = Time.now - metadata[:start_time]
    response.header "X-Processing-Time", elapsed.to_s
  end
end
```

**Note:** Existing code with 2-argument blocks continues to work since Ruby allows blocks to ignore extra arguments.

### Type System

**Supported types:**

- `:string` - String values
- `:number` - Numeric values (integer, float)
- `:boolean` - true/false
- `:object` - Hash/object with nested properties
- `:array` - Array (use `of:` to specify element type)
- `[:string, :number]` - Union types (anyOf in OpenAPI)
- `"Dayjs"` - Custom type for dates/timestamps

**Database column mapping:**

- integer, bigint → :number
- numeric(\*), double precision → :number
- string, character varying, text → :string
- boolean → :boolean
- timestamp, date → "Dayjs"
- jsonb → :object

### OpenAPI Output

The library generates OpenAPI 3.0.0 compliant JSON via the Rake task:

```bash
bundle exec rake openapi:generate
```

**Output files:**

- `doc/apidoc/api.json` - OpenAPI 3.0.0 JSON specification
- `doc/apidoc/api.html` - HTML documentation using Swagger UI

### Known Limitations & Extension Areas

Based on TODOs in the codebase, these areas may need extension:

1. **Request body definitions** - Currently only responses are well-supported
2. **Security/authentication schemes** - No built-in support for security definitions
3. **Example values** - Properties don't have example data support
4. **Default values** - No explicit default value support for properties
5. **Content negotiation** - Currently hardcoded to `application/json`
6. **Nullable improvements** - Some TODOs mention "nilable" support refinement
7. **SQL check constraints** - TODOs mention adding constraint validation
8. **Multiple operations** - `to_open_api` only uses first operation per endpoint

**When you encounter these limitations: extend the library, don't work around it.**

### Testing

The library has comprehensive test coverage in `lib/openapi-dsl/spec/`. When extending functionality:

- Follow existing test patterns
- Test all new features
- Run specs with: `bundle exec rspec lib/openapi-dsl/spec/`

### Key Reference Files

- **Main implementation:** [lib/openapi-dsl/lib/openapi-dsl/open_api.rb](lib/openapi-dsl/lib/openapi-dsl/open_api.rb) (730 lines)
- **Example usage:** [examples/routes/api/v1/ping/get.rb](examples/routes/api/v1/ping/get.rb)
- **Generation task:** [lib/openapi-dsl/lib/openapi-dsl/tasks/generate.rake](lib/openapi-dsl/lib/openapi-dsl/tasks/generate.rake)
- **Tests:** [lib/openapi-dsl/spec/openapi-dsl/](lib/openapi-dsl/spec/openapi-dsl/)

## Handler Helpers

Raxon provides a handler helper system that allows you to define reusable methods that are available within endpoint handler blocks.

### Core Concepts

- **HandlerHelpers Module**: All helper methods are defined in or extend the `Raxon::HandlerHelpers` module
- **Auto-loading**: Helpers can be automatically loaded from a configured directory
- **Global Availability**: Once loaded, helpers are available to all endpoint handlers
- **No Naming Requirements**: Helper files and modules can be named however you prefer

### Configuration

Configure the helpers path in your application initialization:

```ruby
# config.ru or similar
Raxon.configure do |config|
  config.helpers_path = "app/handlers/concerns"
end
```

**Default**: `nil` (no auto-loading)

If `helpers_path` is `nil` or the directory doesn't exist, no helpers are auto-loaded and no error is raised.

### Defining Helpers

Helpers are defined by extending or reopening the `Raxon::HandlerHelpers` module. Create Ruby files in your configured helpers path:

**Example: `app/handlers/concerns/authentication_helpers.rb`**
```ruby
module Raxon::HandlerHelpers
  def authenticate!(request)
    token = request.rack_request.get_header("HTTP_AUTHORIZATION")
    # Authentication logic here
    raise "Unauthorized" unless valid_token?(token)
  end

  def valid_token?(token)
    # Token validation logic
    token == "secret-token"
  end
end
```

**Example: `app/handlers/concerns/response_helpers.rb`**
```ruby
module Raxon::HandlerHelpers
  def json_success(data, status: 200)
    { success: true, data: data, status: status }
  end

  def json_error(message, status: 400)
    { success: false, error: message, status: status }
  end
end
```

### Using Helpers in Handlers

Once defined, helpers are available directly within handler blocks:

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Protected endpoint requiring authentication"

  endpoint.response 200, type: :object do |response|
    response.property :success, type: :boolean
    response.property :data, type: :string
  end

  endpoint.handler do |request, response, metadata|
    # Helper methods are available directly
    authenticate!(request)

    response.code = :ok
    response.body = json_success("Protected data")
  end
end
```

**Passing request/response/metadata to helpers is optional**:

```ruby
endpoint.handler do |request, response, metadata|
  # Helpers can accept request/response/metadata if needed
  user = authenticate_user(request, metadata)

  # Or work without them
  data = format_data(user)

  response.code :ok
  response.body = data
end
```

### Helper Loading

Helpers are loaded automatically when the Router is initialized:

```ruby
# In config.ru
require "raxon"

Raxon.configure do |config|
  config.routes_directory = "routes"
  config.helpers_path = "app/handlers/concerns"
end

# Helpers are loaded when Router/Server is created
run Raxon::Server.new
```

You can also manually load helpers:

```ruby
Raxon.load_helpers
```

**Loading behavior:**
- Helpers are loaded only once, even if `load_helpers` is called multiple times
- All `.rb` files in the helpers path (including subdirectories) are loaded
- Files are loaded with `load`, so they can be reloaded in development if needed

### Directory Structure

You can organize helpers however you prefer:

```
app/
└── handlers/
    └── concerns/
        ├── authentication_helpers.rb
        ├── validation_helpers.rb
        ├── response_helpers.rb
        └── auth/
            └── jwt_helpers.rb
```

All files will be loaded automatically, regardless of directory depth.

### Testing Helpers

Helpers can be tested independently by extending a test object:

```ruby
RSpec.describe "Authentication Helpers" do
  let(:helper_context) do
    Object.new.tap { |obj| obj.extend(Raxon::HandlerHelpers) }
  end

  it "validates tokens" do
    expect(helper_context.valid_token?("secret-token")).to be true
    expect(helper_context.valid_token?("wrong-token")).to be false
  end
end
```

### Implementation Details

Helpers are extended into the handler block's binding when the handler is defined (via `endpoint.handler`), not on every execution. This is more efficient and happens only once per handler definition.

### Key Files

- **HandlerHelpers module**: [lib/raxon/handler_helpers.rb](lib/raxon/handler_helpers.rb)
- **Configuration**: [lib/raxon/configuration.rb](lib/raxon/configuration.rb)
- **Integration**: [lib/raxon/open_api/endpoint.rb](lib/raxon/open_api/endpoint.rb) (handler method extends block at definition time)
- **Loading logic**: [lib/raxon.rb](lib/raxon.rb) (load_helpers method)
- **Tests**: [spec/raxon/handler_helpers_spec.rb](spec/raxon/handler_helpers_spec.rb)
