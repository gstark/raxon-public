# frozen_string_literal: true

require_relative "column_mapper"
require_relative "component"
require_relative "document_builder"
require_relative "endpoint"
require_relative "schema_introspection"
require_relative "security_scheme"

module Raxon
  module OpenApi
    # A collection of endpoints, components, and security schemes, and the
    # OpenAPI document they generate.
    #
    # This is the unit of state: {DSL} holds one default instance for the
    # application, but a Specification can be created directly to build an
    # isolated document (tests do this to avoid touching global state).
    #
    # @example
    #   spec = Specification.new
    #   spec.component(:User, type: :object) { |c| c.property :name, type: :string }
    #   spec.endpoint do |e|
    #     e.path "/users"
    #     e.operation :get
    #     e.response 200, type: :array, of: :User
    #   end
    #   spec.to_open_api
    #
    class Specification
      attr_reader :endpoints, :components, :security_schemes

      def initialize
        @endpoints = []
        @components = []
        @security_schemes = {}
      end

      def reset!
        @endpoints.clear
        @components.clear
        @security_schemes.clear
      end

      # Drop every endpoint that came from a route file, keeping those declared
      # programmatically. Used by hot reloading, where route files re-register
      # as they load and the previous generation would otherwise accumulate as
      # duplicate operations in the generated document.
      #
      # Replaces the array rather than mutating it in place: a reader that has
      # already taken `endpoints` (document generation walking the list) keeps
      # iterating a complete, if stale, snapshot instead of having entries
      # removed underneath it.
      #
      # @return [Array<Endpoint>] the retained endpoints
      def drop_route_file_endpoints!
        @endpoints = @endpoints.reject(&:route_file_path)
      end

      # Define a reusable security scheme, emitted under components.securitySchemes
      # and referenced from endpoints via endpoint.security. An optional block
      # makes the scheme enforceable at runtime (see SecurityScheme).
      #
      # @param name [Symbol, String] Registry name for endpoint.security references
      # @param options [Hash] Scheme fields (type:, name:, in:, scheme:, ...)
      # @return [SecurityScheme]
      def security_scheme(name, **options, &authenticator)
        scheme = SecurityScheme.new(name, **options, &authenticator)
        @security_schemes[scheme.name] = scheme
        scheme
      end

      # Define a reusable OpenAPI component schema.
      #
      # @param name [Symbol, String] The component name
      # @param options [Hash] Component configuration options
      # @yield [Component] The component object for configuration
      # @return [Component]
      def component(name, options, &block)
        component = Component.new(name, **options)
        @components << component
        yield component if block_given?
        component
      end

      # Define an API endpoint with operations and responses.
      #
      # @yield [Endpoint] The endpoint object for configuration
      # @return [Endpoint]
      def endpoint
        endpoint = Endpoint.new
        @endpoints << endpoint
        yield endpoint if block_given?
        endpoint
      end

      # Generate a component schema from an Alba resource and a model class.
      #
      # Automatically introspects the resource attributes and database schema
      # to generate appropriate OpenAPI component definitions with correct types,
      # descriptions, and validation constraints. Introspection goes through
      # SchemaIntrospection, so any supported persistence library (or a
      # configured adapter) works; with none available, only block-declared
      # properties are emitted.
      #
      # @param name [Symbol, String] The component name
      # @param resource [Alba::Resource] The Alba resource class
      # @param model [Class] The model class (e.g. an ActiveRecord model)
      # @yield [Component] The component object for additional configuration
      # @return [Component]
      def from_resource(name, resource, model, &block)
        columns = SchemaIntrospection.model_columns(model)
        build_from_attributes(name, resource, columns, enum_source: model, &block)
      end

      # Generate a component schema from an Alba resource and a database table.
      #
      # Sibling to {#from_resource} for tables that have no model class (e.g.
      # tables owned by a ROM relation). Unlike from_resource, inclusion
      # validators cannot be introspected (there is no model class), so
      # enum-like properties must be declared in the block via allowable_values.
      #
      # @param name [Symbol, String] The component name
      # @param resource [Alba::Resource] The Alba resource class
      # @param table_name [Symbol, String] The database table name
      # @yield [Component] The component object for additional configuration
      # @return [Component]
      def from_table(name, resource, table_name, &block)
        columns = SchemaIntrospection.table_columns(table_name)
        build_from_attributes(name, resource, columns, &block)
      end

      # Generate the complete OpenAPI document for this specification.
      #
      # @return [Hash] Complete OpenAPI document with string keys
      def to_open_api
        DocumentBuilder.new(self).build
      end

      private

      # Shared body of from_resource/from_table: block-declared properties
      # first, then Alba attributes resolved against the introspected columns
      # (nil when no database/adapter is available).
      def build_from_attributes(name, resource, columns, enum_source: nil)
        component(name, type: :object) do |component|
          yield component if block_given?

          resource._attributes.each do |attribute_name, definition|
            next if component.properties.key?(attribute_name.to_sym)

            if definition.is_a?(Alba::Association)
              ColumnMapper.build_association_property(component, attribute_name, definition)
            elsif definition.is_a?(Symbol) && columns
              column = columns[attribute_name.to_s]
              next if column.nil?

              allowable_values = enum_source ? SchemaIntrospection.enum_values(enum_source, attribute_name) : nil
              ColumnMapper.build_column_property(component, attribute_name, column, allowable_values: allowable_values)
            end
          end
        end
      end
    end
  end
end
