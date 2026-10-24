# frozen_string_literal: true

module Raxon
  # A String that is already safe to emit as HTML.
  #
  # Templates escape every +<%= %>+ value unless the value answers
  # +html_safe?+ with true. Rendered templates, partials, and captured blocks
  # come back as a SafeString, so inserting one into another template does not
  # escape it a second time. Helpers that build markup wrap it with
  # {ViewContext#raw}.
  #
  # The check is by duck type, so ActiveSupport::SafeBuffer counts as safe too.
  #
  # @example
  #   Raxon::SafeString.new("<b>bold</b>").html_safe?  # => true
  class SafeString < ::String
    # @return [Boolean] always true
    def html_safe?
      true
    end

    # @return [SafeString] self, so +to_s+ does not drop the safe marker
    def to_s
      self
    end

    # Join another value and keep the safe marker, as ActiveSupport::SafeBuffer
    # does. The other value is escaped unless it is safe.
    #
    # @param other [Object]
    # @return [SafeString]
    def +(other)
      SafeString.new(super(SafeString.escape(other)))
    end

    # Escape a value unless it is already safe.
    #
    # @param value [Object]
    # @return [SafeString]
    def self.escape(value)
      return value if value.is_a?(SafeString)
      return new(value.to_s) if value.respond_to?(:html_safe?) && value.html_safe?

      new(::Erubi.h(value))
    end
  end
end
