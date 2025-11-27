# frozen_string_literal: true

module Raxon
  # Base module for handler helper methods.
  #
  # This module is extended into the execution context of endpoint handlers,
  # making all defined methods available within handler blocks.
  #
  # Helper methods can be added in two ways:
  # 1. Directly in this module (framework-level helpers)
  # 2. Auto-loaded from a configured directory (application-level helpers)
  #
  # @example Using helpers in a handler
  #   endpoint.handler do |request, response|
  #     some_helper_method(request, response)
  #   end
  #
  # @see Configuration#helpers_path
  module HandlerHelpers
    # This module is intentionally empty by default.
    # Helper methods can be added by:
    # - Defining methods directly in this module
    # - Auto-loading modules from the configured helpers_path
  end
end
