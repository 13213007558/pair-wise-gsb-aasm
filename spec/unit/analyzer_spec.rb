require 'spec_helper'

class AnalyzerOrderExample
  include AASM

  aasm :payment do
    state :unpaid, initial: true
    state :paid
    state :refunded

    event :pay do
      transitions from: :unpaid, to: :paid
    end

    event :refund do
      transitions from: :paid, to: :refunded
    end
  end

  aasm :shipment do
    state :pending, initial: true
    state :shipped
    state :delivered

    event :ship, guard: :paid? do
      transitions from: :pending, to: :shipped
    end

    event :deliver do
      transitions from: :shipped, to: :delivered
    end
  end

  def paid?
    aasm(:payment).current_state == :paid
  end
end

class AnalyzerBadOrderExample
  include AASM

  aasm :payment do
    state :unpaid, initial: true
    state :paid

    event :pay do
      transitions from: :unpaid, to: :paid
    end
  end

  aasm :shipment do
    state :pending, initial: true
    state :shipped

    event :ship do
      transitions from: :pending, to: :shipped
    end
  end
end

class AnalyzerShortestTraceExample
  include AASM

  aasm do
    state :a, initial: true
    state :b
    state :c
    state :d
    state :e

    event :e1 do
      transitions from: :a, to: :b
    end

    event :e2 do
      transitions from: :b, to: :d
    end

    event :e3 do
      transitions from: :a, to: :c
    end

    event :e4 do
      transitions from: :c, to: :e
    end

    event :e5 do
      transitions from: :e, to: :d
    end
  end
end

class AnalyzerProcGuardExample
  include AASM

  PAID_GUARD = -> { paid? }

  aasm :payment do
    state :unpaid, initial: true
    state :paid

    event :pay do
      transitions from: :unpaid, to: :paid
    end
  end

  aasm :shipment do
    state :pending, initial: true
    state :shipped

    event :ship, guard: PAID_GUARD do
      transitions from: :pending, to: :shipped
    end
  end

  def paid?
    aasm(:payment).current_state == :paid
  end
end

class AnalyzerUnlessExample
  include AASM

  aasm do
    state :open, initial: true
    state :closed

    event :close, unless: :locked? do
      transitions from: :open, to: :closed
    end
  end

  def locked?
    false
  end
end

class AnalyzerStringGuardExample
  include AASM

  aasm do
    state :open, initial: true
    state :closed

    event :close, guard: 'ready?' do
      transitions from: :open, to: :closed
    end
  end

  def ready?
    true
  end
end

