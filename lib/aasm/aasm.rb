module AASM
  # this is used internally as an argument default value to represent no value
  NO_VALUE = :_aasm_no_value

  # provide a state machine for the including class
  # make sure to load class methods as well
  # initialize persistence for the state machine
  def self.included(base) #:nodoc:
    base.extend AASM::ClassMethods

    # do not overwrite existing state machines, which could have been created by
    # inheritance, see class method inherited
    AASM::StateMachineStore.register(base)

    AASM::Persistence.load_persistence(base)
    super
  end

  module ClassMethods
    # make sure inheritance (aka subclassing) works with AASM
    def inherited(base)
      AASM::StateMachineStore.register(base, self)

      super
    end

    # this is the entry point for all state and event definitions
    def aasm(*args, &block)
      if args[0].is_a?(Symbol) || args[0].is_a?(String)
        # using custom name
        state_machine_name = args[0].to_sym
        options = args[1] || {}
      else
        # using the default state_machine_name
        state_machine_name = :default
        options = args[0] || {}
      end

      AASM::StateMachineStore.fetch(self, true).register(state_machine_name, AASM::StateMachine.new(state_machine_name))

      # use a default despite the DSL configuration default.
      # this is because configuration hasn't been setup for the AASM class but we are accessing a DSL option already for the class.
      aasm_klass = options[:with_klass] || AASM::Base

      raise ArgumentError, "The class #{aasm_klass} must inherit from AASM::Base!" unless aasm_klass.ancestors.include?(AASM::Base)

      @aasm ||= Concurrent::Map.new
      if @aasm[state_machine_name]
        # make sure to use provided options
        options.each do |key, value|
          @aasm[state_machine_name].state_machine.config.send("#{key}=", value)
        end
      else
        # create a new base
        @aasm[state_machine_name] = aasm_klass.new(
          self,
          state_machine_name,
          AASM::StateMachineStore.fetch(self, true).machine(state_machine_name),
          options
        )
      end
      @aasm[state_machine_name].instance_eval(&block) if block # new DSL
      @aasm[state_machine_name]
    end
  end # ClassMethods

  # this is the entry point for all instance-level access to AASM
  def aasm(name=:default)
    unless AASM::StateMachineStore.fetch(self.class, true).machine(name)
      raise AASM::UnknownStateMachineError.new("There is no state machine with the name '#{name}' defined in #{self.class.name}!")
    end
    @aasm ||= Concurrent::Map.new
    @aasm[name.to_sym] ||= AASM::InstanceBase.new(self, name.to_sym)
  end

  def initialize_dup(other)
    @aasm = Concurrent::Map.new
    super
  end

