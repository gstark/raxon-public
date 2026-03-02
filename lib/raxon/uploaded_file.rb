# frozen_string_literal: true

require "forwardable"

module Raxon
  # Wraps a Rack multipart file hash to provide the same interface
  # as ActionDispatch::Http::UploadedFile.
  #
  # Downstream code that expects UploadedFile duck-typing
  # (e.g., ActiveStorage, image processing) works transparently.
  #
  # @example
  #   file = Raxon::UploadedFile.new(rack_file_hash)
  #   file.original_filename  # => "photo.jpg"
  #   file.content_type       # => "image/jpeg"
  #   file.tempfile.path      # => "/tmp/RackMultipart..."
  class UploadedFile
    extend Forwardable

    attr_reader :tempfile, :original_filename, :content_type, :headers

    def_delegators :tempfile, :read, :rewind, :size, :eof?, :close, :path

    def initialize(hash)
      @tempfile = hash[:tempfile] || hash["tempfile"]
      @original_filename = hash[:filename] || hash["filename"]
      @content_type = hash[:type] || hash["type"]
      @headers = hash[:head] || hash["head"]
    end

    def to_io
      tempfile
    end
  end
end
