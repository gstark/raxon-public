# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Focused unit coverage for the shared OpenAPI -> Dry::Schema translation point.
# Request and response validation both route through PropertySchemaBuilder, so the
# type-mapping and constraint-emission matrix is pinned down here directly rather
# than only indirectly via the request/response generator specs.
RSpec.describe Raxon::OpenApi::PropertySchemaBuilder do
  subject(:builder) { described_class.new }

  # Build a one-field Dry::Schema by feeding +field+ through the builder, so we can
  # assert on the resulting validation/coercion behaviour.
  def schema_for(field_name, field)
    b = builder
    Dry::Schema.Params do
      b.add_field_to_schema(self, field_name, field)
    end
  end

  def property(**options)
    Raxon::OpenApi::Property.new(**options)
  end

  describe "#dry_schema_type" do
    {
      "string" => :string,
      "datetime" => :temporal,
      "date_time" => :temporal,
      "date" => :temporal,
      "Dayjs" => :temporal,
      "uuid" => :string,
      "email" => :string,
      "number" => :float,
      "integer" => :integer,
      "boolean" => :bool,
      "array" => :array,
      "object" => :hash,
      "unknown" => :string,
      nil => :any
    }.each do |input, expected|
      it "maps #{input.inspect} to #{expected.inspect}" do
        expect(builder.dry_schema_type(input)).to eq(expected)
      end
    end
  end

  # A datetime is a string on the wire, but a handler returning domain objects
  # hands back a Time/Date/DateTime that JSON.generate turns into exactly that
  # string. Validating those as strings rejected bodies that were correct once
  # serialized — every `created_at` an ORM-backed serializer produced.
  describe "datetime and date properties" do
    %w[datetime date_time date Dayjs].each do |declared|
      it "accepts a string or a temporal object for #{declared}" do
        schema = schema_for(:at, property(type: declared))

        [Time.now, Date.today, DateTime.now, "2026-07-23T00:00:00Z"].each do |value|
          expect(schema.call(at: value).success?).to be(true), "rejected #{value.class}"
        end
      end
    end

    it "still rejects a value that is neither" do
      schema = schema_for(:at, property(type: "datetime"))

      expect(schema.call(at: 42).success?).to be false
    end

    it "allows nil on a nullable datetime" do
      schema = schema_for(:at, property(type: "datetime", nullable: true))

      expect(schema.call(at: nil).success?).to be true
      expect(schema.call(at: Time.now).success?).to be true
    end

    it "accepts temporal items inside a declared array" do
      schema = schema_for(:dates, property(type: "array", of: "date"))

      expect(schema.call(dates: [Date.today, "2026-07-23"]).success?).to be true
      expect(schema.call(dates: [42]).success?).to be false
    end
  end

  # `of:` naming a component is a $ref to an object schema. It used to fall
  # through to the else branch and type the items as strings, so every correct
  # array-of-objects body was rejected with "must be a string".
  describe "arrays whose items are a component reference" do
    it "accepts objects and still requires an array" do
      schema = schema_for(:widgets, property(type: "array", of: "Widget"))

      expect(schema.call(widgets: [{id: 1}, {id: 2}]).success?).to be true
      expect(schema.call(widgets: []).success?).to be true
      expect(schema.call(widgets: "nope").success?).to be false
    end

    it "still constrains items when of: names a scalar type" do
      schema = schema_for(:ids, property(type: "array", of: "integer"))

      expect(schema.call(ids: [1, 2]).success?).to be true
      expect(schema.call(ids: [{id: 1}]).success?).to be false
    end
  end

  # An untyped property emits no `type` key (M-1), i.e. "any type". It used to
  # fall through dry_schema_type's else branch to :string, so the document said
  # "any" while the runtime silently demanded a string — the confusing-500 shape
  # this suite exists to prevent.
  describe "untyped properties" do
    it "accepts any value type, matching the document" do
      schema = schema_for(:notes, property(description: "no declared type"))

      [42, "text", {nested: 1}, [1, 2], false, nil].each do |value|
        expect(schema.call(notes: value).success?).to be(true), "rejected #{value.inspect}"
      end
    end

    it "still enforces a declared enum" do
      schema = schema_for(:mode, property(enum: ["x", 1]))

      expect(schema.call(mode: "x").success?).to be true
      expect(schema.call(mode: 1).success?).to be true
      expect(schema.call(mode: "nope").success?).to be false
    end

    it "enforces a declared enum on a nullable untyped property, and allows nil" do
      schema = schema_for(:mode, property(enum: ["x", 1], nullable: true))

      expect(schema.call(mode: nil).success?).to be true
      expect(schema.call(mode: "x").success?).to be true
      expect(schema.call(mode: "nope").success?).to be false
    end

    it "accepts any value when nullable with no other constraints" do
      schema = schema_for(:notes, property(nullable: true))

      expect(schema.call(notes: nil).success?).to be true
      expect(schema.call(notes: 42).success?).to be true
    end

    it "still rejects a missing required untyped field" do
      schema = schema_for(:notes, property(required: true))

      expect(schema.call({}).success?).to be false
    end
  end

  describe "required vs optional" do
    it "rejects a missing required field" do
      schema = schema_for(:name, property(type: :string, required: true))

      expect(schema.call({}).success?).to be false
    end

    it "allows a missing optional field" do
      schema = schema_for(:name, property(type: :string, required: false))

      expect(schema.call({}).success?).to be true
    end
  end

  describe "scalar fields" do
    it "passes a valid string through unchanged" do
      schema = schema_for(:name, property(type: :string))

      expect(schema.call(name: "John").to_h).to eq(name: "John")
    end

    it "coerces number to float" do
      schema = schema_for(:amount, property(type: :number))

      expect(schema.call(amount: "4.5").to_h[:amount]).to eq(4.5)
    end

    it "coerces integer" do
      schema = schema_for(:count, property(type: :integer))

      expect(schema.call(count: "42").to_h[:count]).to eq(42)
    end

    it "coerces boolean" do
      schema = schema_for(:active, property(type: :boolean))

      expect(schema.call(active: "true").to_h[:active]).to be true
    end

    it "accepts nil for a nullable scalar" do
      schema = schema_for(:name, property(type: :string, nullable: true))

      expect(schema.call(name: nil).success?).to be true
    end

    it "rejects nil for a non-nullable scalar" do
      schema = schema_for(:name, property(type: :string, nullable: false))

      expect(schema.call(name: nil).success?).to be false
    end
  end

  describe "string constraints" do
    it "enforces min_length" do
      schema = schema_for(:name, property(type: :string, min_length: 3))

      expect(schema.call(name: "ab").success?).to be false
      expect(schema.call(name: "abc").success?).to be true
    end

    it "enforces max_length" do
      schema = schema_for(:name, property(type: :string, max_length: 3))

      expect(schema.call(name: "abcd").success?).to be false
      expect(schema.call(name: "abc").success?).to be true
    end

    it "enforces pattern" do
      schema = schema_for(:code, property(type: :string, pattern: '\A[A-Z]+\z'))

      expect(schema.call(code: "abc").success?).to be false
      expect(schema.call(code: "ABC").success?).to be true
    end

    it "compiles the pattern with the configured per-match timeout" do
      Raxon.configuration.regexp_timeout = 0.25

      # Ruby raises Regexp::TimeoutError on any match that exceeds this, capping
      # a ReDoS pattern's CPU cost on hostile input.
      expect(builder.send(:compile_pattern, "^(a+)+$").timeout).to eq(0.25)
    end

    it "compiles the pattern without a timeout when regexp_timeout is nil" do
      Raxon.configuration.regexp_timeout = nil

      compiled = builder.send(:compile_pattern, '\A[A-Z]+\z')
      expect(compiled.timeout).to be_nil

      schema = schema_for(:code, property(type: :string, pattern: '\A[A-Z]+\z'))
      expect(schema.call(code: "ABC").success?).to be true
    end

    it "rejects an oversized value on max_length without running the pattern" do
      # dry-schema chains predicates with a short-circuiting AND in declaration
      # order, so emitting max_size? before format? means a too-long value is
      # rejected on length and the regexp never sees it. That ordering is the
      # structural half of the ReDoS defense (the timeout is the other half),
      # and it is silently lost if dry_constraints_for is ever reordered — hence
      # this test.
      #
      # Timeout disabled so the only thing standing between this catastrophically
      # backtracking pattern and a hung CPU is the ordering itself.
      Raxon.configuration.regexp_timeout = nil
      schema = schema_for(:code, property(type: :string, max_length: 10, pattern: "^(a+)+$"))

      result = nil
      expect {
        Timeout.timeout(5) { result = schema.call(code: "#{"a" * 60}!") }
      }.not_to raise_error

      expect(result.success?).to be false
      expect(result.errors.to_h[:code]).to eq(["size cannot be greater than 10"])
    end

    it "applies the pattern unanchored, matching OpenAPI semantics" do
      # A declared pattern is a *search*, not a full-string match, on both the
      # OpenAPI side and here — consistent, but easy to misread as anchored.
      # Authors who want a whole-string match must anchor with \A and \z.
      unanchored = schema_for(:code, property(type: :string, pattern: "[A-Z]+"))
      anchored = schema_for(:code, property(type: :string, pattern: '\A[A-Z]+\z'))

      expect(unanchored.call(code: "xxABCxx").success?).to be true
      expect(anchored.call(code: "xxABCxx").success?).to be false
    end
  end

  describe "numeric constraints" do
    it "enforces minimum/maximum on integers" do
      schema = schema_for(:n, property(type: :integer, minimum: 1, maximum: 10))

      expect(schema.call(n: "0").success?).to be false
      expect(schema.call(n: "11").success?).to be false
      expect(schema.call(n: "5").success?).to be true
    end

    it "enforces minimum/maximum on floats" do
      schema = schema_for(:n, property(type: :number, minimum: 1.5, maximum: 2.5))

      expect(schema.call(n: "1.0").success?).to be false
      expect(schema.call(n: "2.0").success?).to be true
    end
  end

  describe "object fields" do
    it "validates nested properties" do
      schema = schema_for(:profile, property(
        type: :object,
        properties: {bio: property(type: :string), age: property(type: :integer)}
      ))

      result = schema.call(profile: {bio: "hi", age: "30"})
      expect(result.success?).to be true
      expect(result.to_h[:profile]).to eq(bio: "hi", age: 30)

      expect(schema.call(profile: {bio: "hi"}).success?).to be false
    end

    it "treats a propertyless object as a plain hash" do
      schema = schema_for(:meta, property(type: :object))

      expect(schema.call(meta: {any: "thing"}).success?).to be true
      expect(schema.call(meta: "not-a-hash").success?).to be false
    end

    it "accepts nil for a nullable object" do
      schema = schema_for(:meta, property(type: :object, nullable: true))

      expect(schema.call(meta: nil).success?).to be true
    end
  end

  describe "array fields" do
    it "validates an array of scalars" do
      schema = schema_for(:tags, property(type: :array, of: :string))

      expect(schema.call(tags: %w[a b]).to_h[:tags]).to eq(%w[a b])
    end

    it "coerces array element types" do
      schema = schema_for(:ids, property(type: :array, of: :integer))

      expect(schema.call(ids: %w[1 2]).to_h[:ids]).to eq([1, 2])
    end

    it "enforces min_items/max_items at the array level" do
      schema = schema_for(:tags, property(type: :array, of: :string, min_items: 1, max_items: 2))

      expect(schema.call(tags: []).success?).to be false
      expect(schema.call(tags: %w[a b c]).success?).to be false
      expect(schema.call(tags: %w[a]).success?).to be true
    end

    it "validates an array of objects" do
      schema = schema_for(:items, property(
        type: :array,
        properties: {sku: property(type: :string)}
      ))

      expect(schema.call(items: [{sku: "x"}]).success?).to be true
      expect(schema.call(items: [{}]).success?).to be false
    end

    it "accepts nil for a nullable array" do
      schema = schema_for(:tags, property(type: :array, of: :string, nullable: true))

      expect(schema.call(tags: nil).success?).to be true
    end
  end

  describe "file fields" do
    it "requires a value when not nullable" do
      schema = schema_for(:upload, property(type: :file))

      expect(schema.call(upload: "data").success?).to be true
      expect(schema.call(upload: nil).success?).to be false
    end

    it "accepts nil when nullable" do
      schema = schema_for(:upload, property(type: :file, nullable: true))

      expect(schema.call(upload: nil).success?).to be true
    end
  end

  describe "enum constraints" do
    it "enforces a scalar enum via included_in?" do
      schema = schema_for(:format, property(type: :string, enum: %w[pdf png]))

      expect(schema.call(format: "pdf").success?).to be true
      expect(schema.call(format: "gif").success?).to be false
    end

    it "constrains each element of an array, not the array itself" do
      schema = schema_for(:formats, property(type: :array, of: :string, enum: %w[pdf png]))

      expect(schema.call(formats: %w[pdf png]).success?).to be true
      expect(schema.call(formats: %w[pdf gif]).success?).to be false
    end

    it "applies an element enum alongside array-level item counts" do
      schema = schema_for(:formats, property(
        type: :array, of: :string, enum: %w[pdf png], min_items: 1
      ))

      expect(schema.call(formats: []).success?).to be false
      expect(schema.call(formats: %w[pdf]).success?).to be true
      expect(schema.call(formats: %w[gif]).success?).to be false
    end

    it "falls back to allowable_values when enum is absent" do
      schema = schema_for(:format, property(type: :string, allowable_values: %w[pdf png]))

      expect(schema.call(format: "pdf").success?).to be true
      expect(schema.call(format: "gif").success?).to be false
    end

    it "prefers enum over allowable_values" do
      schema = schema_for(:format, property(
        type: :string, enum: %w[pdf], allowable_values: %w[png]
      ))

      expect(schema.call(format: "pdf").success?).to be true
      expect(schema.call(format: "png").success?).to be false
    end

    it "resolves a deferred (callable) enum" do
      allowed = %w[pdf png]
      schema = schema_for(:format, property(type: :string, enum: -> { allowed }))

      expect(schema.call(format: "pdf").success?).to be true
      expect(schema.call(format: "gif").success?).to be false
    end
  end

  describe "entry points" do
    it "adds a parameter by its name" do
      param = Raxon::OpenApi::Parameter.new(:id, type: :string, in: :path, required: true)
      b = builder
      schema = Dry::Schema.Params { b.add_parameter_to_schema(self, param) }

      expect(schema.call(id: "42").success?).to be true
      expect(schema.call({}).success?).to be false
    end

    it "adds a collection of properties" do
      properties = {name: property(type: :string), age: property(type: :integer, required: false)}
      b = builder
      schema = Dry::Schema.Params { b.add_properties_to_schema(self, properties) }

      expect(schema.call(name: "x", age: "1").to_h).to eq(name: "x", age: 1)
      expect(schema.call({}).success?).to be false
    end
  end
