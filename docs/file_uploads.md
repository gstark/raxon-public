# File Uploads

This document explains how to handle file uploads in Raxon endpoints.

## Overview

Raxon provides native file upload support through the `:file` property type and `Raxon::UploadedFile` wrapper. When you declare a request body property as `type: :file`, Raxon automatically wraps the raw Rack multipart hash into a `Raxon::UploadedFile` object before your handler receives it.

## Basic Usage

Declare file properties in your request body, then access them directly in the handler:

```ruby
# routes/api/v1/photos/post.rb
Raxon::RouteLoader.register(__FILE__) do |endpoint|
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
| `original_filename` | The uploaded file's name (e.g., `"photo.jpg"`) |
| `content_type` | The MIME type (e.g., `"image/jpeg"`) |
| `tempfile` | The underlying `Tempfile` object |
| `headers` | The multipart headers string |

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
3. After validation, `Request#coerce_file_params` wraps any Hash-valued file params in `Raxon::UploadedFile`
4. The handler receives `Raxon::UploadedFile` objects ready to use

Values that are already `Raxon::UploadedFile` instances (not Hashes) are left untouched.
