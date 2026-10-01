# frozen_string_literal: true

module AASM
  module Analysis
    # Outcome of an {Analyzer} run.
    #
    # A result is always in exactly one of three states:
    #
    # * +:safe+        - the whole reachable state space was explored and every
    #                   reachable combination satisfies every invariant
    # * +:violation+   - a reachable combination breaks an invariant; a shortest
    #                   witness event sequence is attached
    # * +:incomplete+  - the abstract model could not cover the concrete one
    #                   (unabstracted reachable guard, dynamic initial state,
    #                   auto-firing callback or a blown state budget); safety is
    #                   never reported in this case
    class Result
      attr_reader :status, :model, :abstraction, :blockers,
                  :root_states, :root_variables,
                  :violated_invariant, :path, :combinations_explored

      def initialize(status, model:, abstraction:, blockers: [], violated_invariant: nil, path: [],
                     combinations_explored: 0, root_states: model.initial_states, root_variables: {})
        @status = status
        @model = model
        @abstraction = abstraction
        @blockers = blockers
        @violated_invariant = violated_invariant
        @path = path
        @combinations_explored = combinations_explored
        @root_states = root_states
        @root_variables = root_variables
      end

      def safe?
        @status == :safe
      end

      def violation?
        @status == :violation
      end

      def incomplete?
        @status == :incomplete
      end

      # @return [Boolean] true when the witness is fully justified by declared
      #   conditions (no unabstracted guard was relied upon)
      def certain?
        @status == :violation && @path.all? { |step| step[:certain] }
      end

      # Shortest event sequence that reaches the violating combination.
      # @return [Array<Symbol>]
      def events
        @path.map { |step| step[:event] }
      end

      # @return [Hash{Symbol => Symbol}] final machine-name => state mapping
      def final_states
        @path.empty? ? @root_states : @path.last[:states]
      end

      # @return [Hash{Symbol => Object}] final abstract variable assignment
      def final_variables
        @path.empty? ? @root_variables : @path.last[:variables]
      end

      # Replay the returned event sequence against the abstract model and
      # assert that it really ends on a combination that breaks an invariant.
      #
      # This never instantiates the analyzed class and never executes Ruby
      # callbacks; it re-evaluates only declared abstract conditions.
      #
      # @raise [ReplayMismatch] if the recorded witness cannot be reproduced
      # @return [Hash] the replayed final states and variables
      def replay!
        raise ReplayMismatch, 'cannot replay a non-violation result' unless violation?

        Analyzer.new(model, abstraction).replay_path(
          path,
          violated_invariant.name,
          root_states,
          root_variables
        )
      end
    end
  end
end
