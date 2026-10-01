require 'spec_helper'
require 'aasm/persistence/orm'

class EventReceiptJob
  include AASM

  attr_reader :before_count, :transition_count, :success_count, :started, :continue
  attr_accessor :close_barrier

  def initialize
    @before_count = 0
    @transition_count = 0
    @success_count = 0
    @block_close = false
    @close_barrier = nil
    @started = Queue.new
    @continue = Queue.new
  end

  aasm do
    state :open, initial: true
    state :closed
    state :archived

    event :close do
      before :before_close
      after :after_close_transition
      success :after_close_success
      transitions from: :open, to: :closed
    end

    event :archive do
      transitions from: :open, to: :archived
    end
  end

  def release
    continue << true
  end

  def block_close!
    @block_close = true
  end

  private

  def before_close(*_args)
    @before_count += 1
    if @block_close
      started << true
      close_barrier ? close_barrier.pop : continue.pop
    end
  end

  def after_close_transition(*_args)
    @transition_count += 1
  end

  def after_close_success(*_args)
    @success_count += 1
  end
end

class BlockingMemoryStore < AASM::EventReceipt::MemoryStore
  attr_reader :waiter_arrived, :release_waiter

  def initialize
    super
    @waiter_arrived = Queue.new
    @release_waiter = Queue.new
  end

  def wait(receipt, timeout = nil)
    waiter_arrived << true
    release_waiter.pop
    super(receipt, timeout)
  end
end

class GuardedEventReceiptJob
  include AASM

  attr_reader :before_count

  def initialize
    @before_count = 0
  end

  aasm do
    state :open, initial: true
    state :closed

    event :close do
      before { @before_count += 1 }
      transitions from: :open, to: :closed, guard: :allow_close?
    end
  end

  def allow_close?
    false
  end
end

class TransactionalEventReceiptJob
  include AASM
  include AASM::Persistence::ORM

  attr_reader :after_commit_count

  def initialize
    @after_commit_count = 0
  end

  aasm do
    state :open, initial: true
    state :closed

    event :close, after_commit: :after_close_commit do
      transitions from: :open, to: :closed
    end
  end

  def aasm_supports_transactions?
    true
  end

  def aasm_read_state(_name = :default)
    @current_state ||= :open
  end

  def aasm_transaction(_requires_new, _requires_lock)
    yield
  end

  def aasm_execute_after_commit
    yield
  end

  def aasm_write_state(state, name = :default)
    @current_state = state
    true
  end

  def aasm_write_attribute(name, value)
    instance_variable_set("@#{name}", value)
  end

  private

  def after_close_commit
    @after_commit_count += 1
    raise StandardError, 'after commit failed'
  end
end

describe AASM::EventReceipt::MemoryStore do
  it 'implements the receipt store extension protocol' do
    expect(described_class.new).to be_a(AASM::EventReceipt::Store)
  end

  it 'binds an event id to the event name and argument digest' do
    job = EventReceiptJob.new
    store = described_class.new

    first = job.aasm.fire_with_receipt!(:close, 'same-id', 'first', store: store)
    different_arguments = job.aasm.fire_with_receipt!(:close, 'same-id', 'second', store: store)
    different_event = job.aasm.fire_with_receipt!(:archive, 'same-id', 'first', store: store)

    expect(first).to be_committed
    expect(different_arguments).to be_not_accepted
    expect(different_arguments).to be_conflict
    expect(different_arguments.error).to be_a(AASM::EventReceipt::Conflict)
    expect(different_arguments.existing_receipt).to eq(first)
    expect(different_event).to be_not_accepted
    expect(different_event).to be_conflict
    expect(job.aasm.current_state).to eq(:closed)
  end

  it 'distinguishes keyword arguments and persistence mode' do
    job = EventReceiptJob.new
    store = described_class.new

    without_persistence = job.aasm.fire_with_receipt(:close, 'same-id', reason: 'done', persist: false, store: store)
    with_persistence = job.aasm.fire_with_receipt!(:close, 'same-id', reason: 'done', store: store)

    expect(without_persistence).to be_committed
    expect(with_persistence).to be_not_accepted
    expect(with_persistence).to be_conflict

    job = EventReceiptJob.new
    first = job.aasm.fire_with_receipt!(:close, 'keyword-id', reason: 'done', store: store)
    different_keyword = job.aasm.fire_with_receipt!(:close, 'keyword-id', reason: 'other', store: store)

    expect(first).to be_committed
    expect(different_keyword).to be_not_accepted
    expect(different_keyword).to be_conflict
  end
