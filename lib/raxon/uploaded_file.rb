# frozen_string_literal: true

require "forwardable"

module Raxon
  # Wraps a Rack multipart file hash to provide the same interface
  # as ActionDispatch::Http::UploadedFile.
  #
  # Downstream code that expects UploadedFile duck-typing
  # (e.g., ActiveStorage, image processing) works transparently.
  #
  # SECURITY: +original_filename+, +content_type+, and +headers+ are supplied by
  # the client and are entirely untrusted — a `.jpg` name or `image/jpeg` type
  # is no proof of the actual bytes. Do not store an upload under its
  # +original_filename+ (path traversal, overwrites, executable names) and do
  # not trust +content_type+ for access-control or rendering decisions. Store
  # under a server-generated name outside any executable/static root, enforce
  # per-file/aggregate size limits, and validate the real content (extension
  # allowlist + signature/MIME sniffing) before use. See docs/security.md.
  #
  # @example
  #   file = Raxon::UploadedFile.new(rack_file_hash)
  #   file.original_filename  # => "photo.jpg"  (untrusted)
  #   file.content_type       # => "image/jpeg" (untrusted)
  #   file.tempfile.path      # => "/tmp/RackMultipart..."
  class UploadedFile
    extend Forwardable

    attr_reader :tempfile, :original_filename, :content_type, :headers

    def_delegators :tempfile, :read, :rewind, :size, :eof?, :close, :path

    def self.rack_file_hash?(value)
      return false unless value.is_a?(Hash)

      tempfile = value[:tempfile] || value["tempfile"]
      filename = value[:filename] || value["filename"]
      tempfile.respond_to?(:read) && tempfile.respond_to?(:rewind) && !!filename && !filename.to_s.empty?
    end

    def self.normalize(value)
      return value if value.is_a?(self)
      return nil unless rack_file_hash?(value)

      new(value)
    end

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
