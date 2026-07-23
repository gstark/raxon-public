# Raxon — Deep Review

_Reviewed 2026-07-19 · status current as of 2026-07-19_

Four independent passes fed this review — a read of the runtime, a DSL-internals
reviewer, an agent-DX reviewer that scaffolded a real `raxon new` app, and a
gpt-5.5 security pass — with every finding verified by executing against the gem.
The framework is well-architected: clean separation (`Endpoint` describes,
`EndpointInvocation` executes, `ParamResolver` isolates sources), genuinely good
error messages for typo'd option keys, correct HTTP semantics out of the box,
Erubi auto-escaping, and a sane proxy-header default.

Findings originally clustered in three places: **a fail-open auth path,
bypassable resource limits, and a Symbol-vs-String normalization bug that broke
the documented happy path.** Two further failures made the out-of-box experience
broken for a new user. All of those are now fixed.

This document is organized by **status**, not by severity: everything still open
is in Part I, everything resolved is summarized in Part II. Item IDs (H-1, M-6,
B-3, C-8 …) are preserved from the original per-pass appendices so earlier
references still resolve — A = DSL internals, B = agent-buildability,
C = security.

**Where things stand:** every finding is closed. What remains in Part I is three
deliberate decisions, not outstanding work — two deferrals with reasons, and one
release call that is the maintainer's to make.

Two findings turned out to be wrong on inspection and were resolved differently
than written: `M-7`'s structural defense was already in effect (just unguarded),
and `L-6`'s real hazard was the route registry rather than `DSL.default_spec`.
Verifying before fixing changed the work in both cases. One bug not in any review
pass — every multipart request body emitting an invalid `"type": "multipart"` —
was found by writing an upload route from the new `llms.txt` and reading the
generated document.

Verification for the fixed work: full suite green at 100% line + branch
coverage, lint clean, and a scaffold smoke test that boots `raxon new` output
against a gemspec-only bundle on every run.

---
---

# Part I — Deliberate decisions

Not open work. Each of these was considered and declined, with the reasoning
recorded so it does not get relitigated from scratch.

## Correctness

### M-6 (residual) — body-only types nested inside a parameter

**Severity: low.** The direct case is fixed (see Part II). Not covered: a
body-only type nested *inside* a parameter's property tree.

```ruby
params.define :meta, type: :object do |p|
  p.property :f, type: :file    # not rejected
end
```

The guard lives in `Parameter#initialize`, which only sees the parameter's own
`type:`. Nested properties are built by `PropertyContainer#property` on plain
`Property` objects that have no idea a parameter is their ancestor, so catching
this means either threading ancestry through `Property` or validating the whole
subtree lazily at schema-build time (a runtime raise rather than a load-time
one). Deliberately not done: a binary field nested in an object query parameter
is exotic, and a guard that silently stops at depth 1 would be more misleading
than none.

## Security

### C-8 (residual) — no magic-byte/MIME signature inspection

**Declined.** Size limits and an extension allowlist shipped (see Part II);
content sniffing did not. It needs a signature table the project would have to
keep current, and deciding whether bytes are an acceptable image is handler
domain logic rather than part of the request contract. `docs/security.md` and
`docs/file_uploads.md` say plainly that `allowed_extensions` matches an untrusted
client filename and does not establish what a file is.

## Documentation

### CHANGELOG — no release entry for the current work

Everything since 0.1.0 sits under `[Unreleased]`. The stale `Api::ErrorHandler`
namespace is fixed and `[Unreleased]` now states that the published 0.1.0 gem
contains only the `[0.1.0]` section, so the ambiguity an agent would hit is
resolved. Cutting an actual versioned entry is a release decision, deliberately
left alone.

---
---

# Part II — Handled

Each entry is the finding and what was actually done. Full detail lives in the
commits; the fix notes here are the durable part.

## The five that were fixed first

