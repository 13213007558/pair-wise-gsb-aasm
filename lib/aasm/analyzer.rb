# frozen_string_literal: true

module AASM
  # A read-only reachability analyzer for AASM state machines.
  #
  # The analyzer never instantiates the inspected class and never fires
  # real events. It explores the finite product of the declared state
  # machines of a class (including multiple named state machines on the
  # same object), starting from the combination of their initial states,
  # and checks user-declared invariants over those combinations.
  #
  # Guards and +unless+ conditions are arbitrary Ruby callbacks, so a
  # read-only analysis cannot execute them. Instead, every guard that
  # takes part in the analysis must be given a finite, side-effect-free
  # *abstract condition*: a pure function from the state combination to a
  # boolean. When the analyzer meets a Ruby callback without an abstract
  # condition, or the number of explored combinations exceeds the state
  # budget, the result is +:incomplete+ and safety is never reported.
  #
  # When an invariant is violated, the analyzer returns the shortest
  # event sequence leading to the violation and replays it in the
  # abstract model to confirm that it really ends in a combination that
  # violates the invariant.
  #
  # Example:
  #
  #   analyzer = AASM::Analyzer.new(Order)
  #   analyzer.abstract_condition(:paid?) { |c| c[:payment] == :paid }
  #   analyzer.invariant('never shipped while unpaid') do |c|
  #     !(c[:shipment] == :shipped && c[:payment] == :unpaid)
  #   end
  #   result = analyzer.check
  #   result.status # => :safe, :violated or :incomplete
  #   result.trace  # => [{ machine: :shipment, event: :ship }, ...]
  #
  class Analyzer
    DEFAULT_STATE_BUDGET = 1_000

    # A guard/unless callback for which no abstract condition was declared.
    UnabstractedCallback = Struct.new(:machine, :event, :callback)

    # The outcome of an analysis run.
    class Result
      # One of :safe, :violated or :incomplete.
      attr_reader :status

      # For :violated, the shortest event sequence leading to the
      # violation, as an array of { machine:, event: } hashes.
      attr_reader :trace

      # For :violated, the name of the violated invariant and the
      # combination reached by replaying the trace.
      attr_reader :violated_invariant, :combination

      # Number of combinations explored before the analysis stopped.
      attr_reader :explored_states

      # For :incomplete, one of :unabstracted_callback,
      # :state_budget_exceeded, :unsupported_initial_state or
      # :replay_mismatch.
      attr_reader :reason

      # The guard/unless callbacks that had no abstract condition.
      attr_reader :unabstracted_callbacks

      def initialize(status, trace: nil, violated_invariant: nil, combination: nil,
                     explored_states: 0, reason: nil, unabstracted_callbacks: [])
        @status = status
        @trace = trace
        @violated_invariant = violated_invariant
        @combination = combination
        @explored_states = explored_states
        @reason = reason
        @unabstracted_callbacks = unabstracted_callbacks
      end

      def safe?
        status == :safe
      end

      def violated?
        status == :violated
      end

      def incomplete?
        status == :incomplete
      end
    end

    attr_reader :klass, :invariants

    def initialize(klass, machines: nil, state_budget: DEFAULT_STATE_BUDGET)
      @klass = klass.is_a?(Class) ? klass : klass.class
      @machine_filter = machines && Array(machines).map(&:to_sym)
      @state_budget = state_budget
      @abstractions = {}
      @invariants = []
    end

    # Declare a finite, side-effect-free abstract condition for a guard.
    #
    # +key+ is the guard itself: a method name (Symbol or String), or the
    # exact Proc/Class object used in the state machine definition.
    # The block receives the frozen state combination (a Hash mapping
    # machine names to state names) and must return a boolean.
    def abstract_condition(key, &block)
      raise ArgumentError, 'abstract_condition requires a block' unless block

      @abstractions[key] = block
      self
    end
    alias_method :abstract_guard, :abstract_condition

    # Declare a named invariant over state combinations. The block
    # receives the frozen combination and must return true while the
    # invariant holds.
    def invariant(name = nil, &block)
      raise ArgumentError, 'invariant requires a block' unless block

      @invariants << [(name || 'invariant_' + (@invariants.size + 1).to_s).to_s, block]
      self
    end

    # Explore the reachable combinations and check all invariants.
    def check(state_budget: @state_budget)
      machines = selected_machines
      initial = initial_combination(machines)
      unless initial
        return incomplete_result(:unsupported_initial_state, 0,
                                 [UnabstractedCallback.new(nil, nil, :initial_state)])
      end

      unabstracted = []
      visited = { initial => true }
      queue = [[initial, []]]
      explored = 0

      until queue.empty?
        combination, trace = queue.shift

        if (name = violated_invariant(combination))
          return violation_result(trace, name, explored, unabstracted)
        end

        explored += 1
        if explored > state_budget
          return incomplete_result(:state_budget_exceeded, explored, unabstracted)
        end

        each_successor(combination, machines, unabstracted) do |successor, step|
          next if visited.key?(successor)

          visited[successor] = true
          queue << [successor, trace + [step]]
        end
      end

      return incomplete_result(:unabstracted_callback, explored, unabstracted) unless unabstracted.empty?

      Result.new(:safe, explored_states: explored)
    end

    # Replay an event trace in the abstract model, starting from the
    # initial combination. Returns the final combination, or nil when the
    # trace cannot be replayed (e.g. it relies on unabstracted guards).
    def replay(trace)
      machines = selected_machines
      combination = initial_combination(machines)
      return nil unless combination

      trace.each do |step|
        combination = abstract_successor(combination, step[:machine], step[:event], machines)
        return nil unless combination
      end
      combination
    end

    private

    def selected_machines
      store = AASM::StateMachineStore.fetch(@klass, true)
      raise ArgumentError, @klass.to_s + ' does not include AASM' unless store

      machines = {}
      store.machine_names.each do |name|
        next if @machine_filter && !@machine_filter.include?(name.to_sym)

        machines[name.to_sym] = store.machine(name)
      end
      machines
    end

    def initial_combination(machines)
      combination = {}
      machines.each do |name, state_machine|
        initial = state_machine.initial_state
        return nil unless initial.is_a?(Symbol) || initial.is_a?(String)

        combination[name] = initial.to_sym
      end
      combination
    end

    def violated_invariant(combination)
      combination.freeze
      @invariants.each do |name, condition|
        return name unless condition.call(combination)
      end
      nil
    end

    def each_successor(combination, machines, unabstracted)
      machines.each do |machine_name, state_machine|
        current = combination[machine_name]
        state_machine.events.each_value do |event|
          transitions = event.transitions.select { |t| t.from.nil? || t.from == current }
          next if transitions.empty?

          transitions.each do |transition|
            decision = abstract_decision(transition, machine_name, event.name, combination, unabstracted)
            break if decision == :unknown

            next unless decision

            successor = combination.dup
            to = Array(transition.to).first
            successor[machine_name] = to.nil? ? current : to.to_sym
            yield successor, { machine: machine_name, event: event.name }
            break # only the first allowed transition fires
          end
        end
      end
    end

    # Returns true/false when every guard of the transition has an
    # abstract condition, or :unknown when at least one Ruby callback is
    # not abstracted (recording it in +unabstracted+).
    def abstract_decision(transition, machine_name, event_name, combination, unabstracted)
      guards, unlesses = transition_conditions(transition)

      missing = (guards + unlesses).reject { |c| decidable_literal?(c) || abstraction_for(c) }
      unless missing.empty?
        missing.each do |callback|
          entry = UnabstractedCallback.new(machine_name, event_name, callback)
          unabstracted << entry unless unabstracted.include?(entry)
        end
        return :unknown
      end

      guards.all? { |c| evaluate(c, combination) } &&
        unlesses.none? { |c| evaluate(c, combination) }
    end

    def transition_conditions(transition)
      opts = transition.opts
      guards = Array(opts[:guards]) + Array(opts[:guard]) + Array(opts[:if])
      unlesses = Array(opts[:unless])
      [guards.flatten, unlesses.flatten]
    end

    # Subjects that are neither method references (String/Symbol) nor
    # callable (Proc/Class) are not invoked by AASM's Invoker at all and
    # fall through to its default return value (true), so they are
    # decidable without an abstract condition.
    def decidable_literal?(callback)
      !callback.is_a?(Symbol) && !callback.is_a?(String) &&
        !callback.is_a?(Proc) && !callback.is_a?(Class)
    end

    def evaluate(callback, combination)
      return true if decidable_literal?(callback)

      !!abstraction_for(callback).call(combination)
    end

    def abstraction_for(callback)
      return @abstractions[callback] if @abstractions.key?(callback)

      if callback.is_a?(Symbol) || callback.is_a?(String)
        alternate = callback.is_a?(Symbol) ? callback.to_s : callback.to_sym
        return @abstractions[alternate] if @abstractions.key?(alternate)
      end
      nil
    end

    def abstract_successor(combination, machine_name, event_name, machines)
      machine_name = machine_name.to_sym
      state_machine = machines[machine_name]
      return nil unless state_machine

      event = state_machine.events[event_name.to_sym]
      return nil unless event

      current = combination[machine_name]
      transitions = event.transitions.select { |t| t.from.nil? || t.from == current }
      transitions.each do |transition|
        decision = abstract_decision(transition, machine_name, event.name, combination, [])
        return nil if decision == :unknown

        next unless decision

        successor = combination.dup
        to = Array(transition.to).first
        successor[machine_name] = to.nil? ? current : to.to_sym
        return successor
      end
      combination.dup # the event cannot fire: the state stays unchanged
    end

    def violation_result(trace, invariant_name, explored, unabstracted)
      replayed = replay(trace)
      violated = replayed && violated_invariant(replayed)
      return incomplete_result(:replay_mismatch, explored, unabstracted) unless violated

      Result.new(:violated,
                 trace: trace,
                 violated_invariant: violated,
                 combination: replayed,
                 explored_states: explored,
                 unabstracted_callbacks: unabstracted)
    end

    def incomplete_result(reason, explored, unabstracted)
      Result.new(:incomplete,
                 reason: reason,
                 explored_states: explored,
                 unabstracted_callbacks: unabstracted)
    end
  end
end