describe AASM::Analyzer do
  let(:never_shipped_while_unpaid) do
    lambda do |combo|
      !(combo[:shipment] == :shipped && combo[:payment] == :unpaid)
    end
  end

  describe 'a safe combination of named state machines' do
    let(:analyzer) do
      AASM::Analyzer.new(AnalyzerOrderExample).tap do |a|
        a.abstract_condition(:paid?) { |c| c[:payment] == :paid }
        a.invariant('never shipped while unpaid', &never_shipped_while_unpaid)
      end
    end

    it 'reports :safe when no reachable combination violates the invariant' do
      result = analyzer.check

      expect(result.status).to eq(:safe)
      expect(result).to be_safe
      expect(result).not_to be_violated
      expect(result).not_to be_incomplete
      expect(result.trace).to be_nil
      expect(result.explored_states).to eq(7)
    end

    it 'is read-only and leaves instances and definitions untouched' do
      analyzer.check

      order = AnalyzerOrderExample.new
      expect(order.aasm(:payment).current_state).to eq(:unpaid)
      expect(order.aasm(:shipment).current_state).to eq(:pending)
      expect(AnalyzerOrderExample.aasm(:shipment).events.map(&:name)).to eq([:ship, :deliver])
    end

    it 'can be checked repeatedly with the same result' do
      expect(analyzer.check.status).to eq(:safe)
      expect(analyzer.check.status).to eq(:safe)
    end

    it 'supports restricting the analysis to selected machines' do
      result = AASM::Analyzer.new(AnalyzerOrderExample, machines: [:payment]).check

      expect(result).to be_safe
      expect(result.explored_states).to eq(3)
    end
  end

  describe 'a violated invariant' do
    let(:analyzer) do
      AASM::Analyzer.new(AnalyzerBadOrderExample).tap do |a|
        a.invariant('never shipped while unpaid', &never_shipped_while_unpaid)
      end
    end

    it 'reports :violated with the shortest event sequence' do
      result = analyzer.check

      expect(result.status).to eq(:violated)
      expect(result).to be_violated
      expect(result.trace).to eq([{ machine: :shipment, event: :ship }])
      expect(result.violated_invariant).to eq('never shipped while unpaid')
    end

    it 'replays the trace in the abstract model and lands in a violating combination' do
      result = analyzer.check

      expect(result.combination).to eq(payment: :unpaid, shipment: :shipped)
      expect(never_shipped_while_unpaid.call(result.combination)).to be(false)
      expect(analyzer.replay(result.trace)).to eq(result.combination)
    end

    it 'finds the shortest trace among several violating paths' do
      result = AASM::Analyzer.new(AnalyzerShortestTraceExample).tap { |a|
        a.invariant('never d') { |c| c[:default] != :d }
      }.check

      expect(result).to be_violated
      expect(result.trace).to eq([
        { machine: :default, event: :e1 },
        { machine: :default, event: :e2 }
      ])
      expect(result.combination).to eq(default: :d)
    end

    it 'detects violations already present in the initial combination' do
      result = AASM::Analyzer.new(AnalyzerBadOrderExample).tap { |a|
        a.invariant('never unpaid') { |c| c[:payment] != :unpaid }
      }.check

      expect(result).to be_violated
      expect(result.trace).to eq([])
      expect(result.combination).to eq(payment: :unpaid, shipment: :pending)
    end
  end

  describe 'unabstracted Ruby callbacks' do
    it 'reports :incomplete (never :safe) when a guard has no abstract condition' do
      result = AASM::Analyzer.new(AnalyzerOrderExample).tap { |a|
        a.invariant('never shipped while unpaid', &never_shipped_while_unpaid)
      }.check

      expect(result.status).to eq(:incomplete)
      expect(result).not_to be_safe
      expect(result.reason).to eq(:unabstracted_callback)
      expect(result.unabstracted_callbacks).to contain_exactly(
        AASM::Analyzer::UnabstractedCallback.new(:shipment, :ship, :paid?)
      )
    end

    it 'supports abstract conditions keyed by the exact Proc object' do
      analyzer = AASM::Analyzer.new(AnalyzerProcGuardExample)
      analyzer.abstract_condition(AnalyzerProcGuardExample::PAID_GUARD) { |c| c[:payment] == :paid }
      analyzer.invariant('never shipped while unpaid', &never_shipped_while_unpaid)

      expect(analyzer.check).to be_safe
    end

    it 'reports :incomplete for unabstracted Proc guards' do
      result = AASM::Analyzer.new(AnalyzerProcGuardExample).check

      expect(result).to be_incomplete
      expect(result.reason).to eq(:unabstracted_callback)
      expect(result.unabstracted_callbacks.map(&:callback)).to eq([AnalyzerProcGuardExample::PAID_GUARD])
    end

    it 'matches string guards against symbol abstractions' do
      analyzer = AASM::Analyzer.new(AnalyzerStringGuardExample)
      analyzer.abstract_condition(:ready?) { true }
      analyzer.invariant('never closed') { |c| c[:default] != :closed }

      result = analyzer.check
      expect(result).to be_violated
      expect(result.trace).to eq([{ machine: :default, event: :close }])
    end
  end

  describe 'unless conditions' do
    it 'treats unless callbacks as guards that need abstraction' do
      analyzer = AASM::Analyzer.new(AnalyzerUnlessExample)
      analyzer.abstract_condition(:locked?) { false }
      analyzer.invariant('never closed') { |c| c[:default] != :closed }

      result = analyzer.check
      expect(result).to be_violated
      expect(result.trace).to eq([{ machine: :default, event: :close }])
    end

    it 'blocks the transition when the abstract unless condition holds' do
      analyzer = AASM::Analyzer.new(AnalyzerUnlessExample)
      analyzer.abstract_condition(:locked?) { true }
      analyzer.invariant('never closed') { |c| c[:default] != :closed }

      expect(analyzer.check).to be_safe
    end
  end

  describe 'state budget' do
    it 'reports :incomplete (never :safe) when the budget is exceeded' do
      analyzer = AASM::Analyzer.new(AnalyzerOrderExample)
      analyzer.abstract_condition(:paid?) { |c| c[:payment] == :paid }
      analyzer.invariant('never shipped while unpaid', &never_shipped_while_unpaid)

      result = analyzer.check(state_budget: 2)

      expect(result.status).to eq(:incomplete)
      expect(result).not_to be_safe
      expect(result.reason).to eq(:state_budget_exceeded)
    end

    it 'accepts a default budget set on the analyzer' do
      analyzer = AASM::Analyzer.new(AnalyzerOrderExample, state_budget: 1)
      analyzer.abstract_condition(:paid?) { |c| c[:payment] == :paid }

      expect(analyzer.check.reason).to eq(:state_budget_exceeded)
    end
  end

  describe 'replay' do
    it 'returns nil for traces that cannot be replayed' do
      analyzer = AASM::Analyzer.new(AnalyzerOrderExample)
      analyzer.abstract_condition(:paid?) { |c| c[:payment] == :paid }

      expect(analyzer.replay([{ machine: :shipment, event: :unknown_event }])).to be_nil
    end

    it 'keeps the state unchanged when an event cannot fire' do
      analyzer = AASM::Analyzer.new(AnalyzerOrderExample)
      analyzer.abstract_condition(:paid?) { |c| c[:payment] == :paid }

      combination = analyzer.replay([{ machine: :shipment, event: :ship }])
      expect(combination).to eq(payment: :unpaid, shipment: :pending)
    end
  end
end

