require 'spec_helper'

describe 'dynamic transition targets' do
  subject(:record) { DynamicTransition.new }

  it 'resolves an allowed target after the guard passes' do
    expect(record.review!(escalate: true)).to be(true)
    expect(record).to be_manual_review
    expect(record.resolution_count).to eq(1)
    expect(record.reviewer).to be_nil
    expect(record.escalated).to be(true)
  end

  it 'passes positional and keyword arguments to the resolver' do
    record.review!('alice', escalate: true)

    expect(record.aasm.current_state).to eq(:manual_review)
    expect(record.reviewer).to eq('alice')
    expect(record.escalated).to be(true)
  end

  it 'passes positional and keyword arguments to a proc resolver' do
    record.review_with_lambda!('alice', escalate: true)

    expect(record.aasm.current_state).to eq(:manual_review)
    expect(record.reviewer).to eq('alice')
    expect(record.escalated).to be(true)
  end

  it 'does not resolve when a guard fails' do
    expect(record.may_attempt_blocked_review?).to be(false)
    expect(record.resolution_count).to eq(0)
    expect(record).to be_pending
  end

  it 'does not reuse the target calculated by a may query' do
    expect(record.may_review?(escalate: true)).to be(true)
    expect(record.resolution_count).to eq(1)

    record.review!(escalate: true)

    expect(record).to be_manual_review
    expect(record.resolution_count).to eq(2)
  end

  it 'fails before leaving the original state for an unknown target' do
    expect { record.review_to_unknown_target! }.to raise_error(ArgumentError, /not one of/)
    expect(record).to be_pending
  end

  it 'fails before leaving the original state when resolver evaluation raises' do
    allow(record).to receive(:resolve_review).and_raise(RuntimeError, 'resolver failed')

    expect { record.review! }.to raise_error(RuntimeError, 'resolver failed')
    expect(record).to be_pending
  end

  it 'honors an explicitly requested dynamic target' do
    expect(record.may_review?(:manual_review, escalate: true)).to be(true)
    expect(record.may_review?(:approved, escalate: true)).to be(false)
  end

  it 'works for inherited state machines' do
    child = Class.new(DynamicTransition).new

    expect(child.may_review?).to be(true)
    child.review!

    expect(child).to be_approved
    expect(child.resolution_count).to eq(2)
    expect(DynamicTransition.new.resolution_count).to eq(0)
  end

  it 'works with named state machines' do
    named = NamedDynamicTransition.new

    named.aasm(:workflow).fire!(:review, 'alice', escalate: true)

    expect(named.aasm(:workflow).current_state).to eq(:manual_review)
    expect(named.resolution_count).to eq(1)
    expect(named.reviewer).to eq('alice')
    expect(named.escalated).to be(true)
  end
end
