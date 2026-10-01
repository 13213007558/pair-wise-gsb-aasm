# frozen_string_literal: true

module AASM
  module Analysis
    # Declarative description of how a concrete AASM definition is turned into
    # a finite, side-effect free abstract model.
    #
    #   AASM::Analysis::Abstraction.new do |model|
    #     model.variable :paid, values: [true, false], initial: false
    #     model.condition :paid? { |ctx| ctx.paid? }
    #     model.invariant('never shipped while unpaid') do |ctx|
    #       !(ctx.state(:shipping) == :shipped && ctx.paid? == false)
    #     end
    #   end
    class Abstraction
      Variable = Struct.new(:name, :values, :initial, keyword_init: true)
      Invariant = Struct.new(:name, :block, keyword_init: true)
      EventEffect = Struct.new(:machine, :event, :block, keyword_init: true)

      attr_accessor :budget
      attr_reader :conditions, :variables, :invariants, :effects

      def initialize(budget: Analyzer::DEFAULT_BUDGET, &block)
        @conditions = {}
        @variables = {}
        @invariants = []
        @effects = []
        @budget = budget
        block.call(self) if block
      end

      # Declare a finite abstract variable.
      #
      # +values+  - the finite domain of the variable
      # +initial+ - optional fixed initial value; when omitted the analysis
      #            starts from every value in the domain
      def variable(name, values:, initial: nil)
        name = name.to_sym
        values = Array(values)
        raise ArgumentError, "Variable :#{name} needs a non-empty domain" if values.empty?
        unless initial.nil? || values.include?(initial)
          raise ArgumentError, "Initial value #{initial.inspect} is not in domain of :#{name}"
        end
        @variables[name] = Variable.new(name: name, values: values, initial: initial)
      end

      # Provide a finite, side-effect free condition that abstracts a guard
      # callback. The token is whatever was passed as +:guard+/+:guards+/+:if+
      # (a Symbol/String method name or a Proc/Class object).
      def condition(token, &block)
        raise ArgumentError, 'A condition needs a block' unless block

        @conditions[token] = block
      end
      alias_method :abstract_guard, :condition
      alias_method :predicate, :condition

      # Declare the finite effect of an event on the abstract variables.
      #
      # The block receives the pre-event {Context} and must return a Hash of
      # variable assignments (only the variables that change). Variables not
      # mentioned by an effect persist unchanged across the event.
      #
      #   model.effect :pay do |ctx|
      #     { paid: true }
      #   end
      #
      # When event names collide across named machines, scope the event:
      #   model.effect [:shipping, :pay] { |ctx| { ... } }
      def effect(event, machine = nil, &block)
        raise ArgumentError, 'An effect needs a block' unless block

        if event.is_a?(Array)
          machine, event_name = event.map(&:to_sym)
        else
          event_name = event.to_sym
          machine = machine && machine.to_sym
        end
        @effects << EventEffect.new(machine: machine, event: event_name, block: block)
      end

      # @return [Proc, nil] the effect block for an event on a machine
      def effect_for(machine, event)
        exact = @effects.find { |e| e.machine == machine.to_sym && e.event == event.to_sym }
        return exact.block if exact

        unscoped = @effects.select { |e| e.machine.nil? && e.event == event.to_sym }
        raise AmbiguousEventEffect, "multiple unscoped effects for event #{event.inspect}; scope them with [:machine, :event]" if unscoped.size > 1

        unscoped.first&.block
      end

      # Declare a finite-state invariant over the combination of all analyzed
      # state machines. Returns a truthy value when the combination is legal.
      def invariant(name = "invariant #{@invariants.size + 1}", &block)
        raise ArgumentError, 'An invariant needs a block' unless block

        @invariants << Invariant.new(name: name, block: block)
      end

      # Evaluate the condition registered for a guard token. Returns true when
      # no condition is registered; the analyzer treats this "unknown" result
      # separately and refuses to report safety when it affects reachability.
      def evaluate(token, context)
        block = @conditions[token]
        return :unknown if block.nil?

        result = block.call(context)
        !!result
      end
    end
  end
end
