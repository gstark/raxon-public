# frozen_string_literal: true

require "spec_helper"
require "active_record"

# Models for the specs, connected through their own abstract class so that
# ActiveRecord::Base stays unconnected for the rest of the suite. Each class
# names a table in the raxon_sql_json_spec schema, which the database group
# below creates and drops.
module SqlJsonSpec
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  class Employee < Record
    default_scope { where(discarded_at: nil) }

    has_many :post_employee_assignments
    has_many :posts, through: :post_employee_assignments
  end

  class PostResponsibleEmployee < Record
    belongs_to :post
    belongs_to :employee
  end

  class PostEmployeeAssignment < Record
    belongs_to :post
    belongs_to :employee
  end

  class Post < Record
    default_scope { where(deleted_at: nil) }

    belongs_to :author, class_name: "Employee", optional: true
    has_many :post_responsible_employees
    has_many :responsible_employees, through: :post_responsible_employees, source: :employee
    has_many :post_employee_assignments
    has_many :employees, through: :post_employee_assignments
  end

  class PostStatisticAssignment < Record
    belongs_to :post
    belongs_to :statistic
  end

  class Statistic < Record
    default_scope { where(deleted_at: nil) }

    has_many :post_statistic_assignments
    has_many :posts, through: :post_statistic_assignments
    has_many :employees, through: :posts
  end

  class EmployeeResource < Raxon::SqlJson::Resource
    model Employee

    columns :id, :first_name
    pluck :post_titles, from: :posts, column: :title
  end

  class EmployeeByNameResource < Raxon::SqlJson::Resource
    model Employee

    columns :first_name

    order { |row| row[:first_name] }
  end

  class PostWithPeopleResource < Raxon::SqlJson::Resource
    model Post

    columns :id, :title
    has_one :author, resource: EmployeeByNameResource
    has_many :responsible_employees, resource: EmployeeResource
    has_many :named_responsible_employees, resource: EmployeeByNameResource, from: :responsible_employees

    order { |row| row[:title] }
  end

  class StatisticWithPostsResource < Raxon::SqlJson::Resource
    model Statistic

    columns :name
    has_many :posts, resource: PostWithPeopleResource
  end

  class PostTimeResource < Raxon::SqlJson::Resource
    model Post

    columns :created_at
  end

  class StatisticTimeResource < Raxon::SqlJson::Resource
    model Statistic

    columns :published_at, :deleted_at
    pluck :post_created_ats, from: :posts, column: :created_at
    pluck :post_created_at_text, from: :posts, expression: ->(posts) { posts[:created_at] }
    has_many :posts, resource: PostTimeResource
  end

  class PostTitleResource < Raxon::SqlJson::Resource
    model Post

    columns :id, :title

    pluck :responsible_employee_names, from: :responsible_employees,
      expression: ->(employees) { Arel::Nodes::Concat.new(Arel::Nodes::Concat.new(employees[:first_name], Arel::Nodes.build_quoted(" ")), employees[:last_name]) }

    order { |row| row[:title] }
  end

  class CatalogResource < Raxon::SqlJson::Resource
    model Statistic

    option :with_posts, default: -> { true }

    columns :id, :name, :value
    json_column :settings
    attribute(:archived) { |row| row[:archived].eq(true).or(row[:deleted_at].not_eq(nil)) }
    constant :tags, ["a", {"b" => 1}]

    branch(with_posts: true) do
      pluck :post_ids, from: :posts, column: :id
      pluck :post_titles, from: :posts, column: :title
    end

    pluck :employee_ids, from: :employees, column: :id
    pluck :distinct_employee_ids, from: :employees, column: :id, distinct: true
    pluck :alpha_post_ids, from: :posts, column: :id, where: {title: "Alpha"}

    order { |row| row[:name] }
  end
end

