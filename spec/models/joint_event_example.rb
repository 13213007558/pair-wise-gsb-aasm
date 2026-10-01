class JointEventOrder
  include AASM

  attr_reader :log
  attr_accessor :delivery_allowed, :fail_after

  def initialize
    @log = []
    @delivery_allowed = true
  end

  aasm :payment do
    state :unpaid, :initial => true
    state :paid

    event :pay do
      transitions :from => :unpaid, :to => :paid,
                  :success => -> { log << :pay_success }
    end
  end

  aasm :delivery do
    state :pending, :initial => true
    state :shipped

    event :ship do
      transitions :from => :pending, :to => :shipped,
                  :guard => :delivery_allowed?,
                  :success => -> { log << :ship_success }
    end
  end

  aasm_joint_event :confirm_shipment, { :payment => :pay, :delivery => :ship } do
    before { log << :joint_before }
    after  { log << :joint_after; raise 'external side effect failed' if fail_after }
    error  { |e| log << [:joint_error, e.class] }
  end

  def delivery_allowed?
    !!@delivery_allowed
  end
end

# the delivery guard of this order depends on the payment state, to prove
# that all guards of a joint event see the consistent pre-event state
class JointEventCrossGuardOrder
  include AASM

  aasm :payment do
    state :unpaid, :initial => true
    state :paid

    event :pay do
      transitions :from => :unpaid, :to => :paid
    end
  end

  aasm :delivery do
    state :pending, :initial => true
    state :shipped

    event :ship do
      transitions :from => :pending, :to => :shipped,
                  :guard => -> { aasm(:payment).current_state == :unpaid }
    end
  end

  aasm_joint_event :confirm_shipment, { :payment => :pay, :delivery => :ship }
end
