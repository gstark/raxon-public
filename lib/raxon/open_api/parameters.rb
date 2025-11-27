# frozen_string_literal: true

module Raxon
  module OpenApi
    # Container for endpoint parameters.
    #
    # Manages a collection of Parameter objects that define the input
    # parameters for an API endpoint (query, path, header, etc.).
    #
    # @example
    #   parameters = Parameters.new
    #   parameters.define :id, type: :string, in: :path
    #   parameters.define :limit, type: :number, in: :query, required: false
    #
    class Parameters
      attr_reader :parameters

      # Initialize an empty parameters collection.
      def initialize
        @parameters = []
      end

      # Define a new parameter for the endpoint.
      #
      # @param name [Symbol, String] The parameter name
      # @param options [Hash] Parameter configuration options
      #
      # @example
      #   define :user_id, type: :string, in: :path, description: "User identifier"
      #   define :page, type: :number, in: :query, required: false, description: "Page number"
      def define(name, options, &block)
        parameter = Parameter.new(name, **options)
        yield parameter if block_given?
        @parameters << parameter
      end
    end
  end
end