1. ⚑ **Auth failed open** — a typo'd or not-yet-declared scheme name in
   `endpoint.security` was silently classified "documentation-only" and the
   request granted 200 without credentials, while the generated OpenAPI still
   advertised the endpoint as protected (`endpoint_invocation.rb:69-77`; also
   A-H-3, C-2). **Fixed:** fails closed with a 401 when a requirement references
   an undeclared scheme; declared-but-authenticator-less schemes still skip, as
   documented.
2. ⚑ **Request-body limit off by default and bypassable when on** — defaulted to
   `nil`, and the check read `Content-Length` via `.to_i`, so absent, chunked,
   negative, or non-numeric lengths sailed through (`router.rb:280`; also C-1).
   **Fixed:** strict `Integer(…, 10)` parsing, a 10 MB default, and a
   `LimitedInput` wrapper (`lib/raxon/limited_input.rb`) that raises
   `RequestBodyTooLarge` mid-read, so a lying or absent length is caught during
   the read and answered 413.
3. ⚑ **`activesupport` require broke every rake task in a real project** —
   `lib/tasks/generate.rake:6` required `active_support/core_ext/hash`, which is
   not a gemspec dependency and only resolved inside this repo. `rake -T`,
   `raxon:openapi:generate`, and `raxon:routes` all `LoadError`'d in a scaffolded
   app, killing the primary "did my schema compile?" loop (also B-1).
   **Fixed:** the require was unused; deleted.
4. ⚑ **`Server.new` silently swallowed keyword args** — `server.rb:54` captured
   `**args` and never read it, so `Server.new(routes_directory:)` and
   `Server.new(fallback:)` no-op'd. The repo's own `config.ru` therefore 404'd on
   every route (also B-2). **Fixed:** honors `fallback:`/`routes_directory:` and
   raises `ArgumentError` on anything else.
5. ⚑ **Symbol-named components emitted invalid OpenAPI** — `DSL.component(:User)`
   stored the Symbol, the `$ref` guard compared `[:User].include?("User")`, and
   `of: :User` emitted `{"items":{"type":"User"}}`. The documented style used
   Symbols — the broken path — while every spec used Strings (also A-H-1).
   **Fixed:** component names coerced to String, property keys to Symbol, so
   `$ref` emits correctly and duplicate string/symbol keys collapse.

## Generated-document validity (A: H-1, H-2, M-1 – M-5)

- **`from_resource`/`from_table` raised on common Postgres types** — no default
  branch, so `uuid`, bare `numeric`, `json`, `smallint`, `inet` exploded at boot;
  a UUID primary key is the most common Rails/Postgres choice. **Fixed** with a
  data-driven `openapi_element_for_sql_type` map (unknown → string), which also
  collapsed the six byte-identical `*_property_options` methods (M-11).
- **Untyped property emitted `"type": null`.** **Fixed** — omits the key. Note
  this fix was document-only, and left the runtime disagreeing with the document
  (untyped validated as a string) until M-9 closed the other half.
- **`type: :array` with no `of:` emitted `"items": {"type": ""}`.** **Fixed** —
  emits `items: {}`.
- **Endpoint with no `path` emitted a `""` path key.** **Fixed** — raises
  `Raxon::OpenApi::Error` (which had been a defined-but-never-raised dead class).
- **3.0 output put `nullable` as a `$ref` sibling**, silently ignored by tooling.
  **Fixed** — `anyOf`+null on 3.1, `allOf`+`nullable` on 3.0.
- **No way to declare a body-less 204/304**; `content` was always emitted.
  **Fixed** — `response 204` with no type emits no `content`.

- **Every multipart request body emitted `"type": "multipart"`** — not a JSON
  Schema type, so the document was invalid for every file-upload endpoint and no
  validator or client generator could act on that schema. Found while verifying
  `llms.txt` against a scaffolded project, not by any review pass. `multipart` is
  a Raxon-level marker that selects the `multipart/form-data` media type; it was
  passed through to the schema `type` keyword as well. **Fixed:** the emitter
  maps it to `object` (the body *is* an object of form fields) while media-type
  selection, which reads the RequestBody's own type, is untouched.

