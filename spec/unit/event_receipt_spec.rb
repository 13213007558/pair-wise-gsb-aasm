require 'spec_helper'
require 'thread'
require 'aasm/persistence/orm'

class EventReceiptExample
  include AASM

  attr_reader :transition_count, :success_count, :callback_values

  def initialize
    @transition_count = 0
    @success_count = 0
    @callback_values = []
  end

  aasm whiny_transitions: false do
    state :open, initial: true
    state :closed
    state :rejected

    event :close do
      success :record_success
      transitions from: :open, to: :closed
    end

    event :close_with_keyword_argument do
      success :record_keyword_success
      transitions from: :open, to: :closed
    end

    event :close_with_callback_failure do
      success :record_success_with_failure
      transitions from: :open, to: :closed
    end

    event :reject do
      transitions from: :open, to: :rejected
    end
  end

  private

  def record_success(value = nil)
    @transition_count += 1
    @success_count += 1
    @callback_values << value
  end

  def record_keyword_success(value:)
    @transition_count += 1
    @success_count += 1
    @callback_values << value
  end

  def record_success_with_failure(value = nil)
    record_success(value)
    raise 'post commit failed'
  end
end

class EventReceiptOrmExample
  module OrmStub
    def aasm_transaction(_requires_new, _requires_lock)
      yield
    end

    def aasm_write_state(_state, _name)
      true
    end

    def aasm_write_state_without_persistence(state, _name)
      @instance_current_state = state
    end

    def aasm_read_state(_name)
      @instance_current_state || :open
    end

    def aasm_read_attribute(_name)
      @instance_current_state
    end

    def aasm_write_attribute(_name, value)
      @instance_current_state = value
    end

    def aasm_save
      true
    end

    def aasm_rollback(_name, _old_value)
      false
    end
  end

  include AASM

  attr_reader :post_commit_callback_count

  def initialize
    @post_commit_callback_count = 0
  end

  aasm do
    state :open, initial: true
    state :closed

    event :close, after_commit: :after_commit_close do
      transitions from: :open, to: :closed
    end
  end

  prepend AASM::Persistence::ORM
  prepend OrmStub

  private

      def after_commit_close
    @post_commit_callback_count += 1
    raise 'after commit failed'
  end
end

class EventReceiptCountingStore < AASM::EventReceiptStore::Abstract
  attr_reader :memory, :claims, :marks

  def initialize
    @memory = AASM::EventReceiptStore::Memory.new
    @claims = 0
    @marks = 0
  end

  def claim(request)
    @claims += 1
    memory.claim(request)
  end

  def mark(receipt, status, attributes = {})
    @marks += 1
    memory.mark(receipt, status, attributes)
  end

  def find(**attributes)
    memory.find(**attributes)
  end
end

