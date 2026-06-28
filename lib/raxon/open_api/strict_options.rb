# frozen_string_literal: true

require "set"

module Raxon
  module OpenApi
    # Fail-fast guard against unknown keyword options on DSL objects.
    #
    # dry-initializer silently ignores keyword arguments it does not recognise,
    # so a typo'd or unsupported option (e.g. +enum:+ on a class that lacks it)
    # vanishes with no error and the generated OpenAPI contract is quietly wrong.
    # Including this module makes any unknown option raise +ArgumentError+ at
    # construction time, surfacing the mistake immediately — see the
    # No Silent Fallbacks tenet.
    #
    # Each including class still owns its +initialize+ signature (some take a
    # positional name); it just calls {#reject_unknown_options!} on the keyword
    # options before delegating to dry-initializer's +super+.
    module StrictOptions
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # The set of keyword option names this class accepts, derived from its
        # dry-initializer +option+ declarations. Positional +param+s are excluded.
        #
        # @return [Set<Symbol>]
        def known_option_names
          @known_option_names ||= dry_initializer.options.map(&:source).to_set
        end
      end

      private

      # Raise +ArgumentError+ if +options+ contains any key this class does not
      # declare as an +option+.
      #
      # @param options [Hash] the keyword options passed to the constructor
      # @raise [ArgumentError] when one or more keys are unknown
      # @return [void]
      def reject_unknown_options!(options)
        unknown = options.keys.map(&:to_sym).reject { |key| self.class.known_option_names.include?(key) }
        return if unknown.empty?

        raise ArgumentError,
          "unknown option#{"s" if unknown.size > 1} for #{self.class}: " \
          "#{unknown.map(&:inspect).join(", ")}. " \
          "Known options: #{self.class.known_option_names.to_a.sort.join(", ")}."
      end
    end
  end
end
