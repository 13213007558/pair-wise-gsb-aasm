require 'spec_helper'

describe 'joint events' do
  let(:order) { JointEventOrder.new }

  it 'commits all state machines at once when every guard passes' do
    order.confirm_shipment

    expect(order.aasm(:payment).current_state).to eql :paid
    expect(order.aasm(:delivery).current_state).to eql :shipped
  end

  it 'knows whether it may fire' do
    expect(order.may_confirm_shipment?).to be(true)

    order.delivery_allowed = false
    expect(order.may_confirm_shipment?).to be(false)
    expect(order.aasm(:payment).current_state).to eql :unpaid
  end

  it 'runs joint callbacks around the committed participants' do
    order.confirm_shipment

    expect(order.log).to eql [:joint_before, :pay_success, :ship_success, :joint_after]
  end

  context 'when a later participant refuses' do
    before { order.delivery_allowed = false }

    it 'raises and changes no state machine' do
      expect { order.confirm_shipment }.to raise_error(AASM::InvalidTransition)

      expect(order.aasm(:payment).current_state).to eql :unpaid
      expect(order.aasm(:delivery).current_state).to eql :pending
    end

    it 'does not run any success or joint before/after callback of the first machine' do
      expect { order.confirm_shipment }.to raise_error(AASM::InvalidTransition)

      expect(order.log).to eql [[:joint_error, AASM::InvalidTransition]]
    end

    it 'returns false instead of raising when transitions are not whiny' do
      order.class.aasm(:delivery).state_machine.config.whiny_transitions = false

      expect(order.confirm_shipment).to be(false)
      expect(order.aasm(:payment).current_state).to eql :unpaid
      expect(order.aasm(:delivery).current_state).to eql :pending
    ensure
      order.class.aasm(:delivery).state_machine.config.whiny_transitions = true
    end
  end

  context 'when a joint after callback fails after the commit' do
    before { order.fail_after = true }

    it 'reports the failure but keeps the committed states' do
      expect { order.confirm_shipment }.to raise_error('external side effect failed')

      expect(order.aasm(:payment).current_state).to eql :paid
      expect(order.aasm(:delivery).current_state).to eql :shipped
      expect(order.log).to eql [:joint_before, :pay_success, :ship_success, :joint_after, [:joint_error, RuntimeError]]
    end
  end

  it 'evaluates all guards against the consistent pre-event state' do
    cross_guard_order = JointEventCrossGuardOrder.new

    # the delivery guard requires payment to still be :unpaid; it only
    # passes if the guard runs before the payment machine is committed
    cross_guard_order.confirm_shipment

    expect(cross_guard_order.aasm(:payment).current_state).to eql :paid
    expect(cross_guard_order.aasm(:delivery).current_state).to eql :shipped
  end
end
