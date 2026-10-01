# frozen_string_literal: true

require 'spec_helper'

module AnalysisSpec
  class ShippedOnlyAfterPaid
    include AASM

    attr_accessor :paid_amount

    aasm do
      state :unpaid, initial: true
      state :paid
      state :shipped

      event :pay do
        transitions from: :unpaid, to: :paid
      end

      event :ship do
        transitions from: :unpaid, to: :shipped, guard: :paid?
        transitions from: :paid, to: :shipped
      end
    end
  end

  class ShipBeforePaid
    include AASM

    aasm do
      state :unpaid, initial: true
      state :paid
      state :shipped

      event :pay do
        transitions from: :unpaid, to: :paid
      end

      event :ship do
        transitions from: :unpaid, to: :shipped
        transitions from: :paid, to: :shipped
      end
    end
  end

  class WithProcGuard
    include AASM

    aasm do
      state :a, initial: true
      state :b
      event :go do
        transitions from: :a, to: :b, guard: proc { false }
      end
    end
  end

  class WithClassGuard
    include AASM

    class Never
      def initialize(_record); end
      def call; false; end
    end

    aasm do
      state :a, initial: true
      state :b
      event :go do
        transitions from: :a, to: :b, guard: Never
      end
    end
  end

  class GuardedOnly
    include AASM

    aasm do
      state :s, initial: true
      state :t
      event :go do
        transitions from: :s, to: :t, guard: :allowed?
      end
    end
  end

  class ReachableUnknownGuard
    include AASM

    aasm do
      state :a, initial: true
      state :b
      state :c

      # reachable without any guard
      event :to_b do
        transitions from: :a, to: :b
      end

      # leaves :b, which is reachable, but behind an unknown guard
      event :to_c do
        transitions from: :b, to: :c, guard: :mystery
      end
    end
  end

  class UnknownGuardOnUnreachableEdge
    include AASM

    aasm do
      state :a, initial: true
      state :b
      state :c

      event :to_b do
        transitions from: :a, to: :b
      end

      # :c has no incoming transition, so this unknown guard is never reached
      event :to_c do
        transitions from: :c, to: :b, guard: :mystery
      end
    end
  end

  class FirstMatchWins
    include AASM

    aasm do
      state :s, initial: true
      state :x
      state :y

      event :go do
        transitions from: :s, to: :x, guard: :always
        transitions from: :s, to: :y
      end
    end

    def always; true; end
  end

  class UnlessGuard
    include AASM

    aasm do
      state :s, initial: true
      state :t
      event :go do
        transitions from: :s, to: :t, unless: :blocked
      end
    end

    def blocked; false; end
  end

  class UnlessBlocks
    include AASM

    aasm do
      state :s, initial: true
      state :t
      event :go do
        transitions from: :s, to: :t, unless: :blocked
      end
    end

    def blocked; true; end
  end

  class TwoMachines
    include AASM

    aasm :payment do
      state :unpaid, initial: true
      state :paid
      event :pay do
        transitions from: :unpaid, to: :paid
      end
    end

    aasm :logistics do
      state :pending, initial: true
      state :shipped
      event :ship do
        transitions from: :pending, to: :shipped
      end
    end
  end

  class DynamicInitial
    include AASM

    aasm do
      state :a, initial: true
      state :b
      event :go do
        transitions from: :a, to: :b
      end
    end

    def aasm_initial_state(_name = nil)
      :a
    end
  end

  class LongChain
    include AASM

    aasm do
      state :s0, initial: true
      1.upto(6) { |i| state "s#{i}".to_sym }
      1.upto(6) do |i|
        event("e#{i}".to_sym) { transitions from: "s#{i - 1}".to_sym, to: "s#{i}".to_sym }
      end
    end
  end

  class MultiTarget
    include AASM

    aasm do
      state :s, initial: true
      state :a
      state :b
      event :pick do
        transitions from: :s, to: [:a, :b]
      end
    end
  end

  class Wildcard
    include AASM

    aasm do
      state :s, initial: true
      state :t
      event :reset do
        transitions to: :s
      end
    end
  end

  def self.shipped_implies_paid(model)
    model.invariant('shipped implies paid') do |ctx|
      ctx.state != :shipped || ctx.var(:paid)
    end
  end
end