All are now guarded by a `document_validity_spec` that walks the generated
document — the "highest-leverage test to add" from the original review, since one
test covers the whole class. That spec's type check was itself too weak to catch
the multipart bug: it asserted only that `type` was neither nil nor empty. It now
checks every emitted `type` against the seven real JSON Schema types, so a
DSL-level name cannot leak into the document again.

## Security (C: 1 – 7, 9, 10; M-7; §2)

- **Route/helper containment was lexical** — `File.expand_path` resolves `..` but
  not symlinks, so a `.rb` symlink inside a route tree could point outside the
  root and execute at boot with full privileges (C-3). **Fixed:** new
  `Raxon::PathContainment` resolves real paths and refuses to load an escaping
  file (in-tree symlinks still allowed); `reload_routes?` forces off outside
  development; the trust model — namespace scoping, not a sandbox — is documented.
- **Proxy trust was all-or-nothing and took the leftmost `X-Forwarded-For`**
  (C-4), forgeable if the proxy appends or the backend is reachable directly.
  **Fixed:** `config.trusted_proxies` (IP/CIDR list, default `[]`); `remote_ip`
  walks the chain from the right with `IPAddr`, discarding trusted hops.
- **CLI generator allowed directory traversal and Ruby source injection** (C-6) —
  `..` preserved, and a segment like `safe#{Kernel.system("id")}` written
  verbatim into a double-quoted Ruby string that executes at load. **Fixed:**
  segments allowlisted, literals emitted with `String#dump`, resolved path
  verified under the routes root.
- **`flows` on a security scheme was emitted verbatim** into public
  `api.json`/HTML (C-7), so `flows: {client_secret: ENV[…]}` leaked the secret.
  **Fixed:** validated structurally against the scheme type and the OpenAPI flow
  shape — an allowlist, not a keyword denylist, so the legitimate `password` flow
  name survives.
- **Developer regexps ran with no timeout** (C-5) against attacker-controlled
  subjects. **Fixed:** `config.regexp_timeout`, default 1.0s, per-regexp and
  scoped to Raxon's own patterns.
- **`max_length` before `format?`** (M-7 residual) — the review recorded the
  cheaper structural defense as not applied. It turned out to be *already in
  effect but unprotected*: dry-schema chains predicates with a short-circuiting
  AND in declaration order, and `dry_constraints_for` happened to emit
  `max_size?` before `format?`, so an oversized value was already rejected on
  length without the regexp running. Verified both directions — with the
  emitted order a 5000-char subject never reaches the regexp; with `format?`
  first it does. The exposure was therefore one edit away, with nothing to
  catch it. **Fixed:** the ordering is now documented as load-bearing at the
  call site and pinned by a spec that feeds a catastrophic pattern an oversized
  subject *with the timeout disabled*, so a reorder hangs the suite rather than
  passing quietly. Also documented the unanchored-pattern gotcha (`pattern:` is
  a search, not a full match, on both sides) in the README and
  `docs/security.md`, with the `max_length` + `pattern:` pairing recommended.
- **Error logs could be forged and leak** (C-9) — messages and backtraces logged
  without CR/LF sanitization; the callback got the raw Rack env. **Fixed:**
  control characters stripped from every logged value; the raw-env caveat
  documented on the callback and in `docs/security.md`.
