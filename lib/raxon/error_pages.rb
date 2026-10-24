# frozen_string_literal: true

module Raxon
  # Static HTML error pages for apps that serve browsers, like the
  # public/404.html and public/500.html pages of a Rails app.
  #
  # Set +config.error_pages_path+ to the directory of the pages. A request that
  # accepts text/html then gets +<status>.html+ from that directory. Other
  # requests, and statuses with no page, keep the JSON error.
  #
  # @example
  #   Raxon.configure { |config| config.error_pages_path = "public" }
  module ErrorPages
    module_function

    # The page for a status, when the request accepts HTML and the page exists.
    #
    # @param status [Integer]
    # @param env [Hash] Rack environment
    # @return [String, nil] the page HTML, or nil
    def page(status, env)
      directory = Raxon.configuration.error_pages_path
      return unless directory && html_request?(env)

      file = File.join(directory, "#{Integer(status)}.html")
      File.read(file) if File.file?(file)
    end

    # A Rack response for a status: the HTML page when there is one, otherwise
    # a JSON error with the status reason phrase.
    #
    # @param status [Integer]
    # @param env [Hash] Rack environment
    # @param headers [Hash] extra headers
    # @return [Array] Rack response triple
    def rack_response(status, env, headers = {})
      if (html = page(status, env))
        [status, {"content-type" => "text/html; charset=utf-8", **headers}, [html]]
      else
        [status, {"content-type" => "application/json", **headers}, [JSON.generate({error: reason(status)})]]
      end
    end

    # @param status [Integer]
    # @return [String] the reason phrase, for example "Not Found"
    def reason(status)
      Rack::Utils::HTTP_STATUS_CODES.fetch(Integer(status), "Error")
    end

    # @param env [Hash] Rack environment
    # @return [Boolean]
    def html_request?(env)
      Request.accepts?(env["HTTP_ACCEPT"], "text/html")
    end
  end
end
