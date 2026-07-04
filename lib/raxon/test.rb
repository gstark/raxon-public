# frozen_string_literal: true

require "raxon"

module Raxon
  # Test helpers for exercising Raxon applications without a running server.
  #
  # Not loaded by `require "raxon"`; require it from your test setup. RSpec
  # users should require "raxon/test/rspec" instead, which also defines the
  # +conform_to_response_schema+ matcher:
  #
  #   # spec_helper.rb
  #   require "raxon/test/rspec"
  #
  #   RSpec.configure do |config|
  #     config.include Raxon::Test::Methods
  #   end
  #
  # Then drive endpoints directly in specs:
  #
  #   it "returns the user" do
  #     get "/api/v1/users/42", headers: {"X-API-Key" => "secret"}
  #
  #     expect(last_response.status).to eq(200)
  #     expect(last_response.json).to eq({"id" => 42})
  #     expect(last_response).to conform_to_response_schema(200)
  #   end
  module Test
    # The result of a test request: status, headers, and a fully-read body.
    class Response
      attr_reader :status, :headers, :request_method, :request_path

      # @param rack_response [Array] Rack response tuple [status, headers, body]
      # @param request_method [String] The HTTP method of the originating request
      # @param request_path [String] The path (without query string) of the originating request
      def initialize(rack_response, request_method:, request_path:)
        @status, @headers, body = rack_response
        chunks = []
        body.each { |chunk| chunks << chunk }
        body.close if body.respond_to?(:close)
        @body = chunks.join
        @request_method = request_method
        @request_path = request_path
      end

      # The response body as a String.
      #
      # @return [String]
      attr_reader :body

      # The response body parsed as JSON.
      #
      # @param symbolize_names [Boolean] Parse object keys as symbols
      # @return [Object]
      def json(symbolize_names: false)
        JSON.parse(body, symbolize_names: symbolize_names)
      end

      # Fetch a response header, case-insensitively.
      #
      # @param name [String] Header name
      # @return [String, nil]
      def [](name)
        headers[name.downcase]
      end
    end

    # Request helpers mixed into test contexts.
    module Methods
      # The Rack application under test. Defaults to a Raxon::Server built from
      # the loaded routes; override in your test context to customize.
      #
      # @return [#call]
      def app
        @raxon_test_app ||= Raxon::Server.new
      end

      # The response to the most recent request.
      #
      # @return [Raxon::Test::Response]
      def last_response
        @last_response || raise(Raxon::Error, "No request has been made yet")
      end

      %w[get post put patch delete head options].each do |verb|
        # @param path [String] Request path, may include a query string
        # @param params [Hash, nil] Query params (GET/HEAD) or form params (POST/PUT/PATCH)
        # @param headers [Hash] Request headers ("X-API-Key" and "HTTP_X_API_KEY" forms both work)
        # @param json [Object, nil] Body serialized as JSON with an application/json content type
        # @param body [String, nil] Raw request body
        # @return [Raxon::Test::Response]
        define_method(verb) do |path, params: nil, headers: {}, json: nil, body: nil|
          perform_request(verb.upcase, path, params: params, headers: headers, json: json, body: body)
        end
      end

      private

      def perform_request(method, path, params:, headers:, json:, body:)
        options = {method: method}

        if json
          options[:input] = JSON.generate(json)
          options["CONTENT_TYPE"] = "application/json"
        elsif body
          options[:input] = body
        end

        if params
          if options.key?(:input)
            path = append_query(path, params)
          else
            options[:params] = params
          end
        end

        headers.each { |name, value| options[normalize_header_key(name)] = value }

        env = Rack::MockRequest.env_for(path, options)
        @last_response = Response.new(
          app.call(env),
          request_method: env["REQUEST_METHOD"],
          request_path: env["PATH_INFO"]
        )
      end

      def append_query(path, params)
        separator = path.include?("?") ? "&" : "?"
        "#{path}#{separator}#{Rack::Utils.build_nested_query(params)}"
      end

      def normalize_header_key(name)
        key = name.to_s
        return key if key.start_with?("HTTP_")

        normalized = key.upcase.tr("-", "_")
        %w[CONTENT_TYPE CONTENT_LENGTH].include?(normalized) ? normalized : "HTTP_#{normalized}"
      end
    end

    # Define the conform_to_response_schema RSpec matcher. Called by requiring
    # "raxon/test/rspec"; RSpec must already be loaded.
    #
    # @return [void]
    def self.define_rspec_matchers
      ::RSpec::Matchers.define :conform_to_response_schema do |expected_status = nil|
        match do |response|
          @schema_failure = nil

          if expected_status && response.status != expected_status
            @schema_failure = "expected status #{expected_status}, got #{response.status} (body: #{response.body})"
            next false
          end

          route = Raxon::RouteLoader.routes.find(response.request_method, response.request_path)
          unless route
            @schema_failure = "no route matches #{response.request_method} #{response.request_path}"
            next false
          end

          endpoint = route[:endpoint]
          schema = endpoint.response_schemas[response.status]
          unless schema
            @schema_failure = "#{endpoint.path} declares no response schema for status #{response.status}"
            next false
          end

          parsed = begin
            response.json
          rescue JSON::ParserError
            @schema_failure = "response body is not valid JSON: #{response.body.inspect}"
            next false
          end

          result = schema.call(parsed)
          unless result.success?
            @schema_failure = "response body does not conform to the declared schema for status #{response.status}: #{result.errors.to_h.inspect}"
          end
          result.success?
        end

        failure_message { @schema_failure }
      end
    end
  end
end
