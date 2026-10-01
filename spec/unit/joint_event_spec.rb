require 'spec_helper'

describe 'joint events' do
  let(:order) { JointEventOrder.new }

  def logged_names(order)
    order.log.map { |entry| Array(entry).first }
  end

  describe 'firing' do
    it 'commits all involved state machines at once' do
      expect(order.confirm_shipment).to be true
      expect(order.aasm(:payment).current_state).to eq(:paid)
      expect(order.aasm(:delivery).current_state).to eq(:shipped)
    end

    it 'supports the bang version' do
      expect(order.confirm_shipment!).to be true
      expect(order.aasm(:payment).current_state).to eq(:paid)
      expect(order.aasm(:delivery).current_state).to eq(:shipped)
    end

    it 'runs the callbacks in a defined order' do
      order.confirm_shipment

      expect(order.log).to eq([
        :joint_before,
        :pay_before,
        :ship_before,
        [:pay_success, :paid, :shipped],
        [:ship_success, :paid, :shipped],
        :pay_after,
        :ship_after,
        :joint_success,
        :joint_after,
        :joint_ensure,
      ])
    end

    it 'lets success callbacks observe the committed joint state' do
      order.confirm_shipment

      expect(order.log).to include([:pay_success, :paid, :shipped])
      expect(order.log).to include([:ship_success, :paid, :shipped])
    end
  end

  describe 'may_fire' do
    it 'is true when all targets may fire' do
      expect(order.may_confirm_shipment?).to be true
    end

    it 'is false when any target may not fire' do
      allow(order).to receive(:delivery_open?).and_return(false)
      expect(order.may_confirm_shipment?).to be false
    end
  end

  describe 'when the second machine rejects' do
    before do
      allow(order).to receive(:delivery_open?).and_return(false)
    end

    it 'raises an InvalidTransition error' do
      expect { order.confirm_shipment }.to raise_error(AASM::InvalidTransition)
    end

    it 'does not change the first machine' do
      expect { order.confirm_shipment }.to raise_error(AASM::InvalidTransition)

      expect(order.aasm(:payment).current_state).to eq(:unpaid)
      expect(order.aasm(:delivery).current_state).to eq(:pending)
    end

    it 'does not fire success or after callbacks of the first machine' do
      expect { order.confirm_shipment }.to raise_error(AASM::InvalidTransition)

      expect(logged_names(order)).to include(:pay_before)
      expect(logged_names(order)).not_to include(:pay_success)
      expect(logged_names(order)).not_to include(:pay_after)
      expect(logged_names(order)).not_to include(:joint_success)
      expect(logged_names(order)).not_to include(:joint_after)
    end

    it 'returns false when transitions are not whiny' do
      non_whiny = JointEventNonWhinyOrder.new
      allow(non_whiny).to receive(:delivery_open?).and_return(false)

      expect(non_whiny.confirm_shipment).to be false
      expect(non_whiny.aasm(:payment).current_state).to eq(:unpaid)
      expect(non_whiny.aasm(:delivery).current_state).to eq(:pending)
    end
  end

  describe 'guard evaluation' do
    it 'uses the consistent pre-event state for all guards' do
      cross_guarded = JointEventCrossGuardOrder.new

      expect(cross_guarded.confirm_shipment).to be true
      expect(cross_guarded.aasm(:payment).current_state).to eq(:paid)
      expect(cross_guarded.aasm(:delivery).current_state).to eq(:shipped)
    end
  end

  describe 'error handling' do
    it 'changes nothing when a before callback fails' do
      allow(order).to receive(:log_pay_before).and_raise(StandardError.new('boom'))

      expect { order.confirm_shipment }.to raise_error('boom')
      expect(order.aasm(:payment).current_state).to eq(:unpaid)
      expect(order.aasm(:delivery).current_state).to eq(:pending)
    end

    it 'reports the committed state when a post-commit callback fails' do
      allow(order).to receive(:log_pay_success).and_raise(StandardError.new('boom'))

      expect { order.confirm_shipment }.to raise_error('boom')
      # committed states are not rolled back
      expect(order.aasm(:payment).current_state).to eq(:paid)
      expect(order.aasm(:delivery).current_state).to eq(:shipped)
    end

    it 'passes post-commit failures to the error callbacks without rolling back' do
      handled = JointEventOrderWithErrorHandler.new
      allow(handled).to receive(:log_pay_success).and_raise(StandardError.new('boom'))

      expect(handled.confirm_shipment).to be false
      expect(handled.log).to include([:joint_error, 'boom'])
      expect(handled.aasm(:payment).current_state).to eq(:paid)
      expect(handled.aasm(:delivery).current_state).to eq(:shipped)
    end
  end

  describe 'unknown targets' do
    it 'raises for an unknown state machine' do
      klass = Class.new do
        include AASM
        aasm(:payment) do
          state :unpaid, :initial => true
          state :paid
          event(:pay) { transitions :from => :unpaid, :to => :paid }
        end
        aasm_joint_event :confirm, :payment => :pay, :delivery => :ship
      end

      expect { klass.new.confirm }.to raise_error(AASM::UnknownStateMachineError)
    end

    it 'raises for an unknown event' do
      klass = Class.new do
        include AASM
        aasm(:payment) do
          state :unpaid, :initial => true
          state :paid
          event(:pay) { transitions :from => :unpaid, :to => :paid }
        end
        aasm_joint_event :confirm, [[:payment, :pay], [:payment, :nope]]
      end

      expect { klass.new.confirm }.to raise_error(AASM::UndefinedEvent)
    end
  end
end
