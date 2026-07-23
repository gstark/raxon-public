# Raxon — Domain Glossary

Names for the load-bearing concepts in Raxon. New terms are added here as the
architecture's seams get named. Architecture vocabulary (module, interface,
depth, seam, adapter, leverage, locality, the deletion test) is used as a shared
language for *why* a concept earns a name.

---

## Param resolution

Turning the raw, multi-source input of an HTTP request into a single
**validated, coerced parameter set** that a handler can rely on.

A request carries parameters in up to six places — query string, form body,
JSON body, path segments, headers, and cookies. Param resolution collapses these
into one map under a fixed precedence (`query < form < json < path`), then
re-reads any parameter with a declared `in:` location from *its* source so a body
value can't satisfy a required header, cookie, or path parameter. The merged set
is validated against the endpoint's request schema; on failure the lenient,
unvalidated merge is returned and the errors are recorded. Finally, request-body
properties are coerced (file uploads wrapped) into their final shape.

This is a **deep seam**: its interface is one verb over plain inputs —
`resolve(sources) -> Result(params, errors, parse_error)` — but it hides
precedence rules, source isolation, schema validation, lenient fallback, and
coercion. The module that owns it is `ParamResolver`
(`lib/raxon/param_resolver.rb`). Its supporting value objects:

- **Sources** — the six request sources for one request, collected by `Request`
  honoring the body-stream ordering constraint (JSON must be parsed before form
  params, because reading the form consumes the Rack stream). Only what a
  request needs is built: headers and cookies are read from the `Request` on
  first access, since most endpoints declare no parameter in either, and the
  form and JSON sources are skipped outright for a request that provably has no
  body.
- **Result** — the immutable outcome of resolution: final `params`, any
  `errors`, and whether the body failed to `parse`.

`Request` keeps a **gate** in front of resolution: a bare GET with nothing to
resolve short-circuits to path params without materializing any sources.

Related: the request schema and request body live on the endpoint spec; param
resolution depends on those two artifacts, not on the whole endpoint.

---

## Endpoint spec vs. Endpoint invocation

Two responsibilities that used to share one object, now split along a seam.

An **Endpoint** *describes* a route: its path, operations, parameters, responses,
schemas, and lifecycle blocks (metadata/before/after/handler). It is built once,
from a route file, and thereafter read as data. It is a spec.

**Endpoint invocation** *executes* a matched route against a request and response.
Given the selected endpoint and its matched hierarchy (parent → child), it runs
the lifecycle — metadata blocks (parent → child), before blocks (parent → child),
the handler with request and response validation around it, and after blocks
(child → parent) — and short-circuits to 400 on a bad request or 500 on a
schema-violating response. The module that owns it is `EndpointInvocation`
(`lib/raxon/endpoint_invocation.rb`); its one verb is
`run(request, response, metadata)`.

The split keeps the global lifecycle stages that wrap a single route — around
blocks, global before/after, instrumentation, halt, and exception handling — in
the **Router**, which now drives a route hierarchy through one verb instead of
reaching into endpoint bookkeeping (`has_handler?`, per-block execution). A halt
in a before block raises `HaltException`, which unwinds past the handler and
after blocks to the Router (flow control).

---

## Property container

The set of OpenAPI classes that hold a tree of nested property definitions:
Property, Response, RequestBody, Component, and Parameter. Each carries a
`@properties` hash and builds nested properties the same way, so the builder
itself is one shared mixin, `PropertyContainer`
(`lib/raxon/open_api/property_container.rb`), rather than five copies.

This names only the *construction* of the property tree. Its two *translations*
— to OpenAPI JSON (in `SchemaEmitter`) and to a Dry::Schema validator (in
`PropertySchemaBuilder`) — still live apart and do not share an abstraction. A
single property tree that owns both translations remains future work.