- **Uploads were only structurally validated** (C-8) — the docs said
  "enforce per-file and aggregate size limits" and "use an extension allowlist"
  while giving no way to declare either, so every app hand-rolled it in the
  handler. **Fixed** with three schema options: `max_size` on a file property,
  `max_total_size` on the request body (catching uploads each within their own
  limit but too large together), and `allowed_extensions`. Size violations raise
  `RequestBodyTooLarge` → 413, matching `max_request_body_size`; a disallowed
  extension answers 422 — the request was well-formed and carried a real file,
  the endpoint just refuses that kind — while a malformed request stays 400.
  Errors are reported together regardless of status, so a request that is both
  missing a field and carrying a rejected upload lists both; only the status
  differs, and a content rejection wins it. `max_size` emits as `maxLength` on the
  binary schema so generated clients see the limit; `allowed_extensions` has no
  standard keyword and stays runtime-only rather than being invented into the
  document.

  Deliberately **not** done: magic-byte/MIME signature sniffing. It needs a
  signature table the project would have to keep current, and it belongs to the
  handler's domain logic rather than the request contract. The docs are explicit
  that `allowed_extensions` matches an untrusted client filename and is a
  usability check, not a security control — renaming `shell.php` to `shell.jpg`
  defeats it — and that both limits apply after Rack has buffered the parts, so
  `max_request_body_size` remains what bounds intake. Overstating these would be
  worse than not having them.

  `UploadedFile.valid_upload?` was removed in the process: the validator now
  needs the normalized object rather than a boolean, and nothing else called it.
- **Rack parse exceptions became 500s or escaped the framework** (C-10).
  **Fixed:** the Router rescues `Rack::BadRequest` on both the matched-route and
  catchall paths, returning 400 or 413, bypassing app exception handlers and the
  exception tracker.
- **`ErrorHandler` was opt-in**, so a bare `run Raxon::Server.new` leaked raw
  exceptions to the app server's default page. **Fixed:** `Raxon::Server` wraps
  the router automatically (`config.wrap_error_handler`, default true), detects an
  explicitly added `ErrorHandler` and does not double-wrap. This also closed
  C-10's "install safe error middleware in all runnable examples" — the examples
  have no middleware of their own and are now covered.

## DSL ergonomics (A: H-4, H-5, M-6, M-8, M-9, L-1, L-2, L-3; B-5)

- **`FileUploadValidator::ValidationResult#to_h` returned coerced output on a
  failed validation** (L-1), unlike the near-identical
  `ResponseSchemaGenerator::ValidationResult#to_h`, which guards on `success?`.
  The wrapper is only ever built for a failure — the validator returns the
  Dry::Schema result untouched when everything passes — so `success?` is always
  false and the coerced branch was reachable on *every* instance, not just an
  edge case. A caller checking errors loosely got a params hash carrying values
  that had failed upload validation (`{photo: "not-a-file", count: 5}` — note the
  integer, coerced out of a rejected request). **Fixed:** it holds the input
  params and returns those, so the failure path can never surface coerced
  values. `ParamResolver` already guarded on `success?`, so nothing in-tree
  changed behavior; this closes the trap for callers that don't.


- **`property` required a positional options hash** (M-9) — `property :a` raised
  `wrong number of arguments (given 1, expected 2)`, an error about the DSL
  rather than about the declaration. **Fixed:** `options = {}` on
  `PropertyContainer#property`, `RouteDSL::NestedDSL#property`, and
  `Parameters#define`.

  The finding was half stale and half understated. `Endpoint#response` already
  defaulted its options (`endpoint.rb:353`), so only `property` was affected.
  But defaulting the hash alone would have made `property :a` *silently wrong*:
  an untyped property emits no `type` key (correct, "any type" per M-1) while
  `dry_schema_type` fell through its `else` branch to `:string`, so the runtime
  demanded a string for a property the document described as any. Verified
  before fixing: `untyped vs number: false`, `untyped vs hash: false`,
  `untyped vs string: true`. That is exactly the confusing-500 shape this review
  flagged for typo'd types — and it was reachable *today* via
  `property :a, description: "x"`, with no bare-name call needed.

  So the real fix was the mapping: `nil` now maps to `:any`. That needed a
  dedicated `add_untyped_field` path, because dry-schema silently drops
  predicates passed alongside `:any` — `value(:any, included_in?: […])` accepts
  anything — which would have dropped a declared enum. Constraints are applied
  without a type instead. Covered for the plain, enum, nullable, nullable+enum,
  and missing-required combinations.

