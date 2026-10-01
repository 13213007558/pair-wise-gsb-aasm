class JointEventOrder
  include AASM

  attr_reader :log

  def initialize
    @log = []
  end

  aasm(:payment) do
    state :unpaid, :initial => true
    state :paid

    event :pay, :before => :log_pay_before,
                :success => :log_pay_success,
                :after => :log_pay_after do
      transitions :from => :unpaid, :to => :paid, :guard => :payment_open?
    end
  end

  aasm(:delivery) do
    state :pending, :initial => true
    state :shipped

    event :ship, :before => :log_ship_before,
                 :success => :log_ship_success,
                 :after => :log_ship_after do
      transitions :from => :pending, :to => :shipped, :guard => :delivery_open?
    end
  end

  aasm_joint_event :confirm_shipment,
                   {:payment => :pay, :delivery => :ship},
                   :ensure => lambda { log << :joint_ensure } do
    before { log << :joint_before }
    success { log << :joint_success }
    after { log << :joint_after }
  end

  def payment_open?
    true
  end

  def delivery_open?
    true
  end

  def log_pay_before
    log << :pay_before
  end

  def log_pay_success
    log << [:pay_success, aasm(:payment).current_state, aasm(:delivery).current_state]
  end

  def log_pay_after
    log << :pay_after
  end

  def log_ship_before
    log << :ship_before
  end

  def log_ship_success
    log << [:ship_success, aasm(:payment).current_state, aasm(:delivery).current_state]
  end

  def log_ship_after
    log << :ship_after
  end
end

# both guards read the other machine's state - they only pass when all
# guards are evaluated against the consistent pre-event state
class JointEventCrossGuardOrder
  include AASM

  aasm(:payment) do
    state :unpaid, :initial => true
    state :paid

    event :pay do
      transitions :from => :unpaid, :to => :paid, :guard => :delivery_pending?
    end
  end

  aasm(:delivery) do
    state :pending, :initial => true
    state :shipped

    event :ship do
      transitions :from => :pending, :to => :shipped, :guard => :payment_unpaid?
    end
  end

  aasm_joint_event :confirm_shipment, :payment => :pay, :delivery => :ship

  def delivery_pending?
    aasm(:delivery).current_state == :pending
  end

  def payment_unpaid?
    aasm(:payment).current_state == :unpaid
  end
end

class JointEventNonWhinyOrder
  include AASM

  aasm(:payment, :whiny_transitions => false) do
    state :unpaid, :initial => true
    state :paid

    event :pay do
      transitions :from => :unpaid, :to => :paid
    end
  end

  aasm(:delivery, :whiny_transitions => false) do
    state :pending, :initial => true
    state :shipped

    event :ship do
      transitions :from => :pending, :to => :shipped, :guard => :delivery_open?
    end
  end

  aasm_joint_event :confirm_shipment, :payment => :pay, :delivery => :ship

  def delivery_open?
    true
  end
end

class JointEventOrderWithErrorHandler
  include AASM

  attr_reader :log

  def initialize
    @log = []
  end

  aasm(:payment) do
    state :unpaid, :initial => true
    state :paid

    event :pay, :success => :log_pay_success do
      transitions :from => :unpaid, :to => :paid
    end
  end

  aasm(:delivery) do
    state :pending, :initial => true
    state :shipped

    event :ship do
      transitions :from => :pending, :to => :shipped
    end
  end

  aasm_joint_event :confirm_shipment, :payment => :pay, :delivery => :ship do
    error { |error| log << [:joint_error, error.message] }
  end

  def log_pay_success
    log << :pay_success
  end
end
