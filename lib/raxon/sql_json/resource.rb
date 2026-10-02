# frozen_string_literal: true

module Raxon
  module SqlJson
    # Declares a JSON array of objects that Postgres builds in one query.
    #
    # == Purpose
    #
    # A list endpoint that loads records, preloads their associations, walks
    # them through a serializer, and encodes the result spends most of its
    # time and memory on Ruby objects that exist only to be turned back into
    # text. This class moves that work into Postgres. A subclass names a
    # model, lists the attributes each object carries, and gets back `json`:
    # the finished array as text. The app makes one round trip and allocates
    # one String, no matter how many rows or associations the body covers.
    #
    # The declaration reads like an Alba resource on purpose, so the two can
    # sit side by side and a reader can check them against each other.
    #
    # == A declaration and the SQL it becomes
    #
    #   class CatalogResource < Raxon::SqlJson::Resource
    #     model Statistic
    #     columns :id, :name
    #     attribute(:archived) { |row| row[:archived].eq(true).or(row[:deleted_at].not_eq(nil)) }
    #     pluck :post_ids, from: :posts, column: :id
    #     order { |row| row[:name].lower }
    #   end
    #
    #   CatalogResource.new(Statistic.where(organization_id: 1)).sql
    #
    # produces (quoting trimmed):
    #
    #   WITH sql_json_scope AS (SELECT statistics.* FROM statistics WHERE deleted_at IS NULL AND organization_id = 1)
    #   SELECT COALESCE(json_agg(json_build_object(
    #     'id', sql_json_row.id,
    #     'name', sql_json_row.name,
    #     'archived', (sql_json_row.archived = TRUE OR sql_json_row.deleted_at IS NOT NULL),
    #     'post_ids', COALESCE((
    #       SELECT json_agg(posts.id ORDER BY posts.id)
    #       FROM posts
    #       INNER JOIN post_statistic_assignments ON post_statistic_assignments.statistic_id = sql_json_row.id
    #       WHERE posts.deleted_at IS NULL AND posts.id = post_statistic_assignments.post_id
    #     ), '[]'::json)
    #   ) ORDER BY LOWER(sql_json_row.name)), '[]'::json)::text
    #   FROM sql_json_scope sql_json_row
    #
    # Three things to notice:
    #
    # 1. The caller's relation becomes the CTE as is, ordering removed. Any
    #    policy scope, archived filter, or soft-delete default scope arrives
    #    through it. This class never filters rows itself.
    # 2. Every `pluck` is a correlated subquery built from the association's
    #    reflection chain, the way ActiveRecord's JoinDependency builds a
    #    `joins(:posts)`, but starting at the target table and tying the
    #    first link to the outer row rather than joining the model's table
    #    again. The through table and the `posts.deleted_at IS NULL`
    #    condition come from the reflections, so no table name or soft-delete
    #    rule is written here. Joining the model's table again inside every
    #    subquery doubled a 106-row statement's execution and planning time.
    # 3. Both aggregates are wrapped in `COALESCE(..., '[]'::json)`, because
    #    `json_agg` over zero rows is NULL, not an empty array.
    #
    # The attribute SQL depends only on the declaration, so it is rendered
    # once per class and active attribute set and kept; a request renders
    # only the scope's CTE.
    #
    # == How a request compiles
    #
    #   declaration ──> class-level attribute list (declaration order)
    #        │
    #        ▼  new(scope, **options)
    #   resolve options: passed value, else the declared default proc
    #        │
    #        ▼  #sql
    #   keep attributes whose branch matches the options
    #   ask each attribute for its SQL expression against the row alias
    #   wrap in json_build_object / json_agg / COALESCE, cast to text
    #   (everything after the CTE is cached per attribute set)
    #        │
    #        ▼  #json
    #   connection.select_value  ──> one String
    #
    # == Attribute shapes
    #
    # Each shape is a Struct with a `sql(resource)` method that returns one
    # SQL expression for the value. The name becomes the JSON key.
    #
    #   columns :id, :name            Column      sql_json_row.id (a timestamp through to_char)
    #   json_column :settings         JsonColumn  to_json(sql_json_row.settings)
    #   attribute(:x) { |row| node }  Computed    (node compiled to SQL)
    #   constant :x, []               Constant    '[]'::json
    #   pluck :x, from:, column:      Pluck       COALESCE((SELECT json_agg(...) ...), '[]'::json)
    #   pluck :x, from:, expression:  Pluck       the same, over an Arel node built from the target table
    #   has_many :x, resource: R      Nested      (SELECT COALESCE(json_agg(json_build_object(...)), '[]'::json) FROM (...) sql_json_row_1)
    #   has_one :x, resource: R       Nested      (SELECT json_build_object(...) FROM (...) sql_json_row_1 LIMIT 1)
    #
    # `json_column` exists because a json/jsonb column handed straight to
    # `json_build_object` is fine, but a text column holding JSON is not;
    # `to_json` makes the intent explicit and keeps nested JSON nested.
    #
    # == Ordering rules
    #
    # - Objects in the array follow `order`. Without it the order is whatever
    #   Postgres produces, which is not stable; declare one.
    # - A nested `has_many` array follows the nested resource's `order`, or
    #   its model's primary key when it declares none.
    # - Plucked arrays sort by the target table's primary key, so two plucks
    #   from the same association (ids and names, say) line up index by index.
    #   That is not the order a preloader returns.
    # - Distinct plucks sort by value. Postgres only lets a DISTINCT aggregate
    #   order by its own argument, so `json_agg(DISTINCT x ORDER BY x)` is the
    #   only form that works without a subquery.
    #
    # == Options and branches
    #
    #   option :responsible_employees, default: -> { Current.feature_enabled?("responsible_employees") }
    #   branch responsible_employees: true do ... end
    #   branch responsible_employees: false do ... end
    #
    # A branch tags the attributes declared inside it with a condition on
    # option truthiness. At request time only attributes whose condition
    # matches are emitted. Keys keep declaration order, so a branch's
    # attributes appear where the branch sits, and two branches that declare
    # the same keys in the same order produce the same key order. The default
    # proc runs only when the caller passes nothing for that option, which is
    # what lets a test pass the option without the state the default reads.
    #
    # == Invariants worth checking
    #
    # - Every value expression is one SQL expression, so it can be a
    #   `json_build_object` argument. Nothing here emits a bare SELECT list.
    # - `json_build_object` is variadic and Postgres caps function arguments
    #   at 100. MAX_ATTRIBUTES keeps a resource under that.
    # - The row aliases (`sql_json_row`, then `sql_json_row_1` and on for
    #   each nested level) must differ from every table in a reflection
    #   chain, because a subquery joins those tables by name and ties its
    #   first link to the alias of the level above.
    # - A nested resource renders against its own row alias, so its
    #   columns, plucks, and order work at any depth. It may not declare
    #   options: nothing passes them down, so its attribute set is fixed.
    # - A pluck or nested resource never touches the model's table or its
    #   default scope. The
    #   caller's scope already decided which rows exist; if a subquery
    #   re-applied the model's default scope, a `with_discarded` scope would
    #   get empty arrays for its discarded rows.
    # - Everything after the CTE is cached per class and active attribute
    #   set, in `sql_cache`. A nested resource's SQL is part of its parent's
    #   entry. A declaration is fixed once its class is loaded, and
    #   quoting is the adapter's, so the cache never goes stale within a
    #   process.
    # - Numeric columns stay numbers. `json_build_object` renders a
    #   `numeric` as a JSON number with its stored scale (12.50), which every
    #   parser reads as 12.5.
    # - Timestamp columns are text in UTC with milliseconds and a `Z`
    #   (`2026-09-14T21:27:33.009Z`), which is ActiveSupport's default
    #   Time#as_json. A `timestamp` column is read as UTC, so this assumes
    #   ActiveRecord.default_timezone is :utc, its default.
    #
    # == Output differences from an Alba resource
    #
    # - Postgres writes a space after each colon and comma, about 10% more
    #   bytes than JSON.generate.
    # - A computed attribute or an `expression:` pluck over a timestamp
    #   gets json_build_object's format, with no zone suffix
    #   (`2026-09-14T21:27:33.009`). Columns and `column:` plucks are
    #   formatted with a `Z`, as ActiveRecord writes them.
    #
    # == Arel details a validator should know
    #
    # - `Arel::Attributes::Attribute` (what `row[:name]` returns) is not an
    #   `Arel::Nodes::Node`. It has no `to_sql`, `or`, or `and`. `compile`
    #   renders it through the connection visitor, and computed attributes
    #   must start with a predicate such as `eq(true)` before chaining `or`.
    # - `where(id: Arel.sql("..."))` renders `= NULL`; the predicate builder
    #   treats the literal as a bind value. Correlation therefore uses an Arel
    #   equality node, never a hash.
    # - A Hash passed as `where:` on a pluck names columns of the target
    #   table. The relation is built from the model, so an unscoped hash would
    #   qualify the columns with the model's table instead.
    #
    # == Adding a shape
    #
    # 1. Add a Struct with `name`, `branch`, and whatever it needs, plus a
    #    `sql(resource)` method that returns one SQL expression.
    # 2. Add a class-level declaration method that validates what it can at
    #    declaration time and calls `add`.
    # 3. Cover it in spec/raxon/sql_json/resource_spec.rb, which runs the
    #    generator against Postgres through real models.
    #
    # == Not covered
    #
    # - Anything that needs Ruby at render time, such as presigned URLs.
    #
    # @example
    #   CatalogResource.new(scope).json # => "[{\"id\" : 1, ...}]"
    #
    class Resource
      # The outer row inside the query. Top-level attributes read their
      # columns from this alias; a nested resource reads from
      # `sql_json_row_1`, `sql_json_row_2`, and so on, one per depth. No alias
      # may equal a table in any reflection chain, because each pluck and
      # nested resource joins those tables by name inside its subquery.
      ROW = Arel::Table.new("sql_json_row")

      # json_build_object takes key/value pairs as variadic arguments and
      # Postgres caps function arguments at 100.
      MAX_ATTRIBUTES = 50

      # Renders any Arel node or attribute to SQL through a connection's
      # visitor. `Arel::Nodes::Node#to_sql` exists, but the attributes that
      # `ROW[:col]` returns are not nodes and lack it.
      #
      # @param node [Arel::Nodes::Node, Arel::Attributes::Attribute]
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [String]
      def self.compile(node, connection) = connection.visitor.accept(node, Arel::Collectors::SQLString.new).value

      # The to_char pattern for a timestamp: ISO 8601 in UTC with
      # milliseconds and a Z, as ActiveSupport's Time#as_json writes it.
      TIMESTAMP_FORMAT = %('YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')

      # A column's value as JSON should carry it. json_build_object writes a
      # timestamp with no zone (2026-09-14T21:27:33.009), so timestamps go
      # through to_char. A `timestamp` column holds UTC, which is
      # ActiveRecord's default_timezone; a `timestamptz` is converted to UTC
      # first so the session time zone cannot change the text. Every other
      # type is left to Postgres.
      #
      # @param sql [String] the column, already compiled
      # @param column [ActiveRecord::ConnectionAdapters::Column, nil]
      # @return [String]
      def self.column_value(sql, column)
        case column&.type
        when :datetime then "to_char(#{sql}, #{TIMESTAMP_FORMAT})"
        when :timestamptz then "to_char(#{sql} AT TIME ZONE 'UTC', #{TIMESTAMP_FORMAT})"
        else sql
        end
      end

      # What an attribute renders against: the connection that quotes and
      # compiles, the row its columns come from, and the model that row
      # belongs to. `nested` is the context for a resource one level down,
      # with its own row alias.
      Render = Struct.new(:connection, :row, :depth, :model) do
        def compile(node) = Resource.compile(node, connection)

        def quote(value) = connection.quote(value)

        def nested(model) = Render.new(connection, Arel::Table.new("#{ROW.name}_#{depth + 1}"), depth + 1, model)

        # The row alias, quoted, for a FROM clause.
        def row_alias = connection.quote_table_name(row.name)
      end

      # A column of the row. Postgres maps the column type to JSON itself:
      # booleans stay booleans, numerics stay numbers, NULL stays null. A
      # timestamp is formatted by Resource.column_value.
      Column = Struct.new(:name, :branch) do
        def sql(render) = Resource.column_value(render.compile(render.row[name]), render.model.columns_hash[name.to_s])
      end

      # A json or jsonb column, wrapped in to_json so its structure is
      # embedded rather than re-encoded as a string.
      JsonColumn = Struct.new(:name, :branch) do
        def sql(render) = "to_json(#{render.compile(render.row[name])})"
      end

      # An expression built from the row. The block receives the row and
      # returns an Arel node; parentheses keep operator precedence intact
      # inside the json_build_object argument list.
      Computed = Struct.new(:name, :branch, :block) do
        def sql(render) = "(#{render.compile(block.call(render.row))})"
      end

      # A literal JSON value, the same for every row. The Ruby value is
      # encoded once and cast so nested arrays and objects survive.
      Constant = Struct.new(:name, :branch, :value) do
        def sql(render) = "#{render.quote(JSON.generate(value))}::json"
      end

      # The rows of an association that belong to the current row, as an
      # ActiveRecord relation over the association's target table. Pluck and
      # Nested build their subqueries on it. The including Struct supplies
      # `model` (the resource's model), `from` (the association name), and
      # `where` (an extra condition or nil).
      module Correlated
        # The association reflection; validated to exist when declared.
        def target = model.reflect_on_association(from)

        # Walks the association's reflection chain from the owner's side, as
        # ActiveRecord's JoinDependency does for `joins(from)`, asking each
        # link for its `join_scope` against the table before it: the keys that
        # tie the two tables, the link's association scope, and its class's
        # default scope. The first link is tied to the current row instead of
        # the model's table, so the model's table never appears in the
        # subquery and the outer scope alone decides which rows exist. Every
        # link but the target becomes an INNER JOIN with those conditions as
        # its ON; the target's conditions are the WHERE, since the target is
        # the FROM.
        #
        # A chain that names one table twice (a self join) is not aliased
        # here; JoinDependency's alias tracker is what handles that case.
        #
        # @param render [Render] supplies the row the first link is tied to
        # @return [ActiveRecord::Relation]
        def relation(render)
          joins = []
          conditions = []
          foreign_table, foreign_klass = render.row, model
          target.chain.reverse_each do |link|
            table = link.klass.arel_table
            predicate = link.join_scope(table, foreign_table, foreign_klass).where_clause.ast
            if link.equal?(target.chain.first)
              conditions << predicate
            else
              joins << Arel::Nodes::InnerJoin.new(table, Arel::Nodes::On.new(predicate))
            end
            foreign_table, foreign_klass = table, link.klass
          end
          correlated = target.klass.unscoped
          correlated = correlated.joins(*joins) if joins.any?
          correlated = conditions.inject(correlated) { |relation, predicate| relation.where(predicate) }
          where ? correlated.where(condition) : correlated
        end

        # A Hash condition names columns of the target table. Nesting it under
        # the target's table name stops ActiveRecord from qualifying the
        # columns with the model's table. A String passes through untouched.
        def condition = where.is_a?(Hash) ? {target.klass.table_name => where} : where
      end

      # An array of one value from an association, as a correlated subquery.
      #
      # The value is `column`, a column of the association's target table,
      # or `expression`, a block that receives the target's Arel table and
      # returns a node.
      #
      # The steps are separate methods so each is small and readable:
      #
      #   relation   see Correlated#relation
      #   aggregate  json_agg([DISTINCT ]value ORDER BY order_sql)
      #   sql        COALESCE((relation.select(aggregate)), '[]'::json)
      Pluck = Struct.new(:name, :branch, :model, :from, :column, :expression, :where, :distinct) do
        include Correlated

        def sql(render) = "COALESCE((#{relation(render).select(Arel.sql(aggregate(render))).to_sql}), '[]'::json)"

        # The value: the column, or the expression in parentheses so it is one
        # argument to json_agg whatever operators it holds.
        def column_sql(render)
          return Resource.column_value(render.compile(target.klass.arel_table[column]), target.klass.columns_hash[column.to_s]) if column

          "(#{render.compile(expression.call(target.klass.arel_table))})"
        end

        # Non-distinct arrays sort by the target's primary key so plucks from
        # the same association line up. Postgres lets a DISTINCT aggregate
        # order only by its own argument, so distinct arrays sort by value.
        def order_sql(render) = distinct ? column_sql(render) : render.compile(target.klass.arel_table[target.klass.primary_key])

        def aggregate(render) = "json_agg(#{"DISTINCT " if distinct}#{column_sql(render)} ORDER BY #{order_sql(render)})"
      end

      # An association rendered by another resource: an array of objects for
      # `has_many`, one object or null for `has_one`.
      #
      # The correlated relation selects the target's columns and becomes a
      # derived table under the next row alias, so the nested resource's
      # attributes, plucks, and order read that alias exactly as top-level
      # ones read `sql_json_row`:
      #
      #   (SELECT COALESCE(json_agg(json_build_object(...) ORDER BY ...), '[]'::json)
      #    FROM (SELECT employees.* FROM employees INNER JOIN ... ) sql_json_row_1)
      #
      # `has_one` builds one object from the first row in the nested order.
      Nested = Struct.new(:name, :branch, :model, :from, :where, :resource, :many) do
        include Correlated

        def sql(render)
          inner = render.nested(resource.model_class)
          rows = "FROM (#{relation(render).select(target.klass.arel_table[Arel.star]).to_sql}) #{inner.row_alias}"
          if many
            "(SELECT #{resource.aggregate_sql(resource.attributes, inner)} #{rows})"
          else
            "(SELECT #{resource.object_sql(resource.attributes, inner)} #{rows} ORDER BY #{resource.order_sql(inner)} LIMIT 1)"
          end
        end
      end

      # Class-level DSL. State lives in three class instance variables:
      # `@attributes` (declaration order), `@options` (name => default proc),
      # and `@order_block`. `@branch` is set only while a `branch` block runs.
      class << self
        attr_reader :model_class

        # A subclass starts with copies of its parent's declarations and may
        # add more; the parent never sees the additions.
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@attributes, attributes.dup)
          subclass.instance_variable_set(:@options, options.dup)
          subclass.instance_variable_set(:@model_class, model_class)
          subclass.instance_variable_set(:@order_block, @order_block)
        end

        # @return [Array<Struct>] every declared attribute, branch tags included
        def attributes = @attributes ||= []

        # @return [Hash{Symbol => Proc}] option name to default proc
        def options = @options ||= {}

        # The model whose rows the scope yields. Declare it before any `pluck`
        # or nested resource.
        #
        # @param klass [Class<ActiveRecord::Base>]
        def model(klass) = @model_class = klass

        # Declares a per-request switch that `branch` can test.
        #
        # @param name [Symbol]
        # @param default [Proc] called at request time when the caller passes
        #   no value for this option; not called otherwise
        def option(name, default:) = options[name] = default

        # Columns of the model emitted as they are.
        #
        # @param names [Array<Symbol>]
        def columns(*names) = names.each { add Column.new(it, @branch) }

        # A json/jsonb column emitted through to_json.
        #
        # @param name [Symbol]
        def json_column(name) = add JsonColumn.new(name, @branch)

        # A computed value.
        #
        # @param name [Symbol] the JSON key
        # @yieldparam row [Arel::Table] the row
        # @yieldreturn [Arel::Nodes::Node] the expression; start from a
        #   predicate such as `row[:x].eq(true)` before chaining `or`/`and`
        def attribute(name, &block) = add Computed.new(name, @branch, block)

        # A literal value, the same for every row.
        #
        # @param name [Symbol]
        # @param value [Object] anything JSON.generate accepts
        def constant(name, value) = add Constant.new(name, @branch, value)

        # An array of one value from an association.
        #
        # @param name [Symbol] the JSON key
        # @param from [Symbol] an association of the model, direct or through
        # @param column [Symbol, nil] a column of the association's target table
        # @param expression [Proc, nil] instead of a column: receives the
        #   target's Arel table and returns the node to aggregate
        # @param where [String, Hash, nil] extra condition; a Hash names
        #   columns of the target table, a String is raw SQL
        # @param distinct [Boolean] drop repeated values; the array then sorts
        #   by value instead of by the target's primary key
        # @raise [ArgumentError] when `model` is missing, the association does
        #   not exist, or neither or both of column and expression are given,
        #   so a typo fails at class load
        def pluck(name, from:, column: nil, expression: nil, where: nil, distinct: false)
          reflection_for(from)
          (column.nil? ^ expression.nil?) or raise ArgumentError, "pluck takes column: or expression:, not both"
          add Pluck.new(name, @branch, model_class, from, column, expression, where, distinct)
        end

        # An array of objects, one per row of an association, each rendered
        # by another resource. The array follows that resource's `order`, or
        # its model's primary key when it declares none.
        #
        # @param name [Symbol] the JSON key
        # @param resource [Class<Resource>] renders each object; its model must
        #   be the association's class, and it may not declare options
        # @param from [Symbol] an association of the model, direct or through;
        #   defaults to the name
        # @param where [String, Hash, nil] extra condition, as for `pluck`
        # @raise [ArgumentError] on a missing association, a resource for
        #   another model, or a resource with options
        def has_many(name, resource:, from: name, where: nil) = add nested(name, resource, from, where, many: true)

        # One object from an association, rendered by another resource, or
        # null when there is none. Works for belongs_to, has_one, and through
        # associations. With more than one row, the first in the resource's
        # order wins.
        #
        # @param (see #has_many)
        # @raise (see #has_many)
        def has_one(name, resource:, from: name, where: nil) = add nested(name, resource, from, where, many: false)

        # Tags the attributes declared inside the block with a condition.
        # They are emitted only when every named option has the given
        # truthiness at request time.
        #
        # @param conditions [Hash{Symbol => Boolean}] option name to required truthiness
        # @raise [ArgumentError] when a condition names an undeclared option
        def branch(**conditions)
          conditions.each_key { |key| options.key?(key) or raise ArgumentError, "unknown option #{key}" }
          @branch = conditions
          yield
        ensure
          @branch = nil
        end

        # The order of objects in the array.
        #
        # @yieldparam row [Arel::Table] the row
        # @yieldreturn [Arel::Nodes::Node] the sort expression
        def order(&block) = @order_block = block

        # The OpenAPI component name this resource was documented under, or
        # nil. A resource that nests this one refers to that component.
        attr_reader :component_name

        # Declares this resource's attributes as properties of an OpenAPI
        # component and records the component's name. Called by
        # Raxon::OpenApi::DSL.from_sql_json.
        #
        # @param component [OpenApi::Component]
        # @param name [Symbol, String]
        # @return [void]
        def document(component, name)
          @component_name = name
          ComponentBuilder.build(component, self)
        end

        # The SQL for each attribute set a request can emit, keyed by the
        # attributes' object ids. Rendering walks every pluck's reflection
        # chain through ActiveRecord, about 0.3 ms for a small declaration,
        # and nothing in it varies between requests.
        #
        # The key is not the attribute names: two branches can declare the
        # same name with different SQL.
        #
        # @return [Hash{Array<Integer> => String}]
        def sql_cache = @sql_cache ||= {}

        # @param attributes [Array<Struct>] the attributes to emit
        # @param render [Render]
        # @return [String] `json_build_object(...)` over the render's row
        def object_sql(attributes, render)
          "json_build_object(\n  #{attributes.map { |attribute| "#{render.quote(attribute.name.to_s)}, #{attribute.sql(render)}" }.join(",\n  ")}\n)"
        end

        # @param attributes [Array<Struct>] the attributes to emit
        # @param render [Render]
        # @return [String] the objects aggregated into a JSON array, `[]` when
        #   there are none, in the declared order
        def aggregate_sql(attributes, render)
          order = (@order_block || render.depth.positive?) ? " ORDER BY #{order_sql(render)}" : ""
          "COALESCE(json_agg(#{object_sql(attributes, render)}#{order}), '[]'::json)"
        end

        # @param render [Render]
        # @return [String] the declared sort expression over the render's row,
        #   or the model's primary key when none is declared
        def order_sql(render) = render.compile(@order_block ? @order_block.call(render.row) : render.row[model_class.primary_key])

        private

        def add(attribute)
          attributes.size < MAX_ATTRIBUTES or raise ArgumentError, "json_build_object takes at most #{MAX_ATTRIBUTES} attributes"
          attributes << attribute
        end

        def reflection_for(from)
          model_class or raise ArgumentError, "declare `model` before an association"
          model_class.reflect_on_association(from) or raise ArgumentError, "#{model_class} has no association #{from}"
        end

        def nested(name, resource, from, where, many:)
          target = reflection_for(from).klass
          (resource.model_class && target <= resource.model_class) or raise ArgumentError, "#{resource} renders #{resource.model_class}, but #{from} is #{target}"
          resource.options.empty? or raise ArgumentError, "#{resource} declares options, which a nested resource cannot take"
          Nested.new(name, @branch, model_class, from, where, resource, many)
        end
      end

      # @param scope [ActiveRecord::Relation] the rows to render; bring it
      #   already policy-scoped and filtered, since this class never filters
      # @param options [Hash{Symbol => Object}] values for declared options;
      #   a passed option skips its default proc
      # @raise [ArgumentError] on an option the resource did not declare
      def initialize(scope, **options)
        unknown = options.keys - self.class.options.keys
        unknown.empty? or raise ArgumentError, "unknown options #{unknown.join(", ")}"
        @scope = scope
        @options = self.class.options.to_h { |name, default| [name, options.key?(name) ? options[name] : default.call] }
      end

      # Runs the query. A handler returns the text as
      # `JSON::Fragment.new(resource.json)`: Raxon sends it as it is, and
      # response validation parses it.
      #
      # @return [String] the JSON array text; "[]" when the scope is empty
      def json = @scope.connection.select_value(sql)

      # The full query. Useful in a console to inspect what a declaration
      # compiles to or to EXPLAIN it.
      #
      # The scope loses its ORDER BY because ordering inside a CTE does not
      # reach json_agg; `order` supplies the order that does.
      #
      # @return [String]
      def sql
        <<~SQL
          WITH "sql_json_scope" AS (#{@scope.reorder(nil).select("#{model_table}.*").to_sql})
          #{select_sql}
        SQL
      end

      # Everything after the CTE: the aggregate over the scope's rows for
      # this request's attributes, rendered once per attribute set and kept
      # on the class.
      #
      # @return [String]
      def select_sql
        active = attributes
        self.class.sql_cache[active.map(&:object_id)] ||= begin
          render = Render.new(@scope.connection, ROW, 0, self.class.model_class)
          "SELECT #{self.class.aggregate_sql(active, render)}::text\nFROM \"sql_json_scope\" #{render.row_alias}"
        end
      end

      private

      # The declared attributes whose branch matches this request's options,
      # in declaration order.
      def attributes = self.class.attributes.select { |attribute| active?(attribute.branch) }

      def active?(branch) = branch.nil? || branch.all? { |key, value| !!@options[key] == value }

      def model_table = @scope.connection.quote_table_name(self.class.model_class.table_name)
    end
  end
end
