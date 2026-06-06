# frozen_string_literal: true

require "tty-table"

module Raxon
  class RoutesFormatter
    def self.display
      new.display
    end

    def display
      # Load routes
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      routes = Raxon::RouteLoader.routes

      if routes.empty?
        puts "No routes found"
        return
      end

      display_table(routes)
      display_summary(routes)
    end

    private

    def display_table(routes)
      headers = ["Path", "Method", "Before", "Handler", "Description", "File"]
      rows = sorted_routes(routes).map do |key, route_data|
        method = key[:method].upcase
        endpoint = route_data[:endpoint]

        before_indicator = endpoint.has_before? ? "✓" : "-"
        handler_indicator = endpoint.has_handler? ? "✓" : "-"
        file_path = relative_file_path(endpoint.route_file_path)
        description = truncate_text(endpoint.description || "(no description)", 30)

        [
          endpoint.path,
          method,
          before_indicator,
          handler_indicator,
          description,
          file_path
        ]
      end

      table = TTY::Table.new(header: headers, rows: rows)

      # Configure rendering options based on output type.
      render_options = {padding: [0, 1]}
      if $stdout.respond_to?(:tty?) && $stdout.tty?
        # For real TTY, enable auto-resizing.
        render_options[:resize] = true
      else
        # For non-TTY (like StringIO in tests), use an explicit width to avoid
        # ioctl and keep the table horizontal without TTY::Table warning and
        # rotating wide tables to vertical orientation.
        render_options[:width] = [120, table_width(headers, rows)].max
      end

      puts table.render(:unicode, render_options)
    end

    def table_width(headers, rows)
      column_widths = headers.each_index.map do |index|
        ([headers[index]] + rows.map { |row| row[index] }).map { |value| value.to_s.length }.max
      end

      padding_width = 2 * headers.length
      border_width = headers.length + 1

      column_widths.sum + padding_width + border_width
    end

    def display_summary(routes)
      puts "\nTotal routes: #{routes.size}"
    end

    def sorted_routes(routes)
      routes.sort_by { |key, _|
        [key[:path].count("/"), key[:path], key[:method]]
      }
    end

    def relative_file_path(absolute_path)
      return "" if absolute_path.nil?

      expanded_file_path = File.expand_path(absolute_path)
      routes_directory = Array(Raxon.configuration.routes_directory).compact.find do |directory|
        expanded_routes_dir = File.expand_path(directory)
        expanded_file_path.start_with?(expanded_routes_dir + File::SEPARATOR)
      end

      return absolute_path unless routes_directory

      expanded_routes_dir = File.expand_path(routes_directory)
      relative_path = expanded_file_path.sub(/^#{Regexp.escape(expanded_routes_dir)}\//, "")
      "./#{relative_path}"
    end

    def truncate_text(text, max_length)
      return text if text.length <= max_length

      "#{text[0...max_length - 3]}..."
    end
  end
end
