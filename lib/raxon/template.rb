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
    # Names Binding#local_variable_set accepts but a parameter list does not.
    # A template cannot read a local with one of these names, so its value is
    # passed to a placeholder parameter and ignored, as it was before.
    KEYWORDS = %w[
      __ENCODING__ __FILE__ __LINE__ alias and begin break case class def do
      else elsif end ensure false for if in module next nil not or redo rescue
      retry return self super then true undef unless until when while yield
    ].to_set.freeze

    # @param source [String] The raw ERB/Erubi template source
    def initialize(source)
      @src = ::Erubi::Engine.new(source, escape: true).src
      @methods = {}
      @mutex = Mutex.new
      @scope = Class.new.new
    end

    # Render the template with the given local variables.
    #
    # Each distinct list of local names compiles the template into a method
    # whose parameters are those names, so a template referencing +title+
    # resolves to +locals[:title]+. Evaluating the source per render cost about
    # 16us; calling the compiled method costs about 1us. The method lives on an
    # object of its own, so nothing in the template can reach the surrounding
    # framework scope.
    #
    # @param locals [Hash{Symbol => Object}] Local variables for the template
    # @return [String] The rendered, escaped HTML
    def render(locals = {})
      names = locals.keys
      # :title and "title" name one local; the later value wins.
      if names.any?(String) && names.map(&:to_sym).uniq!
        locals = locals.transform_keys(&:to_sym)
        names = locals.keys
      end

      @scope.__send__(method_for(names), *locals.values)
    end

    private

    def method_for(names)
      @methods[names] || @mutex.synchronize { @methods[names] ||= compile(names) }
    end

    def compile(names)
      # Raises NameError for a name that cannot be a local variable, as
      # Binding#local_variable_set did when render used it.
      scratch = binding
      names.each { |name| scratch.local_variable_set(name, nil) }

      params = names.each_with_index.map do |name, index|
        KEYWORDS.include?(name.to_s) ? "_keyword#{index}" : name
      end

      method_name = :"render_#{@methods.size}"
      @scope.singleton_class.class_eval(<<~RUBY, __FILE__, __LINE__ + 1) # standard:disable Security/Eval -- @src is compiled from a developer-authored template file, never request input
        def #{method_name}(#{params.join(", ")})
          #{@src}
        end
      RUBY
      method_name
    end
  end
end
