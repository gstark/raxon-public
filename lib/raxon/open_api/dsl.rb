# frozen_string_literal: true

require_relative "column_mapper"
require_relative "document_builder"
require_relative "parameter"
require_relative "parameters"
require_relative "property"
require_relative "request_body"
require_relative "response"
require_relative "schema_emitter"
require_relative "spec_version"
require_relative "specification"
require_relative "type_system"

module Raxon
  module OpenApi
    # Entry point for the OpenAPI DSL: the application-wide {Specification}.
    #
    # Route files and initializers declare against this default specification;
    # every method here delegates to it. The work itself lives elsewhere —
    # {Specification} holds state, {DocumentBuilder} assembles the document,
    # {SchemaEmitter} renders schemas, {TypeSystem} validates declarations, and
    # {ColumnMapper} maps database columns.
    #
    # @example Basic usage
    #   OpenApi::DSL.component(:User, type: :object) do |component|
    #     component.property :name, type: :string
    #     component.property :email, type: :string
    #   end
    #
    #   OpenApi::DSL.endpoint do |e|
    #     e.path "/users"
    #     e.operation :get
    #     e.response 200, type: :array, of: :User
    #   end
    #
    # @example Resource-based component generation
    #   OpenApi::DSL.from_resource(:User, UserResource, User)
    #
    class DSL
      class << self
        attr_writer :default_spec

        # The application-wide specification every DSL call registers against.
        #
        # @return [Specification]
        def default_spec
          @default_spec ||= Specification.new
        end

        # Discard all declared endpoints, components, and security schemes.
        def reset!
          @default_spec = Specification.new
        end

        def endpoints
          default_spec.endpoints
        end

        def components
          default_spec.components
        end

        def security_schemes
          default_spec.security_schemes
        end

        # @see Specification#security_scheme
        def security_scheme(name, **options, &authenticator)
          default_spec.security_scheme(name, **options, &authenticator)
        end

        # @see Specification#component
        def component(name, options, &block)
          default_spec.component(name, options, &block)
        end

        # @see Specification#endpoint
        def endpoint(&block)
          default_spec.endpoint(&block)
        end

        # @see Specification#from_resource
        def from_resource(name, resource, model, &block)
          default_spec.from_resource(name, resource, model, &block)
        end

        # @see Specification#from_table
        def from_table(name, resource, table_name, &block)
          default_spec.from_table(name, resource, table_name, &block)
        end

        # @see Specification#to_open_api
        def to_open_api
          default_spec.to_open_api
        end
      end
    end
  end
end
