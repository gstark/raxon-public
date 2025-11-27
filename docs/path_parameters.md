# Path Parameters

This document explains how to use path parameters in your API routes.

## Overview

Path parameters allow you to define dynamic segments in your route paths. Parameters are extracted from the URL and made available in `request.params`.

## Syntax

To define a path parameter, prefix a directory segment with a dollar sign (`$`):

```
routes/api/v1/users/$id/get.rb
```

This creates a route with the path `/api/v1/users/{id}` where `{id}` is a path parameter.

## Examples

### Single Parameter

**File structure:**

```
routes/api/v1/users/$id/get.rb
```

**Route definition:**

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Retrieves a specific user by ID"

  endpoint.parameters do |params|
    params.define :id, type: :string, in: :path, description: "The user ID", required: true
  end

  endpoint.response 200, type: :object do |response|
    response.property :id, type: :string
    response.property :username, type: :string
  end

  endpoint.handler do |request, response|
    user_id = request.params[:id]  # Extracted from path
    # ... fetch user by ID
  end
end
```

**Matches:**

- `GET /api/v1/users/123` → `params[:id]` = `"123"`
- `GET /api/v1/users/abc-xyz` → `params[:id]` = `"abc-xyz"`

### Multiple Parameters

**File structure:**

```
routes/api/v1/orgs/$org_id/projects/$project_id/get.rb
```

**Route definition:**

```ruby
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Get project by organization and project ID"

  endpoint.parameters do |params|
    params.define :org_id, type: :string, in: :path
    params.define :project_id, type: :string, in: :path
  end

  endpoint.handler do |request, response|
    org_id = request.params[:org_id]
    project_id = request.params[:project_id]
    # ... fetch project
  end
end
```

**Matches:**

- `GET /api/v1/orgs/acme/projects/website` → `params[:org_id]` = `"acme"`, `params[:project_id]` = `"website"`

## Parameter Merging

Path parameters are automatically merged with query parameters and request body parameters:

```ruby
# Request: GET /api/v1/users/123?include=posts&limit=10

request.params[:id]      # "123" (from path)
request.params[:include] # "posts" (from query string)
request.params[:limit]   # "10" (from query string)
```

## OpenAPI Generation

Routes with `$parameter` segments are automatically converted to OpenAPI format:

- `routes/api/v1/users/$id/get.rb` → path: `/api/v1/users/{id}`
- Parameters defined with `in: :path` appear in the OpenAPI specification
- The generated OpenAPI documentation will show these as path parameters

## Pattern Matching

The routing system uses regex pattern matching to extract parameters:

- Parameters can contain any characters except forward slashes (`/`)
- Pattern: `[^/]+` (one or more non-slash characters)
- Parameters are extracted in order from left to right

## HTTP Method Filtering

Path parameters work with all HTTP methods. The router correctly matches both the method and the path pattern:

- `routes/api/v1/users/$id/get.rb` → matches `GET /api/v1/users/123`
- `routes/api/v1/users/$id/put.rb` → matches `PUT /api/v1/users/123`
- `GET /api/v1/users/123` will NOT match the PUT route

## Example Implementation

See [examples/routes/api/v1/users/$id/get.rb](../examples/routes/api/v1/users/$id/get.rb) for a complete working example.