describe AASM::EventReceipt do
  let(:store) { AASM::EventReceiptStore::Memory.new }
  let(:object) { EventReceiptExample.new }
  let(:custom_store) { EventReceiptCountingStore.new }

  describe '.argument_fingerprint' do
    it 'does not depend on keyword argument order' do
      first = described_class.argument_fingerprint(:close, [], { b: 2, a: 1 })
      second = described_class.argument_fingerprint(:close, [], { a: 1, b: 2 })

      expect(first).to eq(second)
    end

    it 'binds the event name and positional or keyword arguments' do
      expect(described_class.argument_fingerprint(:close, [1], {})).not_to eq(
        described_class.argument_fingerprint(:open, [1], {})
      )
      expect(described_class.argument_fingerprint(:close, [1], {})).not_to eq(
        described_class.argument_fingerprint(:close, [2], {})
      )
      expect(described_class.argument_fingerprint(:close, [], value: 1)).not_to eq(
        described_class.argument_fingerprint(:close, [], value: 2)
      )
    end
  end

  describe 'duplicate event delivery' do
    it 'preserves business keyword arguments' do
      receipt = object.aasm.fire_with_receipt!(
        :close_with_keyword_argument,
        event_id: 'evt-kw',
        store: store,
        value: 'message-1'
      )

      expect(receipt).to be_committed
      expect(object.callback_values).to eq(['message-1'])
    end

    it 'returns the first committed receipt without repeating migration or success callbacks' do
      first = object.aasm.fire_with_receipt!(:close, 'message-1', event_id: 'evt-1', store: store)
      expect(first.attempts).to eq(1)
      second = object.aasm.fire_with_receipt!(:close, 'message-1', event_id: 'evt-1', store: store)

      expect(first).to have_attributes(
        status: :committed,
        result: true,
        event_name: :close,
        from_state: :open,
        to_state: :closed,
      )
      expect(second).to eq(first)
      expect(second.attempts).to eq(2)
      expect(object.transition_count).to eq(1)
      expect(object.success_count).to eq(1)
      expect(object.callback_values).to eq(['message-1'])
      expect(object).to be_closed
    end

    it 'executes the transition once when identical calls race' do
      entered = Queue.new
      release = Queue.new

      allow(object).to receive(:record_success) do
        entered << true
        release.pop
      end

      first = Thread.new do
        object.aasm.fire_with_receipt!(:close, 'message-1', event_id: 'evt-1', store: store)
      end

      entered.pop
      sleep 0.05
      in_progress = store.find(
        object_key: object.object_id,
        state_machine_name: :default,
        event_id: 'evt-1'
      )
      expect(in_progress).to be_in_progress

      second = Thread.new do
        object.aasm.fire_with_receipt!(:close, 'message-1', event_id: 'evt-1', store: store)
      end

      release << true

      first_receipt = first.value
      second_receipt = second.value

      expect(first_receipt).to eq(second_receipt)
      expect(first_receipt).to be_committed
      expect(second_receipt.attempts).to eq(2)
      expect(object).to be_closed
      expect(object).to have_received(:record_success).once
    end

    it 'reports conflicting arguments for the same event id' do
      object.aasm.fire_with_receipt!(:close, 'message-1', event_id: 'evt-1', store: store)

      expect do
        object.aasm.fire_with_receipt!(:close, 'message-2', event_id: 'evt-1', store: store)
      end.to raise_error(
        AASM::EventReceiptConflict,
        /different arguments/
      )
    end

    it 'reports conflicting keyword arguments for an in-progress event' do
      entered = Queue.new
      release = Queue.new

      allow(object).to receive(:record_success) do
        entered << true
        release.pop
      end

      first = Thread.new do
        object.aasm.fire_with_receipt!(:close, event_id: 'evt-1', value: 'one', store: store)
      end

      entered.pop
      expect do
        object.aasm.fire_with_receipt!(:close, event_id: 'evt-1', value: 'two', store: store)
      end.to raise_error(AASM::EventReceiptConflict)

      release << true
      expect(first.value).to be_committed
    end
  end

  describe 'receipt status' do
    it 'accepts a custom store through the extension protocol' do
      receipt = object.aasm.fire_with_receipt!(
        :close,
        event_id: 'evt-custom',
        store: custom_store
      )

      duplicate = object.aasm.fire_with_receipt!(
        :close,
        event_id: 'evt-custom',
        store: custom_store
      )

      expect(receipt).to be_committed
      expect(duplicate).to eq(receipt)
      expect(custom_store.claims).to eq(2)
      expect(custom_store.marks).to eq(1)
    end

    it 'marks an invalid transition as not accepted' do
      object.aasm.fire_with_receipt!(:close, event_id: 'evt-1', store: store)
      receipt = object.aasm.fire_with_receipt!(:reject, event_id: 'evt-2', store: store)

      expect(receipt).to be_not_accepted
      expect(receipt.result).to eq(false)
      expect(object).to be_closed
    end

    it 'returns the first not-accepted result for duplicate delivery' do
      object.close!

      first = object.aasm.fire_with_receipt!(:close, event_id: 'evt-1', store: store)
      second = object.aasm.fire_with_receipt!(:close, event_id: 'evt-1', store: store)

      expect(first).to eq(second)
      expect(second).to be_not_accepted
      expect(object).to be_closed
      expect(object.success_count).to eq(1)
    end

    it 'marks a failure after commit as post commit callback failure' do
      receipt = object.aasm.fire_with_receipt!(
        :close_with_callback_failure,
        'message-1',
        event_id: 'evt-1',
        store: store
      )

      expect(receipt).to be_post_commit_callback_failed
      expect(receipt.result).to eq(true)
      expect(receipt.error.message).to eq('post commit failed')
      expect(object).to be_closed
      expect(object.success_count).to eq(1)

      duplicate = object.aasm.fire_with_receipt!(
        :close_with_callback_failure,
        'message-1',
        event_id: 'evt-1',
        store: store
      )

      expect(duplicate).to eq(receipt)
      expect(duplicate.attempts).to eq(2)
      expect(object.success_count).to eq(1)
    end

    it 'marks an after_commit callback failure without replaying it' do
      orm_object = EventReceiptOrmExample.new

      receipt = orm_object.aasm.fire_with_receipt!(
        :close,
        event_id: 'evt-commit',
        store: store
      )
      duplicate = orm_object.aasm.fire_with_receipt!(
        :close,
        event_id: 'evt-commit',
        store: store
      )

      expect(receipt).to be_post_commit_callback_failed
      expect(receipt.result).to eq(true)
      expect(receipt.error.message).to eq('after commit failed')
      expect(duplicate).to eq(receipt)
      expect(orm_object).to be_closed
      expect(orm_object.post_commit_callback_count).to eq(1)
    end

    it 'scopes receipts by object and state machine' do
      another = EventReceiptExample.new
      first = object.aasm.fire_with_receipt!(:close, event_id: 'evt-1', store: store)
      second = another.aasm.fire_with_receipt!(:close, event_id: 'evt-1', store: store)

      expect(first).not_to eq(second)
      expect(first).to be_committed
      expect(second).to be_committed
    end

    it 'scopes receipts by named state machine' do
      two_machines = BasicTwoStateMachinesExample.new

      search = two_machines.aasm(:search).fire_with_receipt!(
        :query,
        event_id: 'evt-shared',
        store: store
      )
      sync = two_machines.aasm(:sync).fire_with_receipt!(
        :sync,
        event_id: 'evt-shared',
        store: store
      )

      expect(search).not_to eq(sync)
      expect(search.state_machine_name).to eq(:search)
      expect(sync.state_machine_name).to eq(:sync)
      expect(search).to be_committed
      expect(sync).to be_committed
    end
  end
end