- **`Parameters#define` had the same wart** and now defaults too. A bare
  `define :page` raises `option 'type' is required` rather than an arity error —
  parameters keep requiring a type, since a parameter with no type has no
  defined serialization.

- **`type: :file` on a parameter half-worked** (M-6) — worse than either extreme.
  An `in: :query` parameter is validated against the lenient source merge
  (`param_resolver.rb:93`), which includes form params, so a real multipart
  upload *did* reach it; but `RequestSchemaGenerator` gates `FileUploadValidator`
  on the request body and `ParamResolver#finalize` coerces only via
  `RequestBodyCoercer`, so the handler received a raw Rack hash instead of the
  documented `Raxon::UploadedFile`, and a non-file value passed validation
  entirely. Confirmed both ways before fixing: `real upload -> Hash`,
  `"not-a-file" -> no errors`. OpenAPI also defines no serialization for binary
  in a parameter, so the declaration was undescribable regardless of runtime
  behavior. **Fixed:** `Parameter` rejects `:file`/`:multipart` (including inside
  a union, in every location) at construction with an error naming the parameter
  and showing the request-body form; documented in `docs/file_uploads.md`.
  A residual nested case is in Part I.

- **Unknown `type:` values were accepted silently** — `type: :strng` loaded fine,
  emitted `{"type":"strng"}`, then threw a confusing runtime 500 for a field the
  author believed was correct. **Fixed:** validated against a canonical
  `KNOWN_TYPES` across Property, Parameter, Response, Component, and RequestBody,
  with union members checked individually; `content_type:` rejects non-media-type
  values. `of:`/`as:` name components (an open set) and are deliberately not
  validated.
- **`Parameter#in` accepted any value** — `in: :qeury` produced an invalid
  document and a parameter never sourced at runtime. **Fixed:** validated against
  query/header/path/cookie.
- **`RequestBody` was the one DSL class without `StrictOptions`** — exactly the
  class most often hand-written (`endpoint.body …`) silently accepted typo'd keys
  and lacked `enum`/`allowable_values`. **Fixed:** both added.
- **String and Symbol property names created duplicate properties**, so a
  block-declared string key did not suppress an introspected column and the
  intended override became a duplicate. **Fixed** with the same normalization as
  finding 5.
- **`Endpoint#operation` returned `nil` unpredictably** (trailing `.uniq!`) and
  **`response_schemas` memoization was not invalidated by late mutation**, unlike
  the request side. **Fixed:** returns the array; invalidation routed through a
  named `invalidate_response_schemas` mirroring `invalidate_request_schema`.

## Structure and duplication (A: M-10 – M-13, L-4, L-5, L-6)

- **`DSL` was a 1082-line god object** (M-10) mixing five responsibilities on
  ~30 class singletons: type processing, SQL→OpenAPI mapping, schema emission,
  document assembly, and thread-local registry state. `Specification` had been
  extracted to hold state, but every behavior still lived on `DSL.*`, so
  `Specification#to_open_api` reached back through the global class.
  **Fixed:** the extraction is finished. Each responsibility is now its own unit —
  `Specification` (state + `from_resource`/`from_table`), `DocumentBuilder`
  (one instance per document: paths, operations, components, the 3.1 nullable
  rewrite), `SchemaEmitter` (any DSL object → schema hash, and the
  `with_components` context), `TypeSystem` (`type:`/`content_type:`/`extensions:`
  validation and `KNOWN_TYPES`), `ColumnMapper` (SQL/Alba → property), and
  `SpecVersion`. `DSL` is left as a 100-line facade that owns only the default
  specification and delegates. No behavior changed: the same 1340 examples pass
  at 100% line and branch coverage. Call sites moved with the methods — the DSL
  option procs now call `TypeSystem` directly rather than routing through `DSL`.