private

  def aasm_event_receipt_object_key
    object_id
  end

  # Takes args and a from state and removes the first
  # element from args if it is a valid to_state for
  # the event given the from_state
  def process_args(event, from_state, *args)
    # If the first arg doesn't respond to to_sym then
    # it isn't a symbol or string so it can't be a state
    # name anyway
    return args unless args.first.respond_to?(:to_sym)
    if event.transitions_from_state(from_state).map(&:to).flatten.include?(args.first)
      return args[1..-1]
    end
    return args
  end

  def aasm_fire_event(state_machine_name, event_name, options, *args, &block)
    event = self.class.aasm(state_machine_name).state_machine.events[event_name]
    receipt = options[:event_receipt]
    receipt_store = options[:event_receipt_store]
    defer_post_commit = options[:event_receipt_defer_post_commit]
    result = nil

    begin
      old_state = aasm(state_machine_name).state_object_for_name(aasm(state_machine_name).current_state)
      receipt.from_state = old_state.name if receipt

      fire_default_callbacks(event, *process_args(event, aasm(state_machine_name).current_state, *args))

      if may_fire_to = event.may_fire?(self, *args)
        fire_exit_callbacks(old_state, *process_args(event, aasm(state_machine_name).current_state, *args))
        if new_state_name = event.fire(self, {:may_fire => may_fire_to}, *args)
          result = aasm_fired(state_machine_name, event, old_state, new_state_name, options, *args, &block)
        else
          result = aasm_failed(state_machine_name, event_name, old_state, event.failed_callbacks, options)
        end
      else
        result = aasm_failed(state_machine_name, event_name, old_state, event.failed_callbacks, options)
      end
    rescue StandardError => e
      mark_event_receipt(receipt, receipt_store, defer_post_commit, false, e)
      event.fire_callbacks(:error, self, e, *process_args(event, aasm(state_machine_name).current_state, *args)) ||
      event.fire_global_callbacks(:error_on_all_events, self, e, *process_args(event, aasm(state_machine_name).current_state, *args)) ||
      raise(e)
      false
    ensure
      begin
        event.fire_callbacks(:ensure, self, *process_args(event, aasm(state_machine_name).current_state, *args))
        event.fire_global_callbacks(:ensure_on_all_events, self, *process_args(event, aasm(state_machine_name).current_state, *args))
      rescue StandardError => ensure_error
        mark_event_receipt(receipt, receipt_store, defer_post_commit, false, ensure_error)
        raise
      end

      if result
        mark_event_receipt(receipt, receipt_store, defer_post_commit, true)
      elsif !defer_post_commit
        mark_event_receipt(receipt, receipt_store, false, false)
      end
    end
  end

  def mark_event_receipt(receipt, receipt_store, deferred, success, error = nil)
    return unless receipt && receipt_store
    return if receipt.terminal? || deferred

    if success
      receipt.begin_post_commit
      receipt_store.mark(
        receipt,
        :committed,
        result: true,
        to_state: aasm(receipt.state_machine_name).current_state
      )
    else
      status = receipt.post_commit_started ? :post_commit_callback_failed : :not_accepted
      receipt_store.mark(
        receipt,
        status,
        result: receipt.post_commit_started ? true : false,
        error: error
      )
    end
  end

  def fire_default_callbacks(event, *processed_args)
    event.fire_global_callbacks(
      :before_all_events,
      self,
      *processed_args
    )

    # new event before callback
    event.fire_callbacks(
      :before,
      self,
      *processed_args
    )
  end

  def fire_exit_callbacks(old_state, *processed_args)
    old_state.fire_callbacks(:before_exit, self, *processed_args)
    old_state.fire_callbacks(:exit, self, *processed_args)
  end

  def aasm_fired(state_machine_name, event, old_state, new_state_name, options, *args)
    persist = options[:persist]

    new_state = aasm(state_machine_name).state_object_for_name(new_state_name)
    callback_args = process_args(event, aasm(state_machine_name).current_state, *args)

    new_state.fire_callbacks(:before_enter, self, *callback_args)

    new_state.fire_callbacks(:enter, self, *callback_args) # TODO: remove for AASM 4?

    persist_successful = true
    if persist
      persist_successful = aasm(state_machine_name).set_current_state_with_persistence(new_state_name)
      if persist_successful
        options[:event_receipt]&.begin_post_commit
        options[:event_receipt].to_state = new_state_name if options[:event_receipt]
        yield if block_given?
        event.fire_callbacks(:before_success, self, *callback_args)
        event.fire_transition_callbacks(self, *process_args(event, old_state.name, *args))
        event.fire_callbacks(:success, self, *callback_args)
      end
    else
      aasm(state_machine_name).current_state = new_state_name
      yield if block_given?
    end

    binding_event = event.options[:binding_event]
    if binding_event
      __send__("#{binding_event}#{'!' if persist}")
    end

    if persist_successful
      old_state.fire_callbacks(:after_exit, self, *callback_args)
      new_state.fire_callbacks(:after_enter, self, *callback_args)
      event.fire_callbacks(
        :after,
        self,
        *process_args(event, old_state.name, *args)
      )
      event.fire_global_callbacks(
        :after_all_events,
        self,
        *process_args(event, old_state.name, *args)
      )

      self.aasm_event_fired(event.name, old_state.name, aasm(state_machine_name).current_state) if self.respond_to?(:aasm_event_fired)
    else
      self.aasm_event_failed(event.name, old_state.name) if self.respond_to?(:aasm_event_failed)
    end

    persist_successful
  end

  def aasm_failed(state_machine_name, event_name, old_state, failures = [], options = {})
    if self.respond_to?(:aasm_event_failed)
      self.aasm_event_failed(event_name, old_state.name)
    end

    if AASM::StateMachineStore.fetch(self.class, true).machine(state_machine_name).config.whiny_transitions
      error = AASM::InvalidTransition.new(self, event_name, state_machine_name, failures)
      if options[:event_receipt]
        mark_event_receipt(
          options[:event_receipt],
          options[:event_receipt_store],
          options[:event_receipt_defer_post_commit],
          false,
          error
        )
      end
      raise error
    else
      if options[:event_receipt]
        mark_event_receipt(
          options[:event_receipt],
          options[:event_receipt_store],
          options[:event_receipt_defer_post_commit],
          false
        )
      end
      false
    end
  end

end
