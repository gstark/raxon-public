# frozen_string_literal: true

module Raxon
  # Registry linking an OpenAPI component to an object-to-data adapter.
  class RepresentationRegistry
    Entry = Data.define(:component, :resource, :adapter)

    def initialize
      @entries = {}
    end

    def register(component, resource, adapter: AlbaAdapter.new)
      @entries[resource] = Entry.new(component.to_sym, resource, adapter)
    end

    def fetch(resource)
      @entries.fetch(resource) { raise Error, "No representation registered for #{resource}" }
    end

    class AlbaAdapter
      def call(resource, value, collection: false, params: {})
        return value.map { |item| call(resource, item, params: params) } if collection

        resource.new(value, params).serializable_hash
      end
    end
  end
end
