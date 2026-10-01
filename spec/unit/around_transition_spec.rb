require 'spec_helper'

describe 'around_transition callbacks' do
  # A recorder model with three nested around layers and a full set of
  # ordinary callbacks, so the exact event trajectory can be asserted.
  def build_recorder_class
    Class.new do
      include AASM

      attr_reader :trace, :writes, :success_count

      def initialize
        @trace = []
        @writes = 0
        @success_count = 0
      end

      aasm do
        around_all_transitions :global_around

        state :pending, initial: true,
          exit: :exit_pending
        state :running,
          before_enter: :before_enter_running,
          after_enter: :after_enter_running

        event :run,
          around_transition: :event_around,
          after: :event_after,
          success: :event_success,
          guard: :gate_open do
          transitions(
            from: :pending,
            to: :running,
            around_transition: :transition_around,
            after: :transition_after,
            success: :transition_success,
            guard: :transition_gate_open
          )
        end
      end

      def aasm_write_state(*)
        @trace << :write_state
        @writes += 1
        true
      end

      def gate_open; @trace << :event_guard; true; end
      def transition_gate_open; @trace << :transition_guard; true; end

      def global_around(proceed, *)
        @trace << :global_before
        proceed.call
        @trace << :global_after
      end

      def event_around(proceed, *)
        @trace << :event_before
        proceed.call
        @trace << :event_after_around
      end

      def transition_around(proceed, *)
        @trace << :transition_before
        proceed.call
        @trace << :transition_after_around
      end

      def exit_pending; @trace << :exit_pending; end
      def before_enter_running; @trace << :before_enter_running; end
      def after_enter_running; @trace << :after_enter_running; end
      def transition_after; @trace << :transition_after; end
      def event_after; @trace << :event_after; end

      def transition_success
        @trace << :transition_success
        @success_count += 1
      end

      def event_success
        @trace << :event_success
      end
    end
  end

  it 'wraps the transition global -> event -> transition and logs the full trajectory' do
    klass = build_recorder_class
    recorder = klass.new

    expect(recorder.run!).to eq true
    expect(recorder.aasm.current_state).to eq :running

    expect(recorder.trace).to eq [
      :event_guard,
      :transition_guard,
      :global_before,
      :event_before,
      :transition_before,
      :exit_pending,
      :transition_after,
      :before_enter_running,
      :write_state,
      :transition_success,
      :event_success,
      :after_enter_running,
      :event_after,
      :transition_after_around,
      :event_after_around,
      :global_after,
    ]
  end

  it 'writes the state and fires success callbacks exactly once' do
    recorder = build_recorder_class.new
    recorder.run!
    expect(recorder.writes).to eq 1
    expect(recorder.success_count).to eq 1
    expect(recorder.trace.count(:write_state)).to eq 1
    expect(recorder.trace.count(:transition_success)).to eq 1
  end

  describe 'cancellation' do
    it 'treats not calling proceed as cancellation: state and success callbacks stay untouched' do
      klass = build_recorder_class
      klass.send(:define_method, :transition_around) do |proceed, *|
        @trace << :transition_before_cancelled
        # proceed is intentionally never called
      end
      recorder = klass.new

      expect(recorder.run!).to eq false
      expect(recorder.aasm.current_state).to eq :pending
      expect(recorder.writes).to eq 0
      expect(recorder.success_count).to eq 0
      expect(recorder.trace).to include(:global_before, :event_before, :transition_before_cancelled,
                                        :event_after_around, :global_after)
      expect(recorder.trace).not_to include(:write_state, :transition_success, :event_success,
                                           :exit_pending, :event_after)
    end

    it 'does not run around callbacks at all when a guard rejects the transition' do
      klass = build_recorder_class
      klass.send(:define_method, :transition_gate_open) do
        @trace << :transition_guard_failed
        false
      end
      recorder = klass.new

      expect { recorder.run! }.to raise_error(AASM::InvalidTransition)
      expect(recorder.aasm.current_state).to eq :pending
      expect(recorder.trace).to eq [:event_guard, :transition_guard_failed]
    end
  end

  describe 'proceed called twice' do
    it 'raises DoubleProceedError while executing the transition only once' do
      klass = build_recorder_class
      klass.send(:define_method, :event_around) do |proceed, *|
        @trace << :event_before_double
        proceed.call
        proceed.call
      end
      recorder = klass.new

      expect { recorder.run! }.to raise_error(AASM::DoubleProceedError)
      expect(recorder.writes).to eq 1
      expect(recorder.success_count).to eq 1
      expect(recorder.trace.count(:write_state)).to eq 1
    end
  end

  describe 'persistence failure' do
    it 'returns false without running post-proceed logic as committed' do
      klass = build_recorder_class
      klass.send(:define_method, :aasm_write_state) do |*|
        @writes += 1
        @trace << :write_state
        false
      end
      recorder = klass.new

      expect(recorder.run!).to eq false
      expect(recorder.writes).to eq 1
      expect(recorder.success_count).to eq 0
      expect(recorder.trace).not_to include(:transition_success, :event_success)
      expect(recorder.aasm.current_state).to eq :pending
    end
  end

  describe 'exceptions' do
    it 'lets pre-proceed exceptions propagate with the transition never happening' do
      klass = build_recorder_class
      klass.send(:define_method, :event_around) do |proceed, *|
        @trace << :event_before_boom
        raise 'before commit'
      end
      recorder = klass.new

      expect { recorder.run! }.to raise_error(RuntimeError, 'before commit')
      expect(recorder.aasm.current_state).to eq :pending
      expect(recorder.writes).to eq 0
      expect(recorder.success_count).to eq 0
      expect(recorder.trace).to include(:global_before, :event_before_boom)
      expect(recorder.trace).not_to include(:global_after, :event_after_around, :write_state)
    end

    it 'wraps post-proceed exceptions of an outer layer in TransitionCommittedError' do
      klass = build_recorder_class
      klass.send(:define_method, :global_around) do |proceed, *|
        @trace << :global_before
        proceed.call
        @trace << :global_commit_done
        raise 'after commit'
      end
      recorder = klass.new

      begin
        recorder.run!
        raise 'expected TransitionCommittedError'
      rescue AASM::TransitionCommittedError => e
        expect(e.original_error).to be_a(RuntimeError)
        expect(e.original_error.message).to eq 'after commit'
        expect(e.cause).to be_a(RuntimeError)
        expect(e.current_state).to eq :running
        expect(e.originating_state).to eq :pending
      end
      expect(recorder.aasm.current_state).to eq :running
      expect(recorder.writes).to eq 1
      expect(recorder.success_count).to eq 1
    end

    it 'passes pre-commit exceptions to the event error callback unchanged' do
      klass = build_recorder_class
      captured = nil
      klass.aasm.state_machine.events[:run].options[:error] = ->(e) { captured = e; true }
      klass.send(:define_method, :transition_around) do |proceed, *|
        raise 'still pending'
      end
      recorder = klass.new

      expect(recorder.run!).to eq false
      expect(captured).to be_a(RuntimeError)
      expect(captured.message).to eq 'still pending'
      expect(recorder.aasm.current_state).to eq :pending
    end
  end

  describe 'inheritance' do
    it 'uses around callbacks inherited from the parent machine and keeps the parent untouched' do
      parent = Class.new do
        include AASM
        attr_reader :trace
        def initialize; @trace = []; end
        aasm do
          around_all_transitions :parent_around
          state :a, initial: true
          state :b
          event :go do
            transitions from: :a, to: :b
          end
        end
        def parent_around(proceed)
          @trace << :parent_before
          proceed.call
          @trace << :parent_after
        end
      end

      child = Class.new(parent) do
        aasm do
          around_all_transitions :child_around
          event :go do
            transitions from: :a, to: :b, around_transition: :child_event_around
          end
        end
        def child_around(proceed)
          @trace << :child_before
          proceed.call
          @trace << :child_after
        end
        def child_event_around(proceed)
          @trace << :child_event_before
          proceed.call
          @trace << :child_event_after
        end
      end

      child_instance = child.new
      child_instance.go!
      expect(child_instance.trace).to eq [
        :parent_before, :child_before, :child_event_before,
        :child_event_after, :child_after, :parent_after,
      ]
      expect(child_instance.aasm.current_state).to eq :b

      parent_instance = parent.new
      parent_instance.go!
      expect(parent_instance.trace).to eq [:parent_before, :parent_after]
    end
  end

  describe 'named state machines' do
    it 'keeps around chains isolated per machine' do
      klass = Class.new do
        include AASM
        attr_reader :trace
        def initialize; @trace = []; end

        aasm(:left) do
          around_all_transitions :left_around
          state :l1, initial: true
          state :l2
          event :go do
            transitions from: :l1, to: :l2
          end
        end

        aasm(:right) do
          state :r1, initial: true
          state :r2
          event :go_right do
            transitions from: :r1, to: :r2
          end
        end

        def left_around(proceed)
          @trace << :left_before
          proceed.call
          @trace << :left_after
        end
      end

      machine = klass.new
      machine.aasm(:right).fire(:go_right)
      machine.aasm(:left).fire(:go)
      expect(machine.trace).to eq [:left_before, :left_after]
      expect(machine.aasm(:left).current_state).to eq :l2
      expect(machine.aasm(:right).current_state).to eq :r2
    end
  end

  describe 'reentrant events' do
    it 'keeps outer and inner around chains independent and ordered' do
      klass = Class.new do
        include AASM
        attr_reader :trace
        def initialize; @trace = []; end

        aasm do
          around_all_transitions :wrap_all
          state :idle, initial: true
          state :primed
          state :done
          event :prime, after: :after_prime do
            transitions from: :idle, to: :primed
          end
          event :finish do
            transitions from: :primed, to: :done
          end
        end

        def wrap_all(proceed)
          @trace << "before:#{aasm.current_event}"
          proceed.call
          @trace << "after:#{aasm.current_event}"
        end

        def after_prime
          @trace << :primed
          finish!
        end
      end

      machine = klass.new
      machine.prime!
      expect(machine.aasm.current_state).to eq :done
      expect(machine.trace).to eq [
        'before:prime!',
        :primed,
        'before:finish!',
        'after:finish!',
        'after:prime!',
      ]
    end
  end

  describe 'callback shapes' do
    it 'supports a block evaluated on the record with proceed and event args' do
      klass = Class.new do
        include AASM
        attr_reader :trace
        def initialize; @trace = []; end
        aasm do
          state :a, initial: true
          state :b
          event :go do
            transitions from: :a, to: :b, around_transition: ->(proceed, amount) {
              @trace << [:block_before, amount]
              proceed.call
              @trace << :block_after
            }
          end
        end
      end

      machine = klass.new
      machine.go!(42)
      expect(machine.trace).to eq [[:block_before, 42], :block_after]
    end

    it 'rejects a callback that cannot accept proceed' do
      klass = Class.new do
        include AASM
        attr_reader :trace
        def initialize; @trace = []; end
        aasm do
          state :a, initial: true
          state :b
          event :go do
            transitions from: :a, to: :b, around_transition: :no_args
          end
        end
        def no_args; end
      end

      expect { klass.new.go! }.to raise_error(ArgumentError, /must accept a proceed argument/)
    end
  end
end