- **Hot reload raced in-flight requests** (L-6) — and the exposure was larger
  than the finding described. The review named `DSL.default_spec.endpoints`, but
  the serious one was the route registry: `RouteReloader#reload!` called
  `RouteLoader.reset!` (rebinding `@routes` to an empty collection) and then
  repopulated it in place. `Router#call` releases the reloader's mutex *before*
  reading the registry, so a concurrent request reaching the lookup mid-reload
  found nothing. The window is not an instant — it is a glob plus a read and
  eval of every route file. Reproduced directly: mid-reload, a lookup for a
  route that plainly exists returned `MISSING`. Worse, a route file that raised
  left the registry permanently empty, so one syntax error 404'd *every* route
  until it was fixed. **Fixed:** `RouteLoader.reload!` builds into a staging
  registry visible only to the loading thread (`STAGING_KEY`) and publishes it
  with a single assignment, so a reader sees the complete old table or the
  complete new one. Nothing is published if the load raises, so a broken file
  now leaves the working routes serving. `Router#call` reads the registry once
  into a local, since it consults it twice and could otherwise straddle
  generations, and the endpoint list is replaced rather than mutated in place
  (`Specification#drop_route_file_endpoints!`) so document generation cannot
  have entries removed underneath its iteration. Both behaviors are pinned by
  specs that fail against the old code.
- **Redundant nested `with_components`** (L-5) — `to_open_api` and
  `build_components` each opened one. **Fixed** by the same work: `DocumentBuilder`
  establishes the component context once for the whole build, and it is now
  unambiguously owned by `SchemaEmitter`.

- **Two divergent type maps in one class** — `dry_schema_type` (symbols) vs
  `map_type_to_dry` (strings), disagreeing on `file`, the latter dead in
  production. **Fixed:** deleted, along with its two pass-through delegators and
  25 self-referential specs.
- **`Property` and `Parameter` duplicated ~20 option declarations verbatim** and
  had already drifted (`description` defaults differ, forcing a defensive `.to_s`).
  **Fixed:** shared `SchemaOptions` module; each class declares only what
  legitimately differs. Divergent defaults verified preserved.
- **Six near-identical `*_property_options` methods** — ~85 lines for a 6-row
  table. **Fixed** by the SQL type map above.
- **Dead members** — `Response#options` / `RequestBody#options` removed;
  `Raxon::OpenApi::Error` is now raised (missing-path guard); `Component#as`
  turned out to be load-bearing for the shared emitter and is kept with a comment
  explaining why it is intentionally always nil.
- **No public config/test reset** — the suite resorted to
  `Raxon.instance_variable_set(:@configuration, …)`, and apps testing against the
  framework would have needed the same hack. **Fixed:** `Raxon.reset!` and
  `Raxon.reset_configuration!`; all 8 specs now use the public API.

## Docs and scaffold (B: 3, 4, 7, 8, 9, Low)

- **Every documented rake task name was wrong** — `rake openapi:generate` and
  `rake routes` instead of the `raxon:`-namespaced real names, repeated in
  CLAUDE.md; plus `ROUTES_DIR` instead of `RAXON_ROUTES_DIR`. Invisible to
  contributors because the repo's Rakefile loads the `.rake` files directly.
  **Fixed** everywhere.
- **README taught a `before.rb` route file that hard-crashes boot** — `before` is
  not a valid HTTP-method filename; the construct is `all.rb`. **Fixed.** The
  error message itself was already excellent (names the file, lists valid
  options). Relatedly, `raxon routes` buried that message behind a bundler
  backtrace and a fallback warning; a `Raxon::Error` from `config.ru` now aborts
  with just the message.