RSpec.describe 'read-only state analysis' do
  def analyze(klass, **options, &block)
    AASM::Analysis.analyze(klass, **options, &block)
  end

  def paid_abstraction(model)
    model.variable :paid, values: [true, false], initial: false
    model.condition(:paid?) { |ctx| ctx.var(:paid) }
    model.effect(:pay) { |_ctx| { paid: true } }
    AnalysisSpec.shipped_implies_paid(model)
  end

  it 'is read-only: it never instantiates the class or fires callbacks' do
    expect(AnalysisSpec::WithProcGuard).not_to receive(:new)
    result = analyze(AnalysisSpec::ShipBeforePaid) do |model|
      model.invariant('no shipped') { |ctx| ctx.state != :shipped }
    end
    expect(result).to be_violation
  end

  it 'reports safe when every reachable combination satisfies the invariant' do
    result = analyze(AnalysisSpec::ShippedOnlyAfterPaid, &method(:paid_abstraction))
    expect(result).to be_safe
    expect(result).not_to be_incomplete
    expect(result.combinations_explored).to eq 3
  end

  it 'returns the shortest violating event sequence' do
    result = analyze(AnalysisSpec::ShipBeforePaid, &method(:paid_abstraction))
    expect(result).to be_violation
    expect(result.events).to eq [:ship]
    expect(result.violated_invariant.name).to eq 'shipped implies paid'
  end

  it 'replays the witness in the abstract model and lands on the violation' do
    result = analyze(AnalysisSpec::ShipBeforePaid, &method(:paid_abstraction))
    replay = result.replay!
    expect(replay[:states]).to eq(default: :shipped)
    expect(replay[:invariant]).to eq 'shipped implies paid'
  end

  it 'replay uses the effects of preceding events for guarded models' do
    result = analyze(AnalysisSpec::ShippedOnlyAfterPaid, &method(:paid_abstraction))
    expect(result).to be_safe

    # pay then ship is reachable and legal: the effect flips :paid before ship
    effect = result.abstraction.effect_for(:default, :pay)
    pre = AASM::Analysis::Context.new({ default: :unpaid }, paid: false)
    expect(effect.call(pre)).to eq(paid: true)
  end

  it 'keeps a transition unreachable when its guard is abstracted to false' do
    result = analyze(AnalysisSpec::GuardedOnly) do |model|
      model.condition(:allowed?) { |_ctx| false }
      model.invariant('never t') { |ctx| ctx.state != :t }
    end
    expect(result).to be_safe
  end

  it 'returns incomplete, not safe, when a reachable Proc guard has no condition' do
    result = analyze(AnalysisSpec::WithProcGuard) do |model|
      model.invariant('never b') { |ctx| ctx.state != :b }
    end
    expect(result).to be_incomplete
    expect(result.blockers.map { |b| b[:reason] }).to include(:unabstracted_guard)
  end

  it 'returns incomplete when a class-based guard has no condition' do
    result = analyze(AnalysisSpec::WithClassGuard) do |model|
      model.invariant('never b') { |ctx| ctx.state != :b }
    end
    expect(result).to be_incomplete
  end

  it 'can abstract a class-based guard by its class object' do
    result = analyze(AnalysisSpec::WithClassGuard) do |model|
      model.condition(AnalysisSpec::WithClassGuard::Never) { |_ctx| true }
      model.invariant('never b') { |ctx| ctx.state != :b }
    end
    expect(result).to be_violation
    expect(result.events).to eq [:go]
    expect(result).to be_certain
  end

  it 'marks incomplete when a reachable edge depends on an unabstracted guard' do
    result = analyze(AnalysisSpec::ReachableUnknownGuard) do |model|
      model.invariant('never c') { |ctx| ctx.state != :c }
    end
    expect(result).to be_incomplete
    reasons = result.blockers.map { |b| b[:reason] }
    expect(reasons).to include(:unabstracted_guard)
  end

  it 'ignores unabstracted guards on unreachable edges and can still report safe' do
    result = analyze(AnalysisSpec::UnknownGuardOnUnreachableEdge) do |model|
      model.invariant('never c') { |ctx| ctx.state != :c }
    end
    expect(result).to be_safe
  end

  it 'honors first-match-wins transition ordering' do
    result = analyze(AnalysisSpec::FirstMatchWins) do |model|
      model.condition(:always) { |_ctx| true }
      model.invariant('never y') { |ctx| ctx.state != :y }
    end
    expect(result).to be_safe
  end

  it 'supports negated :unless guards that pass' do
    result = analyze(AnalysisSpec::UnlessGuard) do |model|
      model.condition(:blocked) { |_ctx| false }
      model.invariant('never t') { |ctx| ctx.state != :t }
    end
    expect(result).to be_violation
    expect(result.events).to eq [:go]
  end

  it 'treats a passing :unless guard as blocking the transition' do
    result = analyze(AnalysisSpec::UnlessBlocks) do |model|
      model.condition(:blocked) { |_ctx| true }
      model.invariant('never t') { |ctx| ctx.state != :t }
    end
    expect(result).to be_safe
  end

  it 'analyzes multiple named machines and their state combinations' do
    result = analyze(AnalysisSpec::TwoMachines) do |model|
      model.invariant('never shipped while unpaid') do |ctx|
        !(ctx.state(:logistics) == :shipped && ctx.state(:payment) == :unpaid)
      end
    end
    expect(result).to be_violation
    expect(result.events).to eq [:ship]
    expect(result.final_states).to eq(payment: :unpaid, logistics: :shipped)
    expect(result.replay![:states]).to eq(payment: :unpaid, logistics: :shipped)
  end

  it 'can restrict analysis to a subset of named machines' do
    result = analyze(AnalysisSpec::TwoMachines, machine_names: [:payment]) do |model|
      model.invariant('payment only') { |ctx| ctx.state(:payment) != :paid }
    end
    expect(result).to be_violation
    expect(result.events).to eq [:pay]
  end

  it 'returns incomplete on a dynamic (Proc) initial state' do
    machine = AASM::StateMachineStore.fetch(AnalysisSpec::DynamicInitial, true).machine(:default)
    allow(machine).to receive(:initial_state).and_return(proc { :a })

    result = analyze(AnalysisSpec::DynamicInitial) do |model|
      model.invariant('ok') { |ctx| ctx.state != :b }
    end
    expect(result).to be_incomplete
    expect(result.blockers.map { |b| b[:reason] }).to include(:unmodeled_callback)
  end

  it 'returns incomplete when the combination budget is exceeded' do
    result = analyze(AnalysisSpec::LongChain, budget: 3) do |model|
      model.invariant('linear') { |_ctx| true }
    end
    expect(result).to be_incomplete
    expect(result.blockers.map { |b| b[:reason] }).to include(:budget_exceeded)
  end

  it 'reports the shortest of several violating sequences' do
    result = analyze(AnalysisSpec::LongChain) do |model|
      model.invariant('not past s2') { |ctx| !%i[s3 s4 s5 s6].include?(ctx.state) }
    end
    expect(result.events).to eq [:e1, :e2, :e3]
    expect(result.replay![:states]).to eq(default: :s3)
  end

  it 'explores every target of an array :to transition' do
    result = analyze(AnalysisSpec::MultiTarget) do |model|
      model.invariant('never b') { |ctx| ctx.state != :b }
    end
    expect(result).to be_violation
    expect(result.events).to eq [:pick]
    expect(result.final_states).to eq(default: :b)
    expect(result.replay![:states]).to eq(default: :b)
  end

  it 'supports wildcard transitions without a :from state' do
    result = analyze(AnalysisSpec::Wildcard) do |model|
      model.invariant('never t') { |ctx| ctx.state != :t }
    end
    # :t is declared but never a transition target, so it is unreachable
    expect(result).to be_safe
  end

  it 'starts from every value of an abstract variable without an initial value' do
    klass = AnalysisSpec::GuardedOnly
    result = analyze(klass) do |model|
      model.variable :allowed, values: [true, false]
      model.condition(:allowed?) { |ctx| ctx.var(:allowed) }
      model.invariant('never t') { |ctx| ctx.state != :t }
    end
    expect(result).to be_violation
    expect(result.events).to eq [:go]
    expect(result.final_variables).to eq(allowed: true)
  end

  it 'exposes machine states through the context predicate helper' do
    result = analyze(AnalysisSpec::TwoMachines) do |model|
      model.invariant('predicate helper') do |ctx|
        !ctx.state?(:logistics, :shipped)
      end
    end
    expect(result).to be_violation
    expect(result.events).to eq [:ship]
  end

  it 'raises ReplayMismatch when a forged sequence cannot be reproduced' do
    result = analyze(AnalysisSpec::ShipBeforePaid, &method(:paid_abstraction))
    # Tamper with the recorded witness: claim it reaches :paid instead
    result.path.last[:to_state] = :paid
    result.path.last[:states] = { default: :paid }
    expect { result.replay! }.to raise_error(AASM::ReplayMismatch)
  end

  it 'refuses to report safety without any declared invariant' do
    result = analyze(AnalysisSpec::ShipBeforePaid)
    expect(result).to be_incomplete
  end

  it 'raises for a class without state machines or an unknown machine' do
    expect { analyze(Object) }.to raise_error(AASM::NoStateMachines)
    expect do
      analyze(AnalysisSpec::TwoMachines, machine_names: [:nope]) { |m| m.invariant('x') { true } }
    end.to raise_error(AASM::UnknownStateMachine)
  end
end
