# File Uploads

This document explains how to handle file uploads in Raxon endpoints.

## Overview

Raxon provides native file upload support through the `:file` property type and `Raxon::UploadedFile` wrapper. When you declare a request body property as `type: :file`, Raxon automatically wraps the raw Rack multipart hash into a `Raxon::UploadedFile` object before your handler receives it.

**Uploads are declared in the request body, never as a parameter.** `type: :file`
(and `type: :multipart`) on a `params.define` / `query_param` / `header_param` /
`cookie_param` declaration raises `Raxon::OpenApi::Error` at load time:

```ruby
endpoint.parameters { |params| params.define :photo, type: :file }
# => Raxon::OpenApi::Error: type: :file is not valid for a parameter (photo).
#    Declare uploads in the request body: …
```

Parameters are serialized into a URL, header, or cookie, and OpenAPI defines no
serialization for binary data in any of those — so a file parameter cannot be
described in the generated document, and validation and `UploadedFile` wrapping
both run off the request body. The declaration is rejected rather than silently
delivering a raw Rack hash.

## Basic Usage

Declare file properties in your request body, then access them directly in the handler:

```ruby
# routes/api/v1/photos/post.rb
Raxon.route do |endpoint|
  endpoint.description "Upload a photo"

  endpoint.request_body type: :multipart do |body|
    body.property :photo, type: :file, required: true
    body.property :caption, type: :string, required: false
  end

  endpoint.response 201, type: :object do |response|
    response.property :filename, type: :string
    response.property :content_type, type: :string
  end

  endpoint.handler do |request, response, metadata|
    photo = request.params[:photo]

    # photo is a Raxon::UploadedFile — no conversion needed
    response.code = :created
    response.body = {
      filename: photo.original_filename,
      content_type: photo.content_type
    }
  end
end
```

## `Raxon::UploadedFile`

The wrapper duck-types `ActionDispatch::Http::UploadedFile`, so downstream code that expects that interface (ActiveStorage, image processing libraries, etc.) works without changes.

### Attributes

| Method | Description |
|--------|-------------|
| `original_filename` | The uploaded file's name (e.g., `"photo.jpg"`) — **client-supplied, untrusted** |
| `content_type` | The MIME type (e.g., `"image/jpeg"`) — **client-supplied, untrusted** |
| `tempfile` | The underlying `Tempfile` object |
| `headers` | The multipart headers string — **client-supplied, untrusted** |

> **Security:** `original_filename`, `content_type`, and `headers` come from the
> client and prove nothing about the actual bytes. Store uploads under a
> server-generated name (never `original_filename`) outside any executable/static
> root, don't trust `content_type` for access or rendering decisions, and
> validate the real content (extension allowlist + signature sniffing). See
> [Security](security.md#file-uploads).

## Declaring Upload Constraints

Size and extension limits are part of the schema, so they are enforced before
your handler runs and documented alongside everything else:

```ruby
endpoint.request_body type: :multipart, required: true, max_total_size: 20 * 1024 * 1024 do |body|
  body.property :avatar, type: :file, required: true,
    max_bytes: 2 * 1024 * 1024,
    content_types: %w[image/jpeg image/png],
    allowed_extensions: %w[jpg jpeg png]

  body.property :resume, type: :file, required: false,
    max_size: 5 * 1024 * 1024,
    allowed_extensions: %w[pdf]
end
```

| Option | Where | Effect |
|--------|-------|--------|
| `max_size` | file property | Maximum bytes for that one upload |
| `max_bytes` | file property | Preferred spelling for a per-file byte limit (`max_size` remains supported) |
| `content_types` | file property | Client-claimed MIME types accepted; case and optional MIME parameters are normalized |
| `max_total_size` | request body | Maximum combined bytes across every upload in the request |
| `allowed_extensions` | file property | Filename extensions accepted, without the leading dot |

Each failure gets the status that describes it:

| Outcome | Status |
|---------|--------|
| A part exceeds `max_bytes`/`max_size`, or the uploads exceed `max_total_size` | `413 Payload Too Large` |
| Filename extension outside `allowed_extensions`, or MIME outside `content_types` | `422 Unprocessable Entity` |
| Missing or mistyped field | `400 Bad Request` |

`413` matches what `config.max_request_body_size` returns for an oversized
request. `422` is the well-formed-but-unacceptable case: the request parsed
fine and carried a real file, the endpoint just will not take that kind. `400`
stays for a request that is malformed.

Errors are reported together regardless of status, so a request that is both
missing a required field and carrying a rejected upload lists both in
`details`; only the status differs, and a content rejection wins it.

`max_total_size` catches what a per-file limit cannot — several uploads that are
each within their own limit but too large together.

The byte limit is emitted as `x-max-bytes`; `content_types` is emitted as
`x-content-types`. `allowed_extensions` has no standard OpenAPI keyword and is
enforced at runtime only.

> **`allowed_extensions` is a usability check, not a security control.** It
> matches against the client-supplied filename, which proves nothing about the
> bytes — an attacker renames `shell.php` to `shell.jpg` and passes. It catches
> honest mistakes early and narrows what you accept; it does not replace
> validating actual content before you use or serve a file. Likewise, these
> limits are checked after Rack has parsed the request and buffered the parts to
> disk: `config.max_request_body_size` is what bounds how much a client can make
> the server read in the first place.

### Delegated IO Methods

These methods delegate directly to the `tempfile`:

| Method | Description |
|--------|-------------|
| `read` | Read file contents |
| `rewind` | Reset read position to beginning |
| `size` | File size in bytes |
| `eof?` | Whether read position is at end |
| `close` | Close the tempfile |
| `path` | Filesystem path to the tempfile |
| `to_io` | Returns the tempfile (for ActiveStorage compatibility) |

### Example: Reading File Contents

```ruby
endpoint.handler do |request, response, metadata|
  file = request.params[:document]

  contents = file.read
  file.rewind  # reset if you need to read again

  response.code = :ok
  response.body = { size: file.size, name: file.original_filename }
end
```

## Multiple File Fields

Declare each file as a separate property:

```ruby
endpoint.request_body type: :multipart do |body|
  body.property :avatar, type: :file, required: true
  body.property :cover_photo, type: :file, required: false
end

endpoint.handler do |request, response, metadata|
  avatar = request.params[:avatar]           # always present
  cover = request.params[:cover_photo]       # may be nil

  # process files...
end
```

## Optional Files

When a file property is `required: false`, it can be omitted from the request. Check for `nil` before using it:

```ruby
endpoint.handler do |request, response, metadata|
  attachment = request.params[:attachment]

  if attachment
    # process the file
  end
end
```

## How It Works

1. Rack parses the multipart request and produces a raw Hash (`{ tempfile: ..., filename: ..., type: ... }`)
2. The `RequestSchemaGenerator` validates that required file fields are present (without type coercion)
3. After validation, `RequestBodyCoercer` wraps declared file params in `Raxon::UploadedFile`, including nested file fields inside objects and arrays of objects
4. The handler receives `Raxon::UploadedFile` objects ready to use

Values that are already `Raxon::UploadedFile` instances are left untouched. Values declared as `type: :file` must be Rack multipart file hashes or `Raxon::UploadedFile` instances; invalid values fail request validation.