- **`rescue_from` was documented nowhere**, so the natural move is hand-rolled
  `begin/rescue` in every handler. **Fixed:** a README section plus a config-list
  entry, and an `docs/lifecycle.md` section recording what the code actually does
  — the rescue wraps the whole pipeline (so a handled exception skips `after`
  blocks), matching is most-specific-class-first, and
  `HaltException`/`RequestBodyTooLarge`/`Rack::BadRequest` never route there.
- **README mixed DSL forms with no orientation** — the Basic Example used the
  bare form, later sections the `|endpoint|` form, and several snippets were
  orphan `endpoint.handler` fragments with no enclosing block; handler arity
  varied between 2 and 3 args with no statement that both work. **Fixed:** a
  paragraph after the Basic Example states the equivalence and the arity rule,
  and the four orphan snippets now show the enclosing `Raxon.route`. Remaining
  bare `endpoint.*` lines are deliberate — they are attribute reference lists,
  not runnable examples.
- **The scaffold set up testing halfway** — `spec/` and rspec in the Gemfile, but
  no `spec_helper.rb`, no `.rspec`, no example spec, and no mention of tests. The
  documented setup plus `conform_to_response_schema` is a genuinely strong
  verification loop; it was just undiscoverable from inside a scaffold.
  **Fixed:** all three scaffolded, README gained a Testing section. Verified in a
  fresh project — `raxon routes`, `rake raxon:openapi:generate`, and `rspec`
  (including `conform_to_response_schema(200)`) all green out of the box.
- **`raxon new` shipped no agent doc.** **Fixed:** `AGENTS.md` covering the
  contract-first rule, the file→route table, valid filenames and types, both DSL
  forms, lifecycle order, and the verify loop.
