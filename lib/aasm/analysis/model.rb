# frozen_string_literal: true

module AASM
  module Analysis
    # Static, read-only projection of one or more AASM state machines.
    #
    # The model never instantiates the analyzed class, never fires an event
    # and never invokes Ruby callbacks. Guard callbacks are only interpreted
    # through the conditions supplied in the {Abstraction}.
    class Model
      Candidate = Struct.new(:machine, :event, :transition, keyword_init: true)

      attr_reader :klass, :machines, :states, :initial_states, :events, :blockers

      def initialize(klass, machine_names: nil)
        @klass = klass
        @blockers = []

        store = AASM::StateMachineStore.fetch(klass, true)
        available = store ? store.machine_names.map(&:to_sym) : []
        raise NoStateMachines, "#{klass} does not define any AASM state machines" if available.empty?

        names = machine_names ? Array(machine_names).map(&:to_sym) : available.sort
        unknown = names - available
        unless unknown.empty?
          raise UnknownStateMachine, "Unknown state machine(s) #{unknown.map(&:inspect).join(', ')} on #{klass}"
        end

        @machines = names
        @states = {}
        @initial_states = {}
        @events = {}

        names.each { |name| load_machine(store.machine(name)) }
        detect_binding_events(store, available)
      end

      # Ordered event candidates leaving +state+ of one machine, preserving
      # both event definition order and transition definition order. The
      # analyzer applies AASM's first-match-wins rule to these candidates.
      #
      # Wildcard transitions (no +:from+) match any state, exactly as the
      # runtime does.
      def candidates_for(machine, state)
        @events.fetch(machine).filter_map do |event_name, event|
          transitions = event.transitions.select do |transition|
            transition.from.nil? || transition.from == state
          end
          next nil if transitions.empty?

          [event_name, transitions.map do |transition|
            Candidate.new(machine: machine, event: event_name, transition: transition)
          end]
        end
      end

      # Evaluate the guards of one transition.
      #
      # @return [:enabled] every guard has a condition and it passes
      # @return [:disabled] at least one condition deterministically blocks it
      # @return [Array(:unknown, tokens)] no decisive block, but some guards
      #   lack an abstract condition
      def evaluate_transition(transition, context, abstraction)
        unknown_tokens = []

        transition.guards.each do |token|
          result = abstraction.evaluate(token, context)
          unknown_tokens << token if result == :unknown
          return :disabled if result == false
        end

        transition.unless_guards.each do |token|
          result = abstraction.evaluate(token, context)
          unknown_tokens << token if result == :unknown
          return :disabled if result == true
        end

        unknown_tokens.empty? ? :enabled : [:unknown, unknown_tokens]
      end

      private

      def load_machine(machine)
        name = machine.name.to_sym

        if machine.initial_state.nil? || machine.initial_state.is_a?(Proc)
          @blockers << [:dynamic_initial_state, name, machine.initial_state]
          @initial_states[name] = nil
        else
          @initial_states[name] = machine.initial_state.to_sym
        end

        state_names = machine.states.map { |state| state.name.to_sym }
        @states[name] = state_names

        @events[name] = {}
        machine.events.each_value do |event|
          @events[name][event.name.to_sym] = event
        end
      end

      def detect_binding_events(store, all_machine_names)
        # An event on *any* machine of the class may auto-fire another event
        # through :binding_event (including a machine not part of this
        # analysis). Such Ruby-driven state changes cannot be reproduced by
        # the abstract graph, so they force an incomplete result.
        all_machine_names.each do |name|
          machine = store.machine(name)
          next unless machine

          machine.events.each_value do |event|
            if event.options[:binding_event]
              blocker = [:binding_event, name.to_sym, event.name.to_sym, event.options[:binding_event]]
              @blockers << blocker unless @blockers.include?(blocker)
            end
          end
        end
      end

    end
  end
end
