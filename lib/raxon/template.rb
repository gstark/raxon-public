# frozen_string_literal: true

require "erubi"
require "erubi/capture_block"

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
  # A template renders on a {ViewContext}, so it can call {ViewHelpers}. A
  # value that answers +html_safe?+ with true (see {SafeString}) is not
  # escaped. A helper that takes a block can be called with +<%= %>+ and
  # capture the block's output (see {ViewContext#capture}).
  #
  # @example
  #   template = Raxon::Template.new("<h1><%= title %></h1>")
  #   template.render(title: "<script>")  # => "<h1>&lt;script&gt;</h1>"
  class Template
    # The output buffer. It escapes what +<%= %>+ appends unless the value is
    # already safe, and it can capture the output of a block.
    class Buffer < ::Erubi::CaptureBlockEngine::Buffer
      # @param other [Object]
      # @return [Buffer] self
      def |(other)
        if other.respond_to?(:html_safe?) && other.html_safe?
          concat(other.to_s)
        else
          concat(::Erubi.h(other))
        end
      end

      # @return [SafeString] the output the block appended to this buffer
      def capture(*)
        SafeString.new(super)
      end
    end

    # The instance variable that holds the output buffer while a template
    # renders. Helpers reach it to capture blocks.
    BUFFER = :@_raxon_buffer

    # Names Binding#local_variable_set accepts but a parameter list does not.
    # A template cannot read a local with one of these names, so its value is
    # passed to a placeholder parameter and ignored, as it was before.
    KEYWORDS = %w[
      __ENCODING__ __FILE__ __LINE__ alias and begin break case class def do
      else elsif end ensure false for if in module next nil not or redo rescue
      retry return self super then true undef unless until when while yield
    ].to_set.freeze

    # @param source [String] The raw ERB/Erubi template source
    # @param path [String, nil] File the source came from, for backtraces
    def initialize(source, path: nil)
      @src = ::Erubi::CaptureBlockEngine.new(
        source,
        escape: true,
        bufvar: BUFFER.to_s,
        bufval: "::Raxon::Template::Buffer.new"
      ).src
      @path = path || "(raxon template)"
      @methods = {}
      @mutex = Mutex.new
      @module = Module.new
    end

    # Render the template with the given local variables.
    #
    # Each distinct list of local names compiles the template into a method
    # whose parameters are those names, so a template referencing +title+
    # resolves to +locals[:title]+. Evaluating the source per render cost about
    # 16us; calling the compiled method costs about 1us. The method lives on a
    # module of its own and is bound to the context for one call, so nothing in
    # the template can reach the surrounding framework scope.
    #
    # The context keeps its own output buffer across the call. A template can
    # render a partial on the same context, and the partial's output does not
    # replace the caller's buffer.
    #
    # @param locals [Hash{Symbol => Object}] Local variables for the template
    # @param context [ViewContext, nil] Object the template renders on (positional, so +render(title: "x")+ still passes locals). A new
    #   one is made when nil.
    # @yield [*args] What +yield+ in the template calls. A layout yields here.
    # @return [SafeString] The rendered, escaped HTML
    def render(locals = {}, context = nil, &block)
      names = locals.keys
      # :title and "title" name one local; the later value wins.
      if names.any?(String) && names.map(&:to_sym).uniq!
        locals = locals.transform_keys(&:to_sym)
        names = locals.keys
      end

      context ||= ViewContext.new
      method = method_for(names)
      outer = context.instance_variable_get(BUFFER)
      begin
        SafeString.new(method.bind_call(context, *locals.values, &block))
      ensure
        context.instance_variable_set(BUFFER, outer)
      end
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
      # The template's own path and line 1 put template lines in backtraces.
      @module.module_eval(<<~RUBY, @path, 0) # standard:disable Security/Eval, Style/EvalWithLocation -- @src is compiled from a developer-authored template file, never request input
        def #{method_name}(#{params.join(", ")})
          #{@src}
        end
      RUBY
      @module.instance_method(method_name)
    end
  end
end
