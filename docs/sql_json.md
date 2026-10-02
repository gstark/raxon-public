# Building JSON in Postgres with SqlJson

`Raxon::SqlJson::Resource` declares a JSON array of objects that Postgres
builds in one query. A list route that loads records, preloads their
associations, and serializes them spends most of its time on Ruby objects
that exist only to become text again. A SqlJson declaration makes one round
trip and allocates one String.

On a 106-row list with one plucked association, the route took 9.3 ms with
`includes` and an Alba resource, and 1.3 ms with SqlJson.

## Requirements

- ActiveRecord, loaded by your application. Raxon does not depend on it.
  `Raxon::SqlJson` loads only when your code first names it.
- Postgres. The SQL uses `json_build_object` and `json_agg`.

## A declaration

```ruby
class PostTitleResource < Raxon::SqlJson::Resource
  model Post

  columns :id, :title

  pluck :responsible_employee_names, from: :responsible_employees,
    expression: ->(employees) {
      Arel::Nodes::Concat.new(Arel::Nodes::Concat.new(employees[:first_name], Arel::Nodes.build_quoted(" ")), employees[:last_name])
    }

  order { |row| row[:title] }
end
```

A route returns the JSON text as a `JSON::Fragment`:

```ruby
Raxon.route do
  response :ok, type: :array, of: "PostTitle"

  handle { JSON::Fragment.new(PostTitleResource.new(Current.organization.posts).json) }
end
```

Raxon sends the fragment's text as it is. When response validation is on, it
parses the text and checks it against the declared schema. A fragment can
also sit inside a larger body, such as `{data: fragment, total: count}`.

## The scope decides the rows

The relation you pass becomes a CTE. Its policy scope, filters, and the
model's default scope all apply. SqlJson never filters rows itself, and its
plucks never read the model's table again. A `with_discarded` scope therefore
gets the full arrays for its discarded rows.

## Attribute shapes

| Declaration | JSON value |
| --- | --- |
| `columns :id, :name` | The column as Postgres maps it: numbers, booleans, and null stay so. |
| `json_column :settings` | A json or jsonb column, nested as JSON. |
| `attribute(:archived) { \|row\| row[:archived].eq(true) }` | An Arel expression over the outer row. |
| `constant :tags, []` | The same literal for every row. |
| `pluck :post_ids, from: :posts, column: :id` | An array of one column of an association. |
| `pluck :names, from: :employees, expression: ->(t) { ... }` | An array of an Arel expression over the association's table. |

A `pluck` takes `where:` (a Hash names columns of the target table, a String
is raw SQL) and `distinct: true`. The association can be direct or
`through:`, and its target's default scope applies.

`option` and `branch` turn attributes on or off for each request:

```ruby
option :with_posts, default: -> { Current.feature_enabled?(:posts) }

branch with_posts: true do
  pluck :post_ids, from: :posts, column: :id
end
```

The default proc runs only when the caller does not pass the option.

## Timestamps

A `timestamp` or `timestamptz` column, in `columns` or in a `column:` pluck,
is written as ActiveSupport writes a Time: UTC, milliseconds, and a `Z`
(`2026-09-14T21:27:33.009Z`). The session time zone does not change it. A
`timestamp` column is read as UTC, which is ActiveRecord's default
`default_timezone`.

## Nested objects

`has_many` and `has_one` render an association with another declaration:

```ruby
class EmployeeResource < Raxon::SqlJson::Resource
  model Employee
  columns :id, :first_name
  order { |row| row[:first_name] }
end

class PostResource < Raxon::SqlJson::Resource
  model Post
  columns :id, :title
  has_one :author, resource: EmployeeResource
  has_many :responsible_employees, resource: EmployeeResource
end
```

- `has_many` gives an array of objects, or `[]`. The array follows the
  nested declaration's `order`, or its model's primary key.
- `has_one` gives one object, or `null`. It works for `belongs_to`,
  `has_one`, and `through` associations.
- `from:` names the association when the JSON key differs from it. `where:`
  works as it does for `pluck`.
- The nested declaration's model must be the association's class. It cannot
  declare `option`, because nothing passes options down.
- Nesting can go to any depth. Each level is one correlated subquery.

## Output differences from an Alba resource

- Postgres writes a space after each colon and comma. The body is about 10%
  larger than the same data from `JSON.generate`.
- A plucked array sorts by the target table's primary key, so two plucks
  from one association line up. A preloader can return another order.
- A distinct pluck sorts by value.
- A computed `attribute` or an `expression:` pluck over a timestamp has no
  zone suffix (`2026-09-14T21:27:33.009999`).

## OpenAPI

`from_sql_json` makes a component from a declaration, so the route needs no
Alba resource for the document:

```ruby
Raxon::OpenApi::DSL.from_sql_json(:Employee, EmployeeResource)
Raxon::OpenApi::DSL.from_sql_json(:Post, PostResource) do |component|
  component.property :archived, type: :boolean # a computed attribute
end
```

- A column gets its type, nullability, comment, and enum from the database,
  as `from_resource` maps them. `id`, `created_at`, `updated_at`, and
  `deleted_at` are `read_only`.
- A `column:` pluck is an array of the column's type. When the column is
  nullable, the items are untyped, because an item can be null.
- A `constant` gets the type of its Ruby value.
- A computed `attribute`, a `json_column`, and an `expression:` pluck are
  untyped. Declare their types in the block. A block property wins over the
  declaration.
- `has_many` is an array of the nested declaration's component, and
  `has_one` is a nullable object of it. Make the nested component first. If
  the nested declaration has no component, its properties are inlined.
- Attributes inside a `branch` are not required.
- Without a database, columns are untyped, so validation still accepts
  their keys.

## Not covered yet

- Values that need Ruby at render time, such as presigned URLs.

`lib/raxon/sql_json/resource.rb` explains the SQL that each declaration
produces and the invariants that the code keeps.
