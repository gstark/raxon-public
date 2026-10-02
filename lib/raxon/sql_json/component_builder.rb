# frozen_string_literal: true

module Raxon
  module SqlJson
    # Declares a Resource's attributes as properties of an OpenAPI component,
    # so a SqlJson route needs no Alba resource to be documented. Called by
    # Resource.document, which Raxon::OpenApi::DSL.from_sql_json calls.
    #
    # Each attribute becomes the property its JSON value matches:
    #
    #   columns          the column's type, nullability, comment, and enum, as
    #                    from_resource maps it (OpenApi::ColumnMapper)
    #   json_column      untyped
    #   attribute        untyped; declare the type in the from_sql_json block
    #   constant         the type of the Ruby value
    #   pluck column:    array of the column's type; untyped items when the
    #                    column is nullable, since an item can then be null
    #   pluck expression untyped array
    #   has_many         array of the nested resource's component
    #   has_one          nullable object of the nested resource's component
    #
    # A nested resource with no component of its own has its properties
    # inlined. Attributes inside a `branch` are not required, because a
    # request can leave them out. Without a database the column types are
    # unknown, and columns become untyped properties so that validation still
    # accepts their keys.
    module ComponentBuilder
      module_function

      # @param container [OpenApi::Component, OpenApi::Property] receives the properties
      # @param resource [Class<Resource>]
      # @return [void]
      def build(container, resource)
        columns = OpenApi::SchemaIntrospection.model_columns(resource.model_class)
        resource.attributes.each do |attribute|
          next if container.properties.key?(attribute.name.to_sym)

          options = options_for(attribute, resource.model_class, columns).merge(required: attribute.branch.nil?)
          container.property(attribute.name, options, &inline_block(attribute))
        end
      end

      def options_for(attribute, model, columns)
        case attribute
        when Resource::Column then column_options(model, attribute.name, columns)
        when Resource::Constant then constant_options(attribute.value)
        when Resource::Pluck then pluck_options(attribute)
        when Resource::Nested then nested_options(attribute)
        else {}
        end
      end

      def column_options(model, name, columns)
        column = columns&.[](name.to_s)
        return {} unless column

        enum = OpenApi::SchemaIntrospection.enum_values(model, name)
        options = OpenApi::ColumnMapper.build_property_options(column.sql_type, column.array, column.comment.to_s, column.null, enum)
        options[:read_only] = true if OpenApi::ColumnMapper::READ_ONLY_COLUMNS.include?(name.to_s)
        options
      end

      def constant_options(value)
        case value
        when String then {type: :string}
        when Integer then {type: :integer}
        when Float, BigDecimal then {type: :number}
        when true, false then {type: :boolean}
        when Array then {type: :array}
        when Hash then {type: :object}
        else {}
        end
      end

      def pluck_options(pluck)
        return {type: :array} if pluck.expression

        column = OpenApi::SchemaIntrospection.model_columns(pluck.target.klass)&.[](pluck.column.to_s)
        return {type: :array} if column.nil? || column.null

        {type: :array, of: OpenApi::ColumnMapper.openapi_element_for_sql_type(column.sql_type)}
      end

      def nested_options(nested)
        name = nested.resource.component_name
        if nested.many
          name ? {type: :array, of: name} : {type: :array}
        else
          name ? {type: :object, as: name, nullable: true} : {type: :object, nullable: true}
        end
      end

      # The block that inlines a nested resource with no component of its own.
      def inline_block(attribute)
        return unless attribute.is_a?(Resource::Nested) && attribute.resource.component_name.nil?

        ->(property) { build(property, attribute.resource) }
      end
    end
  end
end
