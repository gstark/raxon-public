# Security model

## Route and helper files are trusted code

Raxon builds an application by loading the `.rb` files in your configured
`routes_directory` (and `helpers_path`). Each route file is evaluated with
`class_eval` inside a per-file anonymous class.

That anonymous class is **namespace isolation, not a security sandbox.** A route
file runs with the full privileges of the server process: it can read
constants, call `Kernel`, touch the filesystem and network, and read secrets.
The isolation only keeps `def`-defined methods from leaking into the global
namespace between files.

The practical consequence: **your routes and helpers directories must be
trusted.** Treat them exactly like the rest of your source code.

- Own them with the deployment user and do not make them writable by untrusted
  users or processes.
- Do not generate route files from untrusted input at runtime.

There is no HTTP-path traversal into route files — incoming request paths are
matched against the routes already loaded at boot, never mapped to the
filesystem.

## Symlink containment

`File.expand_path` collapses `..` lexically but does not follow symlinks, so a
symlink placed inside the routes tree could otherwise point at, and execute, a
file elsewhere on disk. At load time Raxon resolves each candidate file's real
path (via `File.realpath`) and **refuses to load any file that resolves outside
the configured routes/helpers roots**, raising `Raxon::Error`. Symlinks that
stay within the tree are allowed; escaping ones are rejected.

This is defense in depth on top of "trust the directory", not a replacement for
it.

## Hot reloading is development-only

Route hot reloading watches the routes/helpers directories and re-executes
changed files on the request thread. Because that is a live code-execution
surface, it is **confined to development**: outside the development environment
it is always off, even if `config.reload_routes = true` is set. Within
development the default is on; set `config.reload_routes = false` to disable it.

## Request body size

Request bodies are capped at `config.max_request_body_size` (10 MB by default).
The limit is enforced both from the `Content-Length` header and while the body
is read, so a chunked or mis-declared length cannot bypass it. Raise the limit
for large uploads, or set it to `nil` to disable the check (and enforce size at
your proxy instead).

## Schema pattern regexps (ReDoS)

Raxon compiles the `pattern:` you declare on a string field into a validation
regexp that runs against attacker-controlled request values, and it compiles
your `filter_parameters` regexps against request parameter/header names. A
carelessly written, backtracking-heavy pattern could otherwise be driven into
catastrophic backtracking and pin a CPU (ReDoS).

Every such regexp is compiled with a per-match timeout (`config.regexp_timeout`,
default `1.0` second), so an over-budget match raises `Regexp::TimeoutError`
instead of hanging. This is scoped to Raxon's own regexps and does not change
the host application's global `Regexp.timeout`. Lower it to tighten the ceiling,
or set it to `nil` to disable.

Declaring `max_length` alongside `pattern:` is the cheaper defense, and Raxon
orders the two so it actually helps: length is checked first, and a value that
fails it is rejected without the regexp ever running against it. A hostile
100 KB subject costs a length comparison rather than a timeout's worth of
backtracking.

```ruby
# The regexp never sees a value longer than 64 characters.
property :slug, type: :string, max_length: 64, pattern: '\A[a-z0-9-]+\z'
```

Anchor deliberately. A declared `pattern:` is a **search, not a full-string
match** — on both the OpenAPI side and in Raxon's validation, which is
consistent but easy to misread. `pattern: "[A-Z]+"` accepts `"xxABCxx"`; use
`\A` and `\z` when you mean the whole string.

## Security-scheme data is public

Security schemes declared with `Raxon::OpenApi::DSL.security_scheme` are emitted
into the generated `api.json` and HTML, which are public API documentation.
Everything you pass as scheme fields — including OAuth2 `flows` — is published.
**Never put a secret (client secret, token, password) in a scheme.** Runtime
credentials belong only inside the authenticator block (which is never
serialized) or a secret store.

