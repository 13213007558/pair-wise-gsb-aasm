# frozen_string_literal: true

module AASM
  module Analysis
    # A read-only evaluation context handed to abstract guard conditions and
    # to declared invariants during analysis.
    #
    # It exposes the currently assumed state of every analyzed state machine
    # plus the current assignment of the abstract variables. Conditions must
    # be finite and side-effect free: they may only read from this context and
    # return a boolean-ish result.
    class Context
      # @param states [Hash{Symbol => Symbol}] machine name => state name
      # @param variables [Hash{Symbol => Object}] variable name => value
      def initialize(states, variables = {})
        @states = states
        @variables = variables
      end

      # @return [Symbol] the state of the given (or default) state machine
      def state(machine = :default)
        @states.fetch(machine.to_sym)
      end

      # Predicate form:
      #   context.state?(:shipped)              # default machine
      #   context.state?(:logistics, :shipped)  # named machine
      def state?(machine_or_state, maybe_state = nil)
        if maybe_state.nil?
          @states.fetch(:default) == machine_or_state.to_sym
        else
          @states.fetch(machine_or_state.to_sym) == maybe_state.to_sym
        end
      end

      # @return [Object] the value of an abstract variable
      def variable(name)
        raise UnknownVariable, "Unknown abstract variable :#{name}" unless @variables.key?(name.to_sym)

        @variables.fetch(name.to_sym)
      end
      alias_method :var, :variable

      # Convenience predicates for boolean abstract variables, e.g.
      # `context.paid?`.
      def method_missing(name, *args)
        variable_name = name.to_s.chomp('?').to_sym
        if args.empty? && !name.end_with?('=') && @variables.key?(variable_name)
          @variables.fetch(variable_name)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        variable_name = name.to_s.chomp('?').to_sym
        @variables.key?(variable_name) || super
      end

      # @return [Hash] a frozen snapshot of the machine states
      def states
        @states
      end

      # @return [Hash] a frozen snapshot of the abstract variable assignment
      def variables
        @variables
      end
    end
  end
end
