# frozen_string_literal: true

# Raxon has no runtime dependency on ActiveRecord, so lib/raxon.rb only
# autoloads this file. It loads when an application first names
# Raxon::SqlJson, and by then the application must have loaded ActiveRecord.
defined?(::ActiveRecord::Base) or raise Raxon::Error, "Raxon::SqlJson needs ActiveRecord: require \"active_record\" before you use it"

module Raxon
  # Builds a JSON response body in Postgres, in one query, from a
  # declaration that reads like an Alba resource. See Raxon::SqlJson::Resource.
  module SqlJson
  end
end

require_relative "sql_json/resource"
require_relative "sql_json/component_builder"