end

RSpec.describe Raxon::OpenApi::PropertySchemaBuilder, "arrays of objects" do
  subject(:builder) { described_class.new }

  def schema_for(field_name, field)
    b = builder
    Dry::Schema.Params do
      b.add_field_to_schema(self, field_name, field)
    end
  end

  def array_of_objects(**options)
    Raxon::OpenApi::Property.new(type: :array, of: :object, **options).tap do |property|
      property.property :name, type: :string, required: true
    end
  end

  it "accepts nil and validates items for nullable arrays of objects" do
    schema = schema_for(:rows, array_of_objects(nullable: true))

    expect(schema.call(rows: nil)).to be_success
    expect(schema.call(rows: [{name: "a"}])).to be_success
    expect(schema.call(rows: [{}])).not_to be_success
  end

  it "enforces array constraints alongside item validation" do
    schema = schema_for(:rows, array_of_objects(min_items: 2))

    expect(schema.call(rows: [{name: "a"}])).not_to be_success
    expect(schema.call(rows: [{name: "a"}, {}])).not_to be_success
    expect(schema.call(rows: [{name: "a"}, {name: "b"}])).to be_success
  end

  it "treats of: :object without declared properties as a plain array" do
    field = Raxon::OpenApi::Property.new(type: :array, of: :object)
    schema = schema_for(:rows, field)

    expect(schema.call(rows: [{"anything" => 1}, {}])).to be_success
    expect(schema.call(rows: "not-an-array")).not_to be_success
  end
end
