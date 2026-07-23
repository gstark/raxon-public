# Request Lifecycle

This is the canonical guide for Raxon's request lifecycle. It documents the current behavior only; possible future middleware or grouping APIs are listed separately at the end.

## Lifecycle stages

For a matched route, Raxon executes stages in this order:

1. **Global `around` blocks** wrap the entire request lifecycle.
   - The first registered `around` block is outermost.
   - Each `around` block must call `inner.call` to continue.
2. **Global `before` blocks** run in registration order.
3. **Route `metadata` blocks** run from parent route to child route.
4. **Route `before` blocks** run from parent route to child route.
5. **The final handler** runs, if the selected endpoint has one.
6. **Route `after` blocks** run from child route to parent route.
7. **Global `after` blocks** run in registration order.
8. Control returns back out through global `around` blocks, from innermost to outermost.

With two global `around` blocks, the order is:

```text
around 1 before
  around 2 before
    global before
    route metadata parent -> child
    route before parent -> child
    handler
    route after child -> parent
    global after
  around 2 after
around 1 after
```

## Route hierarchy

A request can match a hierarchy of endpoint files. For a request to `GET /api/users`, these files can all participate:

```text
routes/api/all.rb
routes/api/users/get.rb
```

The hierarchy is parent-to-child by path depth. At each path level, `all.rb` participates before the method-specific file at the same level.

Route lifecycle blocks (`metadata`, `before`, `after`) run for every endpoint in the matched hierarchy. The final handler is special: only the selected endpoint's handler runs.

## `all.rb` behavior

`all.rb` registers an endpoint for every HTTP method at that path.

When an `all.rb` endpoint is a parent of a more specific match, it behaves as a parent lifecycle endpoint:

```text
routes/api/all.rb           # parent lifecycle endpoint
routes/api/users/get.rb     # final handler for GET /api/users
```

For `GET /api/users`:

1. `routes/api/all.rb` metadata runs.
2. `routes/api/users/get.rb` metadata runs.
3. `routes/api/all.rb` before blocks run.
4. `routes/api/users/get.rb` before blocks run.
5. `routes/api/users/get.rb` handler runs.
6. `routes/api/users/get.rb` after blocks run.
7. `routes/api/all.rb` after blocks run.

The parent `all.rb` handler does **not** run in this case.

`all.rb` also supplies inheritable endpoint defaults. Static `metadata`,
`path_param` refinements, `default_response`, security, response-validation
settings, and `validation_profile` are composed with the selected child route;
the nearest declaration wins. Request bodies, descriptions, summaries,
operation IDs, and handlers remain local to the selected route.

```ruby
# routes/api/orders/__id__/all.rb
Raxon.route do
  path_param :id, type: :integer
  default_response 404, type: :object do
    property :error, type: :string
  end
  metadata authenticated: true
end
```

When a route family needs a validation status/body different from the default
400/422 behavior, register and opt into a profile explicitly:

```ruby
Raxon.configure do |config|
  config.validation_error_profile(:uploads, status: :unprocessable_entity) do |message, details|
    {error: message, problems: details}
  end
end

# in an all.rb or selected route
validation_profile :uploads
```

When an `all.rb` endpoint is the selected endpoint, its handler runs:

```text
routes/api/all.rb # final handler for POST /api when no post.rb exists
```

## Request context and metadata

Use `request.context` for application-level request state that is created during the lifecycle and reused later in the same request, such as the authenticated user, request ID, authorization decisions, or timing data:

```ruby
metadata do |request, response, metadata|
  request.context[:request_id] = SecureRandom.uuid
end

before do |request, response, metadata|
  request.context.current_user = authenticate!(request)
end

handler do |request, response, metadata|
  response.body = {user_id: request.context.current_user.id}
end
```

`request.context` supports hash-style and method-style access:

```ruby
request.context[:current_user] = user
request.context.current_user    # => user
request.context.current_user = user
request.context[:current_user]  # => user
```

The third block argument, historically called `metadata`, remains supported for compatibility. It is the same backing hash used by `request.context`, so these two writes are equivalent within a request:

```ruby
metadata[:current_user] = user
request.context[:current_user] = user
```

Metadata/context flows down the route hierarchy. Parent values are available to child metadata blocks, before blocks, handlers, after blocks, global after blocks, and exception handlers. Later writes can overwrite earlier keys.

### What storage should I use?

- Use `request.context` for request-scoped application state computed by your app, for example `current_user`, `request_id`, `permissions`, or loaded records.
- Use `request.params`, `request.path_params`, `request.query_params`, `request.body_params`, or `request.form_params` for client-supplied input.
- Use `request.rack_request.env` only for Rack/server integration details or middleware-provided values.
- Use local helper methods for reusable behavior; use `request.context` only when a value must be shared across lifecycle stages.

## Before and after blocks

Route `before` blocks run parent-to-child before the handler:

```ruby
before do |request, response, metadata|
  request.context.current_user = authenticate!(request)
end
```

Route `after` blocks run child-to-parent after the handler:

```ruby
after do |request, response, metadata|
  response.header "X-Request-Id", request.context[:request_id]
end
```

Multiple blocks on the same endpoint run in the order they were defined.

## Halt behavior

Calling `response.halt` raises `Raxon::HaltException` and stops the remaining lifecycle for that request.

```ruby
before do |request, response, metadata|
  response.halt(code: :unauthorized, body: {error: "Unauthorized"}) unless authenticated?(request)
end
```

If a block halts:

- Later blocks in the current stage do not run.
- The handler does not run unless it already ran before the halt.
- Route `after` blocks and global `after` blocks do not run after the halt.
- `around` blocks only run their code after `inner.call` if they ensure/rescue the halt or otherwise handle control flow. A plain statement after `inner.call` is skipped when the halt propagates.

## Exception handling

An exception raised anywhere in the pipeline above — global blocks, metadata, before, handler, or after — unwinds to a single rescue around the whole request. Handlers registered with `config.rescue_from` are matched most-specific class first, and the first match builds the response:

```ruby
Raxon.configure do |config|
  config.rescue_from(MyApp::NotFound) do |exception, request, response, metadata|
    response.code = :not_found
    response.body = {error: exception.message}
  end
end
```

Because the rescue wraps the entire pipeline, a handled exception skips the remaining stages — `after` blocks do not run. `Raxon::HaltException` (flow control), `Raxon::RequestBodyTooLarge` (413), and `Rack::BadRequest` (400) are never routed to `rescue_from`. Anything unmatched propagates to `on_error` and the `Raxon::ErrorHandler` middleware's 500.

## Catchall routes

A catchall route is used only when no normal route matches. It then runs through the same global and route lifecycle with a hierarchy containing only the catchall endpoint:

1. Global `around` blocks.
2. Global `before` blocks.
3. Catchall metadata blocks.
4. Catchall before blocks.
5. Catchall handler.
6. Catchall after blocks.
7. Global `after` blocks.

Example:

```ruby
Raxon::RouteLoader.register_catchall do |endpoint|
  endpoint.handler do |request, response, metadata|
    response.code = :not_found
    response.body = {error: "Not Found"}
  end
end
```

## Future API ideas

The behavior above is the stabilized current lifecycle. Future API ideas should be considered separately from this documentation cleanup, for example:

```ruby
middleware do |request, response, metadata, continue|
  authenticate!
  continue.call
end
```

or:

```ruby
Raxon.group "/api/v1" do
  before { authenticate! }

  get "/users" do
    # ...
  end
end
```
