# frozen_string_literal: true

module Raxon
  module SqlJson
    # SQL functions for the blocks a declaration passes: `expression:` on a
    # pluck, `attribute`, and `order`. Resource extends this module, and those
    # blocks are written in the class body, so they call the functions without
    # a receiver:
    #
    #   pluck :names, from: :employees,
    #     expression: ->(employees) { concat(employees[:first_name], " ", employees[:last_name]) }
    #
    # Each function returns an Arel node. An argument that is not already an
    # Arel node or attribute becomes a quoted SQL literal, so `" "` is the
    # string `' '`, never raw SQL.
    module Functions
      # Postgres `concat(...)`: the arguments joined as text. A NULL argument
      # adds nothing, as `nil` does in Ruby string interpolation. (The `||`
      # operator would make the whole result NULL instead.)
      #
      # @param parts [Array<Arel::Attributes::Attribute, Arel::Nodes::Node, Object>]
      # @return [Arel::Nodes::NamedFunction]
      def concat(*parts) = Arel::Nodes::NamedFunction.new("concat", parts.map { sql_value(it) })

      private

      # @param value [Object]
      # @return [Arel::Nodes::Node, Arel::Attributes::Attribute] the value as is
      #   when it is already Arel, else a quoted literal
      def sql_value(value)
        (value.is_a?(Arel::Nodes::Node) || value.is_a?(Arel::Attributes::Attribute)) ? value : Arel::Nodes.build_quoted(value)
      end
    end
  end
end
