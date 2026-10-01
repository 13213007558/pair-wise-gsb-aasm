# frozen_string_literal: true

module AASM
  # Read-only, test-time analysis of state-machine definitions.
  #
  # The analyzer builds a finite abstract model from the state machines
  # registered on a class, interprets guards through finite side-effect free
  # conditions, explores reachable state combinations from the initial states
  # and checks finite-state invariants. It never instantiates the analyzed
  # class, fires events or executes Ruby callbacks.
  module Analysis
    # Build an abstract model and run the reachability analysis for +klass+.
    #
    # @param klass [Class] class that includes AASM
    # @param machine_names [Array<Symbol>, nil] named machines to analyze;
    #   when omitted every registered machine participates
    # @param abstraction [Abstraction, nil] pre-built abstraction, useful when
    #   the same abstraction is reused or built programmatically
    # @param budget [Integer, nil] maximum number of state combinations to
    #   explore; overrides the abstraction's budget when given
    # @yield [Abstraction] DSL block declaring variables, conditions and
    #   invariants
    # @return [Result]
    def self.analyze(klass, machine_names: nil, abstraction: nil, budget: nil)
      spec = abstraction || Abstraction.new
      spec.budget = budget if budget
      yield spec if block_given?

      model = Model.new(klass, machine_names: machine_names)
      Analyzer.new(model, spec).analyze
    end

  end
end