- **An agent reading the installed gem landed on contributor guidance** (B-6
  residual) — `CLAUDE.md` is deliberately about changing Raxon itself ("extend
  the library, don't work around it", DSL internals), which is the wrong frame
  for someone building an app, and there was no app-builder counterpart outside
  a generated project. **Fixed:** a repo-level `llms.txt` (ships with the gem)
  covering the contract-first rule, a complete worked route file, the file→route
  table, both DSL forms, the type and constraint vocabulary, lifecycle order, the
  verify loop, and an annotated index of every doc. `CLAUDE.md` now states its
  audience in the first line and redirects app builders; the README points there
  too. Verified by scaffolding a project and running the file and the loop from
  `llms.txt` verbatim — `raxon routes`, `rake raxon:openapi:generate`, and
  `rspec` all green, with the emitted `{id}` parameter schema matching what the
  doc claims.
- **Smaller:** `--skip-git` produced no `.gitignore` (`write_gitignore` was nested
  inside `initialize_git`) — moved out, spec added. `raxon generate route` wrote
  to the default `routes/` even when config set another directory — the config.ru
  loading was extracted from `routes_command.rb` into `Raxon::ProjectLoader` and
  used by both; verified writing into a custom `app_routes/`. Scaffold handlers
  were 2-arg while `generate` emitted 3-arg — both 3-arg now. Broken `$id` doc
  link fixed and the remaining `$` examples converted to dunder. Placeholder
  issue-tracker link fixed. `root` documented as "required" though it defaults to
  `nil` and nothing sets it — softened to optional. Blank line added after
  generated `path_param` lines.

## Test-coverage gaps that enabled the above

- **Symbol-named components were never tested** — all 22 `component(…)` calls in
  `dsl_spec.rb` passed Strings, leaving the documented Symbol style entirely
  unexercised (→ finding 5 / H-1). **Closed.**
- **`endpoint.security` with an unresolvable scheme name was never tested**
  (→ H-3). **Closed.**
- **Nothing asserted the generated document validates** (→ M-1 – M-5).
  **Closed** by `document_validity_spec`. Its type check was initially too weak
  ("not nil, not empty") and let `"type": "multipart"` through; it now validates
  against the real JSON Schema vocabulary.
- **No smoke test booted `raxon new` output**, which is why B-1 — a `require` of
  activesupport in a rake task that is not a gemspec dependency — passed every
  spec while breaking every rake task in a real project. The bug was in what the
  gemspec *declares*, so no in-process test could see it. **Closed** by
  `spec/integration/scaffold_smoke_spec.rb`: it generates a project, bundles it
  against the gemspec alone, and runs `raxon routes`, `rake -T`,
  `raxon:openapi:generate`, and `rspec` inside it.

  Proven rather than assumed. Re-adding the exact B-1 require makes the repo's
  own 1360 specs pass unchanged while the smoke test fails with
  `cannot load such file -- active_support/core_ext/hash`. A first example
  asserts the scaffolded bundle *cannot* load activesupport, so the isolation
  that makes the rest meaningful is itself guarded — without
  `Bundler.with_unbundled_env`, the parent's `BUNDLE_GEMFILE` leaks in and the
  whole spec silently tests nothing. Costs ~2.5s, runs by default, skippable
  with `--tag '~scaffold'`.

---
---

# Reference

## What's genuinely good

Worth preserving as the model for future work:

- **`StrictOptions` (`strict_options.rb:44`)** — `unknown option for
  Raxon::OpenApi::Property: :requried. Known options: allowable_values, as,
  default, …`. Best-in-class feedback; the type-value validation added above was
  modeled on it deliberately.
- **`RouteDSL#method_missing` (`route_dsl.rb:50`)** — Ruby's `Did you mean?`
  survives, with the offending route file and line in the trace.
- **Invalid HTTP method filenames** raise loudly at load with the valid list.
- **`raxon routes`** renders a Path/Method/Before/Handler/Description/File table
  — an excellent cheap verification step.
- **HTTP semantics are free and correct** — verified on a scaffold: `POST` to a
  GET-only path → 405, `OPTIONS` → 204, unmatched → 404.
- **`conform_to_response_schema`** — validating responses against the declared
  OpenAPI schema is exactly the closed loop a test suite needs, and its failure
  messages (`test.rb:151-177`) distinguish wrong-status / no-route / no-schema /
  bad-JSON / schema-violation.
- **`CONTEXT.md`** is a genuinely good architecture-vocabulary doc for someone
  *modifying* raxon (less relevant for someone *using* it).

## Verified controls and negative results

From the security pass — these were checked and found sound, and are worth not
regressing:

- The Swagger JSON embedding (`lib/tasks/template.html.erb:38`) converts `<` and
  `>` to JSON Unicode escapes; a `</script><script>…` payload could not break out
  of the inert `application/json` element, and `textContent` is parsed at `:49`
  rather than interpolated into executable JavaScript.
- Swagger UI CDN resources use SRI and `crossorigin`. A restrictive CSP and
  periodic Swagger UI upgrades would still be useful defense in depth.
- `ErrorHandler` returns a fixed client-facing message and does not disclose
  exception text in the HTTP body.
- `remote_ip` ignores forwarding headers by default.
- Invalid JSON is caught and converted into a 400.
- Template output uses Erubi escaping by default.
- **No request-controlled input reaches `eval`, `instance_eval`, `instance_exec`,
  `class_eval`, `binding`, or `public_send`**, and no `const_get` or private
  `send` call uses request input. The dangerous evaluation sites consume
  developer-authored route/template/DSL code — though route and helper loading
  remains full arbitrary execution by design.
- JSON's nesting guard and Rack's parameter-depth limits bound ordinary remote
  recursion. No independently exploitable unbounded request recursion was found
  beyond the request-size and configured-regexp issues addressed above.
- No HTTP-path traversal into route files — paths match already-loaded routes.

## Deliberately out of scope

`docs/plans/2026-07-03-deferred-framework-gaps.md` records framework features
deferred by design (e.g. serving the OpenAPI document at runtime rather than as a
static `doc/apidoc/api.json`). Those are product decisions, not findings, and are
not tracked here.
