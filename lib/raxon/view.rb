# frozen_string_literal: true

module Raxon
  # Finds, compiles, and caches the templates under +config.views_path+, and
  # renders a template inside a layout.
  #
  # Names are relative to the views path and have no extension:
  # +"books/show"+ is +books/show.html.erb+. A partial name gets an underscore
  # before its last part: +"books/book"+ is +books/_book.html.erb+. A template
  # in another format names the format: +template("books/show", format: :md)+
  # is +books/show.md.erb+.
  #
  # A template compiles once. With +reload: true+ it compiles again when its
  # file changes.
  #
  # @example
  #   view = Raxon::View.new("app/views")
  #   view.render("books/show", locals: {book: book}, layout: "layouts/application")
  class View
    EXTENSION = ".html.erb"
    DEFAULT_FORMAT = "html"

    # @return [String] Absolute path of the views directory
    attr_reader :root

    # @param root [String] The views directory
    # @param reload [Boolean] Compile a template again when its file changes
    def initialize(root, reload: false)
      @root = File.expand_path(root)
      @roots = PathContainment.resolve_roots([@root])
      @reload = reload
      @templates = {}
      @mutex = Mutex.new
    end

    # Render a template, then the layout around it.
    #
    # The layout gets the same locals. In the layout, +yield+ returns the
    # template output and +yield :name+ returns the content stored with
    # +content_for :name+.
    #
    # @param name [String] Template name
    # @param locals [Hash{Symbol => Object}]
    # @param layout [String, nil] Layout name, or nil for no layout
    # @param context [ViewContext] Shared by the template, its partials, and the layout
    # @return [SafeString]
    def render(name, locals: {}, layout: nil, context: ViewContext.new(view: self))
      render_with_layout(template(name), locals: locals, layout: layout, context: context)
    end

    # Render a compiled template, then the layout around it. See {#render}.
    #
    # @param compiled [Template]
    # @return [SafeString]
    def render_with_layout(compiled, locals:, layout:, context:)
      body = compiled.render(locals, context)
      return body unless layout

      template(layout).render(locals, context) do |section = nil|
        section ? context.content_for(section) : body
      end
    end

    # @param name [String] Template name
    # @param format [String, Symbol] The format part of the file extension
    # @return [Template]
    # @raise [Raxon::Error] when the file is missing or outside the views path
    def template(name, format: DEFAULT_FORMAT)
      find(name.to_s, format)
    end

    # @param name [String] Partial name, without the underscore
    # @return [Template]
    # @raise [Raxon::Error] when the file is missing or outside the views path
    def partial(name)
      directory, base = File.split(name.to_s)
      find((directory == ".") ? "_#{base}" : File.join(directory, "_#{base}"))
    end

    private

    def find(name, format = DEFAULT_FORMAT)
      file = File.expand_path("#{name}.#{format}.erb", @root)
      cached = @templates[file]
      return cached[:template] if cached && !(@reload && stale?(cached))

      @mutex.synchronize { @templates[file] = compile(name, file) }[:template]
    end

    def stale?(cached)
      !File.file?(cached[:file]) || File.mtime(cached[:file]) != cached[:mtime]
    end

    def compile(name, file)
      unless file.start_with?(@root + File::SEPARATOR) && File.file?(file)
        raise Raxon::Error, "Template not found: #{name} (looked for #{file})"
      end

      unless PathContainment.contained?(file, @roots)
        raise Raxon::Error, "Refusing to load template outside views_path: #{file} " \
                            "(it resolves outside the configured views tree — check for a symlink)."
      end

      {file: file, mtime: File.mtime(file), template: Template.new(File.read(file), path: file)}
    end
  end
end