As a guardrail, `flows` is validated against the OpenAPI structure: only the
standard flow names (`authorizationCode`, `implicit`, `password`,
`clientCredentials`) and fields (`authorizationUrl`, `tokenUrl`, `refreshUrl`,
`scopes`) are allowed, and scheme fields are checked against the scheme type, so
a stray `client_secret` (or a field on the wrong scheme type) raises at
declaration rather than leaking into the document.

## File uploads

`Raxon::UploadedFile` validates the *structure* of an upload (that a file part
with a non-empty name is present) plus whatever size and extension limits you
declare. Its `original_filename`, `content_type`, and `headers` are supplied by
the client and are **entirely untrusted** — a `.jpg` name or an `image/jpeg`
type is no proof of the actual bytes.

Declare limits in the schema so they are enforced before your handler runs:

```ruby
endpoint.request_body type: :multipart, max_total_size: 20 * 1024 * 1024 do |body|
  body.property :avatar, type: :file, max_size: 2 * 1024 * 1024,
    allowed_extensions: %w[jpg jpeg png]
end
```

Size violations answer `413`; a disallowed extension answers `422`. See
[File Uploads](file_uploads.md#declaring-upload-constraints).

These narrow what you accept — they do not establish that a file is what it
claims to be. `allowed_extensions` matches the client-supplied filename, so
renaming `shell.php` to `shell.jpg` defeats it. Both limits are also applied
*after* Rack has parsed the body and buffered parts to disk; `max_request_body_size`
is what bounds how much a client can make the server read.

So, when handling uploads:

- Store files under a **server-generated name** (e.g. a UUID), never the
  client's `original_filename` — otherwise a crafted name enables path
  traversal, overwrites, or executable filenames.
- Keep the storage location **outside any executable or static-served root.**
- Do not trust `content_type` or the filename extension for access-control or
  rendering decisions; sniff the real content (magic-byte/MIME signature)
  instead. Raxon does not do content sniffing for you.
- Run high-risk formats through isolated processing or malware scanning.

## Error handling and logging

`Raxon::Server` wraps the router in `Raxon::ErrorHandler` automatically
(`config.wrap_error_handler`, default `true`), so an unhandled exception returns
a fixed generic JSON 500 instead of leaking a backtrace to the app server's
default error page. Adding your own `ErrorHandler` with `use` replaces the
automatic one; set `config.wrap_error_handler = false` to opt out entirely. The
handler never discloses exception text over HTTP. Two things to be aware of on
the server side:

- **Log forging** — the exception message and request line can contain
  attacker-influenced CR/LF. Raxon sanitizes control characters out of what it
  logs, so a message cannot forge extra log records. If you log request context
  yourself, do the same and redact secrets with `Raxon::ParameterFilter`.
- **The `on_error` callback receives the raw Rack `env`**, which carries
  credentials (Authorization/Cookie/X-API-Key headers, the body stream). Raxon
  does not serialize `env` itself, but a callback that forwards data to an
  external tracker (Sentry, etc.) must filter first — send only the specific,
  scrubbed fields you need, not the whole `env`.

## Reverse-proxy headers

`X-Forwarded-For` is **not** trusted by default — `request.remote_ip` returns
the direct connection peer (`REMOTE_ADDR`), which a client cannot forge.

To honor forwarding headers behind a proxy, list the proxy addresses in
`config.trusted_proxies` as IP or CIDR strings:

```ruby
Raxon.configure { |c| c.trusted_proxies = ["10.0.0.0/8", "127.0.0.1"] }
```

`remote_ip` then walks the chain (`X-Forwarded-For` entries followed by
`REMOTE_ADDR`) from the right, discards every hop that is a trusted proxy, and
returns the first address that is not. This is robust whether the proxy appends
or overwrites the header, and a client cannot spoof its IP by prepending a fake
entry — the real client address, recorded by your innermost trusted proxy, sits
to the right of anything the client injected. Never trust the leftmost entry
directly. Leave `trusted_proxies` empty unless a proxy actually fronts the app.
