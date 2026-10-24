# frozen_string_literal: true

module Raxon
  # Base module for template helper methods.
  #
  # Every template renders on a {ViewContext}, which includes this module.
  # Applications reopen it, usually in a file under +config.helpers_path+, to
  # make methods available to all templates.
  #
  # A helper that returns markup must wrap it with +raw+, or the template
  # escapes it.
  #
  # @example
  #   module Raxon::ViewHelpers
  #     def link_to(text, href)
  #       raw(%(<a href="#{h(href)}">#{h(text)}</a>))
  #     end
  #   end
  #
  # @see ViewContext
  module ViewHelpers
  end
end
