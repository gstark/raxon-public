# Path Parameters

This document explains how to use path parameters in your API routes.

## Overview

Path parameters allow you to define dynamic segments in your route paths. Parameters are extracted from the URL and made available in `request.params`.

## Syntax

Two syntaxes are supported for defining path parameters:

### Dunder Style (Recommended)

Wrap the parameter name with double underscores:

```
routes/api/v1/users/__id__/get.rb
```

This is the recommended style as it avoids issues with shell expansion and works reliably across all tools.

### Dollar Style

Prefix a directory segment with a dollar sign (`$`):

```
routes/api/v1/users/$id/get.rb
```

**Note:** The dollar prefix can cause issues with some shells and tools that interpret `$` as variable expansion. The dunder style is preferred for new projects.

Both syntaxes create a route with the path `/api/v1/users/{id}` where `{id}` is a path parameter.

## Examples

### Single Parameter

**File structure (dunder style):**

```
routes/api/v1/users/__id__/get.rb
```

**File structure (dollar style):**

```
routes/api/v1/users/$id/get.rb
```

**Route definition:**

```ruby
Raxon.route do |endpoint|
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

**File structure (dunder style):**

```
routes/api/v1/orgs/__org_id__/projects/__project_id__/get.rb
```

**File structure (dollar style):**

```
routes/api/v1/orgs/$org_id/projects/$project_id/get.rb
```

**Route definition:**

```ruby
Raxon.route do |endpoint|
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

Routes with `$parameter` or `__parameter__` segments are automatically converted to OpenAPI format:

- `routes/api/v1/users/__id__/get.rb` → path: `/api/v1/users/{id}`
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
