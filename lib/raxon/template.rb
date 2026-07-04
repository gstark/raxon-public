# frozen_string_literal: true

require "erubi"

module Raxon
  # Compiled HTML template with automatic output escaping.
  #
  # Wraps Erubi with +escape: true+ so that +<%= value %>+ is HTML-escaped by
  # default, preventing XSS when handler locals contain user-controlled data.
  # Use +<%== value %>+ (or +<%= raw(value) %>+ style pre-escaping) only for
  # values you have already deemed safe to emit as raw markup.
  #
  # Templates are compiled once (at route load time) and rendered per request
  # with a fresh set of locals.
  #
  # @example
  #   template = Raxon::Template.new("<h1><%= title %></h1>")
  #   template.render(title: "<script>")  # => "<h1>&lt;script&gt;</h1>"
  class Template
    # @param source [String] The raw ERB/Erubi template source
    def initialize(source)
      @src = ::Erubi::Engine.new(source, escape: true).src
    end

    # Render the template with the given local variables.
    #
    # Locals are injected as local variables into an isolated binding, so a
    # template referencing +title+ resolves to +locals[:title]+ and nothing in
    # the template can reach the surrounding framework scope.
    #
    # @param locals [Hash{Symbol => Object}] Local variables for the template
    # @return [String] The rendered, escaped HTML
    def render(locals = {})
      context = binding
      locals.each { |name, value| context.local_variable_set(name, value) }
      eval(@src, context) # standard:disable Security/Eval -- @src is compiled from a developer-authored template file, never request input
    end
  end
end
