# frozen_string_literal: true

module Raxon
  # The object a template renders on.
  #
  # One context serves one render: the template, every partial it renders,
  # and the layout. That is how +content_for+ in a template reaches +yield+ in
  # the layout. The context includes {ViewHelpers}, so application helpers
  # are methods here.
  #
  # @example A template that uses the context
  #   <% content_for :title do %>Books<% end %>
  #   <%= render "books/book", book: book %>
  #   <%= request.path %>
  class ViewContext
    include ViewHelpers

    # @return [Raxon::Request, nil] The request being rendered for
    attr_reader :request

    # @return [Raxon::Response, nil] The response being rendered into
    attr_reader :response

    # @param view [View, nil] Finds partials. Without one, {#render} raises.
    # @param request [Raxon::Request, nil]
    # @param response [Raxon::Response, nil]
    def initialize(view: nil, request: nil, response: nil)
      @view = view
      @request = request
      @response = response
      @content_for = {}
    end

    # Render a partial on this context.
    #
    # The partial file name starts with an underscore: +"books/book"+ renders
    # +books/_book.html.erb+ under +config.views_path+. A block given here is
    # what +yield+ in the partial returns, as captured output.
    #
    # @param name [String] Partial name, relative to the views path
    # @param locals [Hash{Symbol => Object}] Local variables for the partial
    # @return [SafeString]
    # @raise [Raxon::Error] when no views path is configured or the partial is missing
    def render(name, **locals, &block)
      raise Raxon::Error, "Cannot render partial #{name.inspect}: config.views_path is not set" unless @view

      template = @view.partial(name)
      return template.render(locals, self) unless block

      template.render(locals, self) { |*args| capture(*args, &block) }
    end

    # Store content for the layout, or read it.
    #
    # With a block or a value, appends to the named content and returns nil.
    # With neither, returns what was stored, or nil.
    #
    # @param name [Symbol, String]
    # @param content [String, nil] Escaped unless it is already safe
    # @return [SafeString, nil]
    def content_for(name, content = nil, &block)
      key = name.to_sym
      content = capture(&block) if block
      return @content_for[key] if content.nil?

      @content_for[key] = SafeString.new(@content_for.fetch(key, "") + SafeString.escape(content))
      nil
    end

    # @param name [Symbol, String]
    # @return [Boolean] whether any content was stored for +name+
    def content_for?(name)
      @content_for.key?(name.to_sym)
    end

    # Run a block and return what it appended to the template output.
    #
    # When the block appends nothing and returns a String, that String is the
    # result, escaped unless it is already safe. So both of these work:
    #
    #   <% content_for :title do %>Books<% end %>
    #   <% content_for(:title) { "Books" } %>
    #
    # @param args [Array] Passed to the block
    # @return [SafeString]
    def capture(*args)
      value = nil
      buffer = instance_variable_get(Template::BUFFER)
      captured = if buffer
        buffer.capture { value = yield(*args) }
      else
        value = yield(*args)
        SafeString.new
      end
      return captured unless captured.empty?

      value.is_a?(String) ? SafeString.escape(value) : captured
    end

    # The CSRF token for a form or a script. Each call masks the token
    # differently, so the value changes, but every value is valid for the
    # session.
    #
    # @return [String]
    # @raise [Raxon::Error] when the context has no request, or no session
    def csrf_token
      raise Raxon::Error, "Cannot make a CSRF token without a request" unless request

      Rack::Protection::AuthenticityToken.token(request.session)
    end

    # The meta tags that Turbo and @rails/request.js read the CSRF token from.
    #
    # @return [SafeString]
    def csrf_meta_tags
      raw(%(<meta name="csrf-param" content="authenticity_token">\n<meta name="csrf-token" content="#{h(csrf_token)}">))
    end

    # Append a value to the template output, as +<%= %>+ does. A helper that
    # builds content in a block can call it once for each part.
    #
    # @param value [Object] Escaped unless it is already safe
    # @return [nil]
    # @raise [Raxon::Error] when no template is rendering
    def concat(value)
      buffer = instance_variable_get(Template::BUFFER) || raise(Raxon::Error, "Cannot concat outside a template")
      buffer | value
      nil
    end

    # Mark a value as safe HTML. It will not be escaped.
    #
    # @param value [Object]
    # @return [SafeString]
    def raw(value)
      SafeString.new(value.to_s)
    end

    # Escape a value for HTML, unless it is already safe.
    #
    # @param value [Object]
    # @return [SafeString]
    def h(value)
      SafeString.escape(value)
    end

    # Join values into one safe string. Each value is escaped unless it is
    # already safe.
    #
    # @param values [Array<Object>]
    # @param separator [String]
    # @return [SafeString]
    def safe_join(values, separator = "")
      SafeString.new(values.flatten.map { |value| SafeString.escape(value) }.join(SafeString.escape(separator)))
    end
  end
end
