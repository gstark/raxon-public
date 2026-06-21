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

    def self.valid_upload?(value)
      !normalize(value).nil?
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