RSpec.describe Raxon::SqlJson::Resource do
  describe "declaration" do
    it "refuses a branch on an undeclared option" do
      expect {
        Class.new(described_class) do
          model SqlJsonSpec::Statistic
          branch(nope: true) { columns :id }
        end
      }.to raise_error(ArgumentError, /unknown option nope/)
    end

    it "refuses a pluck on a missing association" do
      expect {
        Class.new(described_class) do
          model SqlJsonSpec::Statistic
          pluck :ids, from: :nothing, column: :id
        end
      }.to raise_error(ArgumentError, /no association nothing/)
    end

    it "refuses a pluck before the model" do
      expect {
        Class.new(described_class) { pluck :ids, from: :posts, column: :id }
      }.to raise_error(ArgumentError, /declare `model`/)
    end

    it "refuses a pluck with both a column and an expression, or neither" do
      expect {
        Class.new(described_class) do
          model SqlJsonSpec::Statistic
          pluck :ids, from: :posts, column: :id, expression: ->(posts) { posts[:id] }
        end
      }.to raise_error(ArgumentError, /column: or expression:/)

      expect {
        Class.new(described_class) do
          model SqlJsonSpec::Statistic
          pluck :ids, from: :posts
        end
      }.to raise_error(ArgumentError, /column: or expression:/)
    end

    it "refuses a nested resource for another model" do
      expect {
        Class.new(described_class) do
          model SqlJsonSpec::Post
          has_many :responsible_employees, resource: SqlJsonSpec::PostTitleResource
        end
      }.to raise_error(ArgumentError, /renders .*Post, but responsible_employees is .*Employee/)
    end

    it "refuses a nested resource that declares options" do
      expect {
        Class.new(described_class) do
          model SqlJsonSpec::Employee
          has_many :posts, resource: SqlJsonSpec::CatalogResource
        end
      }.to raise_error(ArgumentError)

      with_options = Class.new(described_class) do
        model SqlJsonSpec::Post
        option :flag, default: -> { true }
      end
      expect {
        Class.new(described_class) do
          model SqlJsonSpec::Employee
          has_many :posts, resource: with_options
        end
      }.to raise_error(ArgumentError, /declares options/)
    end

    describe "OpenAPI" do
      def schema_for(resource, name: :Shape)
        spec = Raxon::OpenApi::Specification.new
        spec.from_sql_json(name, resource) { |component| yield component if block_given? }
        spec.to_open_api.dig("components", "schemas", name.to_s)
      end

      it "documents constants by their Ruby type and computed values as untyped" do
        resource = Class.new(described_class) do
          model SqlJsonSpec::Statistic
          constant :label, "x"
          constant :count, 1
          constant :ratio, 1.5
          constant :flag, true
          constant :tags, []
          constant :meta, {}
          attribute(:archived) { |row| row[:archived].eq(true) }
          pluck :names, from: :posts, expression: ->(posts) { posts[:title] }
        end

        properties = schema_for(resource)["properties"]

        expect(properties.transform_values { it["type"] }).to eq(
          "label" => "string", "count" => "integer", "ratio" => "number", "flag" => "boolean",
          "tags" => "array", "meta" => "object", "archived" => nil, "names" => "array"
        )
      end

      it "lets the block declare a property, which wins" do
        resource = Class.new(described_class) do
          model SqlJsonSpec::Statistic
          attribute(:archived) { |row| row[:archived].eq(true) }
        end

        schema = schema_for(resource) { it.property :archived, type: :boolean }

        expect(schema.dig("properties", "archived", "type")).to eq("boolean")
      end

      it "does not require a branch's attributes" do
        resource = Class.new(described_class) do
          model SqlJsonSpec::Statistic
          option :extra, default: -> { true }
          constant :always, 1
          branch(extra: true) { constant :sometimes, 2 }
        end

        expect(schema_for(resource)["required"]).to eq(["always"])
      end

      it "refers to a nested resource's component, or inlines one that has none" do
        named = Class.new(described_class) do
          model SqlJsonSpec::Employee
          constant :kind, "named"
        end
        unnamed = Class.new(described_class) do
          model SqlJsonSpec::Employee
          constant :kind, "inline"
        end
        parent = Class.new(described_class) do
          model SqlJsonSpec::Post
          has_one :author, resource: named
          has_many :responsible_employees, resource: named
          has_many :employees, resource: unnamed
        end

        spec = Raxon::OpenApi::Specification.new
        spec.from_sql_json(:Person, named)
        spec.from_sql_json(:Parent, parent)
        properties = spec.to_open_api.dig("components", "schemas", "Parent", "properties")

        expect(properties["responsible_employees"]).to include("type" => "array", "items" => {"$ref" => "#/components/schemas/Person"})
        expect(properties["author"].to_s).to include("#/components/schemas/Person", "null")
        expect(properties.dig("employees", "items", "properties", "kind", "type")).to eq("string")
      end
    end

    it "refuses more attributes than json_build_object takes" do
      names = Array.new(described_class::MAX_ATTRIBUTES + 1) { :"column_#{it}" }

      expect {
        Class.new(described_class) { columns(*names) }
      }.to raise_error(ArgumentError, /at most/)
    end

    it "lets a subclass extend its parent's attributes without changing the parent" do
      before = SqlJsonSpec::CatalogResource.attributes.size
      child = Class.new(SqlJsonSpec::CatalogResource) { columns :deleted_at }

      expect(child.attributes.size).to eq(before + 1)
      expect(SqlJsonSpec::CatalogResource.attributes.size).to eq(before)
    end
  end

  describe "against Postgres" do
    before(:all) do
      skip "set DATABASE_URL to a Postgres database to run the Raxon::SqlJson specs" unless ENV["DATABASE_URL"]

      SqlJsonSpec::Record.establish_connection(url: ENV.fetch("DATABASE_URL"), schema_search_path: "raxon_sql_json_spec")
      SqlJsonSpec::Record.connection.execute(<<~SQL)
        DROP SCHEMA IF EXISTS raxon_sql_json_spec CASCADE;
        CREATE SCHEMA raxon_sql_json_spec;
        CREATE TABLE raxon_sql_json_spec.employees (id bigserial PRIMARY KEY, first_name text, last_name text, discarded_at timestamp);
        CREATE TABLE raxon_sql_json_spec.posts (id bigserial PRIMARY KEY, title text, author_id bigint, created_at timestamp(6), deleted_at timestamp);
        CREATE TABLE raxon_sql_json_spec.post_responsible_employees (id bigserial PRIMARY KEY, post_id bigint, employee_id bigint);
        CREATE TABLE raxon_sql_json_spec.post_employee_assignments (id bigserial PRIMARY KEY, post_id bigint, employee_id bigint);
        CREATE TABLE raxon_sql_json_spec.statistics (id bigserial PRIMARY KEY, name text, value numeric(10, 2), settings jsonb, archived boolean NOT NULL DEFAULT false, published_at timestamptz, deleted_at timestamp);
        CREATE TABLE raxon_sql_json_spec.post_statistic_assignments (id bigserial PRIMARY KEY, post_id bigint, statistic_id bigint);
      SQL
    end

    after(:all) do
      next unless ENV["DATABASE_URL"]

      SqlJsonSpec::Record.connection.execute("DROP SCHEMA IF EXISTS raxon_sql_json_spec CASCADE")
      SqlJsonSpec::Record.remove_connection
    end

    around do |example|
      SqlJsonSpec::Record.transaction do
        example.run
        raise ActiveRecord::Rollback
      end
    end

    def parse(resource) = JSON.parse(resource.json)

    def employee(first_name, last_name = "Smith", **attributes) = SqlJsonSpec::Employee.create!(first_name:, last_name:, **attributes)

    def post(title, **attributes) = SqlJsonSpec::Post.create!(title:, **attributes)

    def statistic(name, **attributes) = SqlJsonSpec::Statistic.create!(name:, **attributes)

    it "renders columns, a JSON column, a computed value, and a constant" do
      statistic("Revenue", value: BigDecimal("12.50"), settings: {"goal" => [1, 2]}, archived: true)

      expect(parse(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all)).first).to include(
        "name" => "Revenue", "value" => 12.5, "settings" => {"goal" => [1, 2]},
        "archived" => true, "tags" => ["a", {"b" => 1}]
      )
    end

    it "keeps declaration order for the keys and follows `order` for the objects" do
      statistic("Zulu")
      statistic("Alpha")

      rows = parse(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.order(:id)))

      expect(rows.map { it["name"] }).to eq(%w[Alpha Zulu])
      expect(rows.first.keys).to eq(%w[id name value settings archived tags post_ids post_titles employee_ids distinct_employee_ids alpha_post_ids])
    end

    it "answers an empty array for an empty scope, and for a row with nothing to pluck" do
      expect(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.none).json).to eq("[]")

      statistic("Lonely")
      expect(parse(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all)).first).to include("post_ids" => [], "employee_ids" => [])
    end

    it "plucks an expression over the target table, through a join table" do
      first = post("First")
      second = post("Second")
      ada = employee("Ada", "Lovelace")
      alan = employee("Alan", "Turing")
      SqlJsonSpec::PostResponsibleEmployee.create!(post: first, employee: alan)
      SqlJsonSpec::PostResponsibleEmployee.create!(post: first, employee: ada)

      expect(parse(SqlJsonSpec::PostTitleResource.new(SqlJsonSpec::Post.where(id: [first.id, second.id])))).to eq([
        {"id" => first.id, "title" => "First", "responsible_employee_names" => ["Ada Lovelace", "Alan Turing"]},
        {"id" => second.id, "title" => "Second", "responsible_employee_names" => []}
      ])
    end

    it "applies the target's default scope and leaves the outer scope to the caller" do
      kept = post("Kept")
      deleted = post("Deleted", deleted_at: Time.now)
      SqlJsonSpec::PostResponsibleEmployee.create!(post: kept, employee: employee("Gone", discarded_at: Time.now))
      SqlJsonSpec::PostResponsibleEmployee.create!(post: deleted, employee: employee("Here"))

      rows = parse(SqlJsonSpec::PostTitleResource.new(SqlJsonSpec::Post.unscoped))

      expect(rows.to_h { [it["title"], it["responsible_employee_names"]] }).to eq("Deleted" => ["Here Smith"], "Kept" => [])
    end

    it "lines up two plucks from one association by the target's primary key" do
      later = post("Alpha")
      earlier = post("Zulu")
      revenue = statistic("Revenue")
      SqlJsonSpec::PostStatisticAssignment.create!(post: earlier, statistic: revenue)
      SqlJsonSpec::PostStatisticAssignment.create!(post: later, statistic: revenue)

      row = parse(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all)).first

      expect(row["post_ids"]).to eq([later.id, earlier.id].sort)
      expect(row["post_titles"]).to eq(row["post_ids"].map { SqlJsonSpec::Post.find(it).title })
    end

    it "keeps repeats in a plain pluck and drops them in a distinct one, through a nested association" do
      ada = employee("Ada")
      revenue = statistic("Revenue")
      2.times do |index|
        shared = post("Post #{index}")
        SqlJsonSpec::PostEmployeeAssignment.create!(post: shared, employee: ada)
        SqlJsonSpec::PostStatisticAssignment.create!(post: shared, statistic: revenue)
      end

      row = parse(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all)).first

      expect(row["employee_ids"]).to eq([ada.id, ada.id])
      expect(row["distinct_employee_ids"]).to eq([ada.id])
    end

    it "reads a Hash `where:` as columns of the target table" do
      revenue = statistic("Revenue")
      alpha = post("Alpha")
      [alpha, post("Beta")].each { SqlJsonSpec::PostStatisticAssignment.create!(post: it, statistic: revenue) }

      expect(parse(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all)).first["alpha_post_ids"]).to eq([alpha.id])
    end

    it "emits a branch's attributes only when its option matches" do
      statistic("Revenue")

      row = parse(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all, with_posts: false)).first

      expect(row.keys).not_to include("post_ids", "post_titles")
      expect(row.keys).to include("alpha_post_ids")
    end

    it "renders each branch's own SQL when two branches declare the same key" do
      resource = Class.new(described_class) do
        model SqlJsonSpec::Statistic
        option :big, default: -> { true }
        branch(big: true) { constant :size, "big" }
        branch(big: false) { constant :size, "small" }
      end
      statistic("Revenue")

      expect(parse(resource.new(SqlJsonSpec::Statistic.all, big: true)).first["size"]).to eq("big")
      expect(parse(resource.new(SqlJsonSpec::Statistic.all, big: false)).first["size"]).to eq("small")
    end

    it "refuses an unknown option" do
      expect { SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.none, feature: true) }
        .to raise_error(ArgumentError, /unknown options feature/)
    end

    it "calls an option's default only when the caller passes nothing" do
      resource = Class.new(described_class) do
        model SqlJsonSpec::Statistic
        option :flag, default: -> { raise "default called" }
        columns :id
      end

      expect { resource.new(SqlJsonSpec::Statistic.none, flag: true).sql }.not_to raise_error
      expect { resource.new(SqlJsonSpec::Statistic.none) }.to raise_error("default called")
    end

    it "does not join the model's table inside a pluck" do
      select = SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all).select_sql

      expect(select).to include(%(INNER JOIN "post_statistic_assignments"))
      expect(select).not_to include(%("statistics"))
    end

    it "renders the attribute SQL once per active attribute set" do
      with_posts = SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.all, with_posts: true)
      without_posts = SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.none, with_posts: false)

      expect(SqlJsonSpec::CatalogResource.new(SqlJsonSpec::Statistic.none, with_posts: true).select_sql).to be(with_posts.select_sql)
      expect(without_posts.select_sql).not_to eq(with_posts.select_sql)
    end

    describe "OpenAPI from the columns" do
      it "maps columns and column plucks as from_resource does" do
        resource = Class.new(described_class) do
          model SqlJsonSpec::Statistic
          columns :id, :name, :value, :published_at
          json_column :settings
          pluck :post_ids, from: :posts, column: :id
          pluck :post_titles, from: :posts, column: :title
        end

        spec = Raxon::OpenApi::Specification.new
        spec.from_sql_json(:StatisticShape, resource)
        properties = spec.to_open_api.dig("components", "schemas", "StatisticShape", "properties")

        expect(properties["id"]).to include("type" => "integer", "readOnly" => true)
        expect(properties["value"]["type"]).to include("number")
        expect(properties["published_at"]).to include("format" => "date-time")
        expect(properties["settings"]).not_to have_key("type")
        expect(properties["post_ids"]).to include("type" => "array", "items" => {"type" => "integer"})
        expect(properties["post_titles"]).to include("type" => "array", "items" => {})
      end

      it "validates the body the declaration builds against the component it documents" do
        resource = Class.new(described_class) do
          model SqlJsonSpec::Statistic
          columns :id, :name, :value, :published_at, :deleted_at
          json_column :settings
          constant :tags, ["a"]
          pluck :post_ids, from: :posts, column: :id
        end
        Raxon::OpenApi::DSL.from_sql_json(:ValidatedStatistic, resource)
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.response 200, type: :array, of: :ValidatedStatistic
        revenue = statistic("Revenue", value: BigDecimal("1.5"), settings: {"a" => 1}, published_at: Time.now)
        SqlJsonSpec::PostStatisticAssignment.create!(post: post("First"), statistic: revenue)
        statistic("Empty")
        response = Raxon::Response.new
        response.body = JSON::Fragment.new(resource.new(SqlJsonSpec::Statistic.all).json)

        result = endpoint.response_schemas[200].call(response.validation_body)

        expect(result.errors.to_h).to eq({})
      end
    end

    describe "timestamps" do
      it "writes timestamp columns in UTC with milliseconds and a Z, as ActiveSupport does" do
        require "active_support/json"
        moment = Time.utc(2026, 9, 14, 21, 27, 33, 9_999)
        revenue = statistic("Revenue", published_at: moment, deleted_at: nil)
        SqlJsonSpec::PostStatisticAssignment.create!(post: post("First", created_at: moment), statistic: revenue)
        # ActiveRecord writes in a UTC session; only the read runs in another zone.
        SqlJsonSpec::Record.connection.execute("SET LOCAL TIME ZONE 'America/New_York'")

        row = parse(SqlJsonSpec::StatisticTimeResource.new(SqlJsonSpec::Statistic.all)).first

        expected = moment.as_json
        expect(expected).to eq("2026-09-14T21:27:33.009Z")
        expect(row).to include(
          "published_at" => expected, "deleted_at" => nil,
          "post_created_ats" => [expected], "posts" => [{"created_at" => expected}]
        )
        expect(row["post_created_at_text"]).to eq(["2026-09-14T21:27:33.009999"])
      end
    end

    describe "nested resources" do
      def assign(post, *employees) = employees.each { SqlJsonSpec::PostResponsibleEmployee.create!(post:, employee: it) }

      it "renders a has_many association as an array of objects, with the nested resource's own plucks" do
        first = post("First")
        ada = employee("Ada")
        alan = employee("Alan")
        assign(first, alan, ada)
        SqlJsonSpec::PostEmployeeAssignment.create!(post: post("Assigned"), employee: ada)

        row = parse(SqlJsonSpec::PostWithPeopleResource.new(SqlJsonSpec::Post.where(id: first.id))).first

        expect(row["responsible_employees"]).to eq([
          {"id" => ada.id, "first_name" => "Ada", "post_titles" => ["Assigned"]},
          {"id" => alan.id, "first_name" => "Alan", "post_titles" => []}
        ].sort_by { it["id"] })
      end

      it "orders a has_many array by the nested resource's order" do
        first = post("First")
        assign(first, employee("Zoe"), employee("Ada"))

        row = parse(SqlJsonSpec::PostWithPeopleResource.new(SqlJsonSpec::Post.where(id: first.id))).first

        expect(row["named_responsible_employees"]).to eq([{"first_name" => "Ada"}, {"first_name" => "Zoe"}])
      end

      it "answers an empty array for a has_many with no rows, and applies the target's default scope" do
        first = post("First")
        assign(first, employee("Gone", discarded_at: Time.now))

        row = parse(SqlJsonSpec::PostWithPeopleResource.new(SqlJsonSpec::Post.where(id: first.id))).first

        expect(row["responsible_employees"]).to eq([])
      end

      it "renders a belongs_to association as one object, or null" do
        ada = employee("Ada")
        post("Written", author: ada)
        post("Anonymous")

        rows = parse(SqlJsonSpec::PostWithPeopleResource.new(SqlJsonSpec::Post.all))

        expect(rows.to_h { [it["title"], it["author"]] }).to eq("Anonymous" => nil, "Written" => {"first_name" => "Ada"})
      end

      it "nests two levels deep" do
        revenue = statistic("Revenue")
        first = post("First", author: employee("Grace"))
        assign(first, employee("Ada"))
        SqlJsonSpec::PostStatisticAssignment.create!(post: first, statistic: revenue)

        row = parse(SqlJsonSpec::StatisticWithPostsResource.new(SqlJsonSpec::Statistic.all)).first

        expect(row["posts"].map { [it["title"], it["author"], it["named_responsible_employees"]] })
          .to eq([["First", {"first_name" => "Grace"}, [{"first_name" => "Ada"}]]])
      end

      it "does not join the model's table inside a nested subquery" do
        sql = SqlJsonSpec::StatisticWithPostsResource.new(SqlJsonSpec::Statistic.all).select_sql

        expect(sql).to include(%("sql_json_row_2"))
        expect(sql).not_to include(%("statistics"))
      end
    end
  end
end
