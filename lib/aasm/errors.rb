module AASM

  class UnknownStateMachineError < RuntimeError; end

  class InvalidTransition < RuntimeError
    attr_reader :object, :event_name, :originating_state, :failures, :state_machine_name

    def initialize(object, event_name, state_machine_name, failures = [])
      @object, @event_name, @originating_state, @failures = object, event_name, object.aasm(state_machine_name).current_state, failures
      @state_machine_name = state_machine_name
      super("Event '#{event_name}' cannot transition from '#{originating_state}'.#{reasoning}")
    end

    def reasoning
      " Failed callback(s): #{failures}." unless failures.empty?
    end
  end

  class UndefinedState < RuntimeError; end
  class UndefinedEvent < UndefinedState; end
  class NoDirectAssignmentError < RuntimeError; end

  # Raised when the controlled +proceed+ of an around_transition callback is
  # invoked more than once. The first invocation already executed (or is in
  # the process of executing) the transition.
  class DoubleProceedError < RuntimeError; end

  # Wraps an exception raised by an around_transition callback after the
  # transition itself has already committed (state written, success callbacks
  # fired). The wrapped error is available via #cause / #original_error.
  class TransitionCommittedError < RuntimeError
    attr_reader :object, :state_machine_name, :originating_state, :current_state, :original_error

    def initialize(object, state_machine_name, original_error)
      @object = object
      @state_machine_name = state_machine_name
      @original_error = original_error
      @originating_state = begin; object.aasm(state_machine_name).from_state; rescue StandardError; end
      @current_state = begin; object.aasm(state_machine_name).current_state; rescue StandardError; end
      super("around_transition callback failed after the transition from " \
            "#{@originating_state.inspect} to #{@current_state.inspect} was already " \
            "committed: #{original_error.class}: #{original_error.message}")
      # backtrace points at the callback failure, not at this wrapper
      set_backtrace(original_error.backtrace)
    end
  end
end
