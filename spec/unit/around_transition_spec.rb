require 'spec_helper'

describe 'around transitions' do
  class AroundTransitionExample
    include AASM

    attr_reader :track, :success_count, :guard_calls
    attr_accessor :cancel_global, :cancel_event, :cancel_transition,
                  :fail_guard, :fail_before_global, :fail_after_global,
                  :fail_before_event, :fail_after_event,
                  :fail_before_transition, :fail_after_transition,
                  :double_call_proceed

    def initialize
      @track = []
      @success_count = 0
      @guard_calls = 0
      @write_count = 0
    end

    def write_count
      @write_count
    end

    def reset_track
      @track.clear
    end

    aasm whiny_transitions: false do
      state :sleeping, initial: true
      state :running

      around_transition :global_around

      event :run, before: :before_run, after: :after_run, error: :handle_error do
        around_transition :event_around

        transitions from: :sleeping, to: :running,
                    guard: :run_guard,
                    success: :run_success do
          around_transition :transition_around
        end
      end
    end

    def aasm_write_state(*)
      @write_count += 1
      track << :write
      true
    end

    def before_run
      track << :before_event
    end

    def after_run
      track << :after_event
    end

    def run_guard
      @guard_calls += 1
      track << :guard
      !fail_guard
    end

    def run_success
      @success_count += 1
      track << :success
    end

    def handle_error(error)
      track << [:error, error.message]
      true
    end

    def global_around(proceed, *args)
      track << [:global_before, args]
      raise RuntimeError, :before_global if fail_before_global
      return false if cancel_global

      begin
        result = proceed.call
        track << [:global_after, proceed.committed?, result]
        result
      rescue => error
        track << [:global_error, proceed.committed?, error.message]
        raise unless fail_after_global
        false
      ensure
        track << [:global_ensure, proceed.called?]
      end
    end

    def event_around(proceed, *args)
      track << [:event_before, args]
      raise RuntimeError, :before_event if fail_before_event
      return false if cancel_event

      result = proceed.call
      raise RuntimeError, :after_event if fail_after_event
      track << :event_after
      result
    ensure
      track << [:event_ensure, proceed.called?]
    end

    def transition_around(proceed, *args)
      track << [:transition_before, args]
      raise RuntimeError, :before_transition if fail_before_transition
      return false if cancel_transition

      proceed.call
      if double_call_proceed
        track << :transition_second_call
        proceed.call
      end
      raise RuntimeError, :after_transition if fail_after_transition
      track << :transition_after
    end
  end

  class AroundTransitionInheritedExample < AroundTransitionExample
    aasm do
      around_transition :child_global_around
    end

    def child_global_around(proceed, *args)
      track << [:child_before, proceed.from_state, proceed.to_state, proceed.event.name, args]
      proceed.call
      track << [:child_after, proceed.committed?]
    end
  end

  class AroundTransitionNamedMachineExample
    include AASM

    attr_reader :track

    def initialize
      @track = []
    end

    def aasm_write_state(*)
      track << :write
      true
    end

    aasm(:audit) do
      state :pending, initial: true
      state :approved

      around_transition :audit_around

      event :approve do
        transitions from: :pending, to: :approved
      end
    end

    aasm(:log) do
      state :idle, initial: true
      state :recorded

      around_transition :log_around

      event :record do
        transitions from: :idle, to: :recorded
      end
    end

    aasm(:binding) do
      state :unbound, initial: true
      state :bound

      around_transition :binding_around

      event :bind, binding_event: :record do
        transitions from: :unbound, to: :bound
      end
    end

    def audit_around(proceed)
      track << :audit_before
      proceed.call
      track << [:audit_after, proceed.committed?]
    end

    def log_around(proceed)
      track << :log_before
      proceed.call
      track << [:log_after, proceed.committed?]
    end

    def binding_around(proceed)
      track << :binding_before
      proceed.call
      track << [:binding_after, proceed.committed?]
    end
  end

  it 'runs global, event, and transition callbacks around one committed transition' do
    example = AroundTransitionExample.new
    example.aasm.current_state
    example.reset_track

    expect(example.run!(:audit_id)).to eq(true)
    expect(example).to be_running
    expect(example.write_count).to eq(1)
    expect(example.success_count).to eq(1)
    expect(example.track).to eq([
      :before_event,
      :guard,
      [:global_before, [:audit_id]],
      [:event_before, [:audit_id]],
      [:transition_before, [:audit_id]],
      :write,
      :success,
      :after_event,
      :transition_after,
      :event_after,
      [:event_ensure, true],
      [:global_after, true, true],
      [:global_ensure, true]
    ])
  end

  it 'inherits parent around callbacks and keeps the parent machine unchanged' do
    example = AroundTransitionInheritedExample.new
    example.aasm.current_state
    example.reset_track

    expect(example.run!).to eq(true)
    expect(example.track).to eq([
      :before_event,
      :guard,
      [:global_before, []],
      [:child_before, :sleeping, :running, :run, []],
      [:event_before, []],
      [:transition_before, []],
      :write,
      :success,
      :after_event,
      :transition_after,
      :event_after,
      [:event_ensure, true],
      [:child_after, true],
      [:global_after, true, true],
      [:global_ensure, true]
    ])
    expect(AroundTransitionExample.aasm.state_machine.global_callbacks[:around_transition].map(&:to_s))
      .to eq(['global_around'])
  end

  it 'does not enter the transition or success path when a guard rejects the event' do
    example = AroundTransitionExample.new
    example.aasm.current_state
    example.reset_track
    example.fail_guard = true

    expect(example.run!).to eq(false)
    expect(example).to be_sleeping
    expect(example.write_count).to eq(0)
    expect(example.success_count).to eq(0)
    expect(example.track).to eq([:before_event, :guard])
  end

  it 'cancels when proceed is not called and does not write or fire success' do
    example = AroundTransitionExample.new
    example.aasm.current_state
    example.reset_track
    example.cancel_event = true

    expect(example.run!).to eq(false)
    expect(example).to be_sleeping
    expect(example.write_count).to eq(0)
    expect(example.success_count).to eq(0)
    expect(example.guard_calls).to eq(1)
    expect(example.track).to eq([
      :before_event,
      :guard,
      [:global_before, []],
      [:event_before, []],
      [:event_ensure, false],
      [:global_after, false, false],
      [:global_ensure, true]
    ])
  end

  it 'runs the transition only once when proceed is called twice' do
    example = AroundTransitionExample.new
    example.aasm.current_state
    example.reset_track
    example.double_call_proceed = true
    example.fail_after_global = true

    expect(example.run!).to eq(false)
    expect(example).to be_running
    expect(example.write_count).to eq(1)
    expect(example.success_count).to eq(1)
    expect(example.guard_calls).to eq(1)
    expect(example.track).to include(
      :write,
      :success,
      :transition_second_call,
      [:global_error, true, 'around_transition proceed can only be called once']
    )
    expect(example.track.grep(:write).size).to eq(1)
    expect(example.track.grep(:success).size).to eq(1)
  end

  it 'reports an exception before proceed as not committed without writing state' do
    example = AroundTransitionExample.new
    example.aasm.current_state
    example.reset_track
    example.fail_before_transition = true

    expect(example.run!).to eq(false)
    expect(example).to be_sleeping
    expect(example.write_count).to eq(0)
    expect(example.success_count).to eq(0)
    expect(example.track).to eq([
      :before_event,
      :guard,
      [:global_before, []],
      [:event_before, []],
      [:transition_before, []],
      [:event_ensure, true],
      [:global_error, false, 'before_transition'],
      [:global_ensure, true],
      [:error, 'before_transition']
    ])
  end

  it 'reports an inner exception after proceed as already committed' do
    example = AroundTransitionExample.new
    example.aasm.current_state
    example.reset_track
    example.fail_after_transition = true

    expect(example.run!).to eq(false)
    expect(example).to be_running
    expect(example.write_count).to eq(1)
    expect(example.success_count).to eq(1)
    expect(example.track).to eq([
      :before_event,
      :guard,
      [:global_before, []],
      [:event_before, []],
      [:transition_before, []],
      :write,
      :success,
      :after_event,
      [:event_ensure, true],
      [:global_error, true, 'after_transition'],
      [:global_ensure, true],
      [:error, 'after_transition']
    ])
  end

  it 'lets an outer around callback observe a committed inner post-proceed exception' do
    example = AroundTransitionExample.new
    example.aasm.current_state
    example.reset_track
    example.fail_after_event = true

    expect(example.run!).to eq(false)
    expect(example).to be_running
    expect(example.write_count).to eq(1)
    expect(example.success_count).to eq(1)
    expect(example.track).to eq([
      :before_event,
      :guard,
      [:global_before, []],
      [:event_before, []],
      [:transition_before, []],
      :write,
      :success,
      :after_event,
      :transition_after,
      [:event_ensure, true],
      [:global_error, true, 'after_event'],
      [:global_ensure, true],
      [:error, 'after_event']
    ])
  end

  it 'keeps around callbacks scoped to named machines and nests reentrant events' do
    audited = AroundTransitionNamedMachineExample.new
    audited.aasm(:audit).current_state
    audited.track.clear
    expect(audited.approve!).to eq(true)
    expect(audited.track).to eq([
      :audit_before,
      :write,
      [:audit_after, true]
    ])

    recorded = AroundTransitionNamedMachineExample.new
    recorded.aasm(:log).current_state
    recorded.track.clear
    expect(recorded.record!).to eq(true)
    expect(recorded.track).to eq([
      :log_before,
      :write,
      [:log_after, true]
    ])

    bound = AroundTransitionNamedMachineExample.new
    bound.aasm(:binding).current_state
    bound.track.clear
    expect(bound.bind!).to eq(true)
    expect(bound).to be_bound
    expect(bound).to be_recorded
    expect(bound.track).to eq([
      :binding_before,
      :write,
      :log_before,
      :write,
      [:log_after, true],
      [:binding_after, true]
    ])
  end
end
