require 'spec_helper'

describe 'dynamic transition resolver' do
  let(:model_class) do
    Class.new do
      include AASM

      attr_accessor :resolver_calls, :exited, :after_targets, :guard_arguments, :resolver_arguments,
                    :guard_context, :resolver_context

      def initialize
        @resolver_calls = 0
        @exited = false
        @after_targets = []
        @guard_arguments = nil
        @resolver_arguments = nil
        @guard_context = nil
        @resolver_context = nil
      end

      def guard_allows?(context, role:, urgent:, **)
        @guard_context = context
        @guard_arguments = { role: role, urgent: urgent }
        role == :manager && urgent
      end

      def resolve_review_target(context, decision:, reason:, **)
        @resolver_calls += 1
        @resolver_context = context
        @resolver_arguments = { decision: decision, reason: reason }
        decision == :approve ? :approved : :manual_review
      end

      def unknown_target
        :archived
      end

      def exploding_target
        raise 'resolver failed'
      end

      def record_transition
        after_targets << aasm.to_state
      end

      def record_exit
        @exited = true
      end

      aasm do
        state :pending, initial: true, exit: :record_exit
        state :approved
        state :manual_review

        event :review do
          before { nil }
          transitions from: :pending,
                      to: [:approved, :manual_review],
                      resolver: :resolve_review_target,
                      guard: :guard_allows?,
                      after: :record_transition
        end

        event :unknown_review do
          transitions from: :pending,
                      to: [:approved, :manual_review],
                      resolver: :unknown_target
        end

        event :failing_review do
          transitions from: :pending,
                      to: [:approved, :manual_review],
                      resolver: :exploding_target
        end
      end

      aasm(:workflow, namespace: :workflow) do
        state :pending, initial: true
        state :approved
        state :manual_review

        event :review do
          transitions from: :pending,
                      to: [:approved, :manual_review],
                      resolver: :resolve_review_target
        end
      end
    end
  end

  it 'selects the resolver target once for a real transition and passes full keyword arguments' do
    model = model_class.new

    expect(model.review('context', decision: :approve, reason: 'clear', role: :manager, urgent: true)).to be(true)

    expect(model).to be_approved
    expect(model.resolver_calls).to eq(1)
    expect(model.resolver_context).to eq('context')
    expect(model.resolver_arguments).to eq(decision: :approve, reason: 'clear')
    expect(model.guard_context).to eq('context')
    expect(model.guard_arguments).to eq(role: :manager, urgent: true)
    expect(model.after_targets).to eq([:approved])
  end

  it 'uses an explicitly allowed target without calling the resolver' do
    model = model_class.new

    model.review(:manual_review, 'context', decision: :approve, reason: 'ignored', role: :manager, urgent: true)

    expect(model).to be_manual_review
    expect(model.resolver_calls).to eq(0)
    expect(model.after_targets).to eq([:manual_review])
  end

  it 'does not reuse a may_event? calculation for a later transition' do
    model = model_class.new

    expect(model.may_review?('context', decision: :approve, reason: 'looks good', role: :manager, urgent: true)).to be(true)
    expect(model.resolver_calls).to eq(1)

    model.review('context', decision: :manual, reason: 'needs eyes', role: :manager, urgent: true)

    expect(model).to be_manual_review
    expect(model.resolver_calls).to eq(2)
  end

  it 'does not call the resolver when a guard rejects the transition' do
    model = model_class.new

    expect(model.may_review?('context', decision: :approve, role: :viewer, urgent: true)).to be(false)
    expect(model.resolver_calls).to eq(0)
  end

  it 'fails before exiting the original state when the resolver returns an undeclared target' do
    model = model_class.new

    expect { model.unknown_review }.to raise_error(AASM::InvalidTransitionTarget)
    expect(model).to be_pending
    expect(model.exited).to be(false)
  end

  it 'fails before exiting the original state when the resolver raises' do
    model = model_class.new

    expect { model.failing_review }.to raise_error(RuntimeError, 'resolver failed')
    expect(model).to be_pending
  end

  it 'works on named state machines' do
    model = model_class.new

    model.review_workflow('context', decision: :manual, reason: 'needs eyes', role: :manager, urgent: true)

    expect(model.aasm(:workflow).current_state).to eq(:manual_review)
  end

  it 'keeps inherited dynamic transitions on subclasses' do
    subclass = Class.new(model_class)
    model = subclass.new

    model.review('context', decision: :manual, reason: 'needs eyes', role: :manager, urgent: true)

    expect(model).to be_manual_review
    expect(model_class.new).to be_pending
  end

  it 'supports a Proc resolver' do
    proc_model_class = Class.new do
      include AASM

      aasm do
        state :pending, initial: true
        state :approved
        state :manual_review

        event :review do
          transitions from: :pending,
                      to: [:approved, :manual_review],
                      resolver: proc { |decision:| decision == :approve ? :approved : :manual_review }
        end
      end
    end

    model = proc_model_class.new
    model.review(decision: :manual)

    expect(model).to be_manual_review
  end

  it 'preserves static target behavior without a resolver' do
    static_model_class = Class.new do
      include AASM

      aasm do
        state :pending, initial: true
        state :approved
        state :manual_review

        event :review do
          transitions from: :pending, to: [:approved, :manual_review]
        end
      end
    end

    model = static_model_class.new
    model.review

    expect(model).to be_approved
  end
end