end

describe 'event receipt firing' do
  let(:store) { AASM::EventReceipt::MemoryStore.new }

  it 'runs two identical concurrent calls as one transition and returns the same committed receipt' do
    job = EventReceiptJob.new
    job.block_close!
    receipt_store = BlockingMemoryStore.new
    receipt_id = 'receipt-1'
    release_owner = Queue.new
    job.close_barrier = release_owner

    owner = Thread.new do
      job.aasm.fire_with_receipt!(:close, receipt_id, reason: 'done', store: receipt_store)
    end
    duplicate = Thread.new do
      job.aasm.fire_with_receipt!(:close, receipt_id, reason: 'done', store: receipt_store)
    end

    expect(job.started.pop).to eq(true)
    expect(receipt_store.waiter_arrived.pop).to eq(true)
    release_owner << true
    first_receipt = owner.value
    expect(first_receipt).to be_committed
    expect(job.aasm.find_event_receipt(receipt_id, store: receipt_store)).to equal(first_receipt)
    receipt_store.release_waiter << true
    duplicate_receipt = duplicate.value
    receipts = [first_receipt, duplicate_receipt]

    expect(receipts.map(&:status)).to eq([:committed, :committed])
    expect(receipts.first).to equal(receipts.last)
    expect(receipts.map(&:result)).to eq([true, true])
    expect(job.aasm.current_state).to eq(:closed)
    expect(job.before_count).to eq(1)
    expect(job.transition_count).to eq(1)
    expect(job.success_count).to eq(1)
  end

  it 'returns the first committed receipt without running callbacks again' do
    job = EventReceiptJob.new

    first = job.aasm.fire_with_receipt!(:close, 'receipt-2', reason: 'done', store: store)
    duplicate = job.aasm.fire_with_receipt!(:close, 'receipt-2', reason: 'done', store: store)

    expect(first).to be_committed
    expect(duplicate).to be_committed
    expect(duplicate).to equal(first)
    expect(duplicate.result).to eq(true)
    expect(job.before_count).to eq(1)
    expect(job.transition_count).to eq(1)
    expect(job.success_count).to eq(1)
  end

  it 'reports a non-blocking duplicate as executing' do
    job = EventReceiptJob.new
    receipt_id = 'receipt-3'
    job.block_close!

    owner = Thread.new do
      job.aasm.fire_with_receipt!(:close, receipt_id, reason: 'done', store: store)
    end

    expect(job.started.pop).to eq(true)
    duplicate = job.aasm.fire_with_receipt!(:close, receipt_id, reason: 'done', store: store, wait: false)

    expect(duplicate).to be_executing
    job.release
    expect(owner.value).to be_committed
    expect(duplicate.wait).to be_committed
  end

  it 'reports rejected transitions as not accepted and does not retry them' do
    job = GuardedEventReceiptJob.new

    first = job.aasm.fire_with_receipt!(:close, 'rejected-id', store: store)
    duplicate = job.aasm.fire_with_receipt!(:close, 'rejected-id', store: store)

    expect(first).to be_not_accepted
    expect(first.result).to eq(false)
    expect(first.error).to be_a(AASM::InvalidTransition)
    expect(duplicate).to equal(first)
    expect(job.before_count).to eq(1)
    expect(job.aasm.current_state).to eq(:open)
  end

  it 'reports after commit callback failure without rerunning it' do
    job = TransactionalEventReceiptJob.new

    first = job.aasm.fire_with_receipt!(:close, 'callback-id', store: store)
    duplicate = job.aasm.fire_with_receipt!(:close, 'callback-id', store: store)

    expect(first).to be_post_commit_callback_failed
    expect(first.result).to eq(true)
    expect(first.error.message).to eq('after commit failed')
    expect(duplicate).to equal(first)
    expect(job.aasm.current_state).to eq(:closed)
    expect(job.after_commit_count).to eq(1)
  end

end
