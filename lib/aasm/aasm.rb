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

    # define a joint event, coupling one event on each of several state
    # machines of this class into a single atomic operation:
    #
    #   aasm_joint_event :confirm_shipment, :payment => :pay, :delivery => :ship
    #
    # all guards are checked against the consistent pre-event state first;
    # only then all state changes are committed together. optional joint-level
    # callbacks (:before, :success, :after, :error, :ensure) can be given as
    # options or via a block.
    def aasm_joint_event(name, targets, options = {}, &block)
      joint_event = AASM::Core::JointEvent.new(name, targets, options, &block)

      define_method(name) do |*args|
        aasm_fire_joint_event(joint_event, {:persist => false}, *args)
      end

      define_method(:"#{name}!") do |*args|
        aasm_fire_joint_event(joint_event, {:persist => true}, *args)
      end

      define_method(:"may_#{name}?") do |*args|
        joint_event.may_fire?(self, *args)
      end

      joint_event
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
    begin
      old_state = aasm(state_machine_name).state_object_for_name(aasm(state_machine_name).current_state)

      fire_default_callbacks(event, *process_args(event, aasm(state_machine_name).current_state, *args))

      if may_fire_to = event.may_fire?(self, *args)
        fire_exit_callbacks(old_state, *process_args(event, aasm(state_machine_name).current_state, *args))
        if new_state_name = event.fire(self, {:may_fire => may_fire_to}, *args)
          aasm_fired(state_machine_name, event, old_state, new_state_name, options, *args, &block)
        else
          aasm_failed(state_machine_name, event_name, old_state, event.failed_callbacks)
        end
      else
        aasm_failed(state_machine_name, event_name, old_state, event.failed_callbacks)
      end
    rescue StandardError => e
      event.fire_callbacks(:error, self, e, *process_args(event, aasm(state_machine_name).current_state, *args)) ||
      event.fire_global_callbacks(:error_on_all_events, self, e, *process_args(event, aasm(state_machine_name).current_state, *args)) ||
      raise(e)
      false
    ensure
      event.fire_callbacks(:ensure, self, *process_args(event, aasm(state_machine_name).current_state, *args))
      event.fire_global_callbacks(:ensure_on_all_events, self, *process_args(event, aasm(state_machine_name).current_state, *args))
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

  def aasm_failed(state_machine_name, event_name, old_state, failures = [])
    if self.respond_to?(:aasm_event_failed)
      self.aasm_event_failed(event_name, old_state.name)
    end

    if AASM::StateMachineStore.fetch(self.class, true).machine(state_machine_name).config.whiny_transitions
      raise AASM::InvalidTransition.new(self, event_name, state_machine_name, failures)
    else
      false
    end
  end

  # fires a joint event (see AASM::Core::JointEvent) in three phases:
  #
  # 1. checks - run all before-callbacks and evaluate all guards against
  #    the consistent pre-event state. Any failure here (including a
  #    rejected guard on any machine) leaves every machine untouched and
  #    no success callback is fired.
  # 2. commit - write the new state on every involved machine.
  # 3. cleanup - run all remaining callbacks. A failure here is reported
  #    through the error callbacks with the states already committed;
  #    committed states are never rolled back and arbitrary external
  #    side effects are not undone.
  #
  # callback order (targets in declaration order):
  #   joint :before
  #   per event: :before_all_events, :before
  #   per event: guard checks (all before any state change)
  #   per event: old state :before_exit, :exit
  #   per event: state commit
  #   per event: new state :before_enter, :enter, transition :after,
  #              :before_success, transition :success, :success
  #   per event: old state :after_exit, new state :after_enter, :after,
  #              :after_all_events
  #   joint :success, :after
  #   per event: :ensure, :ensure_on_all_events, then joint :ensure
  # on error: per event :error, :error_on_all_events, then joint :error
  def aasm_fire_joint_event(joint_event, options, *args)
    persist = options[:persist]
    plans = joint_event.resolve(self).map do |machine_name, event|
      {:machine => machine_name, :event => event}
    end

    begin
      joint_event.fire_callbacks(:before, self, *args)

      # phase 1: checks - before-callbacks and guards for every target,
      # all evaluated against the untouched pre-event state
      plans.each do |plan|
        aasm(plan[:machine]).current_event = persist ? :"#{plan[:event].name}!" : plan[:event].name
        fire_default_callbacks(plan[:event], *args)
      end

      plans.each do |plan|
        plan[:old_state] = aasm(plan[:machine]).state_object_for_name(aasm(plan[:machine]).current_state)
        plan[:transition] = plan[:event].may_fire?(self, *args)
      end

      return aasm_joint_failed(joint_event, plans) if plans.any? { |plan| !plan[:transition] }

      plans.each do |plan|
        plan[:new_state_name] = Array(plan[:transition].to).first
        plan[:new_state] = aasm(plan[:machine]).state_object_for_name(plan[:new_state_name])
        fire_exit_callbacks(plan[:old_state], *args)
      end

      # phase 2: commit all state changes
      plans.each do |plan|
        if persist
          plan[:committed] = aasm(plan[:machine]).set_current_state_with_persistence(plan[:new_state_name])
        else
          aasm(plan[:machine]).current_state = plan[:new_state_name]
          plan[:committed] = true
        end
      end

      # phase 3: post-commit callbacks - failures from here on are reported
      # via the error callbacks, but committed states are not rolled back
      plans.each do |plan|
        plan[:new_state].fire_callbacks(:before_enter, self, *args)
        plan[:new_state].fire_callbacks(:enter, self, *args)
        plan[:transition].execute(self, *args)
        next unless plan[:committed]
        plan[:event].fire_callbacks(:before_success, self, *args)
        plan[:transition].invoke_success_callbacks(self, *args)
        plan[:event].fire_callbacks(:success, self, *args)
      end

      plans.each do |plan|
        if plan[:committed]
          plan[:old_state].fire_callbacks(:after_exit, self, *args)
          plan[:new_state].fire_callbacks(:after_enter, self, *args)
          plan[:event].fire_callbacks(:after, self, *args)
          plan[:event].fire_global_callbacks(:after_all_events, self, *args)
          self.aasm_event_fired(plan[:event].name, plan[:old_state].name, aasm(plan[:machine]).current_state) if self.respond_to?(:aasm_event_fired)
        else
          self.aasm_event_failed(plan[:event].name, plan[:old_state].name) if self.respond_to?(:aasm_event_failed)
        end
      end

      joint_event.fire_callbacks(:success, self, *args)
      joint_event.fire_callbacks(:after, self, *args)

      plans.all? { |plan| plan[:committed] }
    rescue StandardError => e
      handled = plans.any? do |plan|
        plan[:event].fire_callbacks(:error, self, e, *args) ||
        plan[:event].fire_global_callbacks(:error_on_all_events, self, e, *args)
      end
      handled = joint_event.fire_callbacks(:error, self, e, *args) || handled
      raise(e) unless handled
      false
    ensure
      plans.each do |plan|
        plan[:event].fire_callbacks(:ensure, self, *args)
        plan[:event].fire_global_callbacks(:ensure_on_all_events, self, *args)
      end
      joint_event.fire_callbacks(:ensure, self, *args)
    end
  end

  def aasm_joint_failed(joint_event, plans)
    failed_plans = plans.select { |plan| !plan[:transition] }

    if self.respond_to?(:aasm_event_failed)
      failed_plans.each { |plan| self.aasm_event_failed(plan[:event].name, plan[:old_state].name) }
    end

    whiny = failed_plans.any? do |plan|
      AASM::StateMachineStore.fetch(self.class, true).machine(plan[:machine]).config.whiny_transitions
    end
    if whiny
      first_failure = failed_plans.first
      raise AASM::InvalidTransition.new(self, joint_event.name, first_failure[:machine], first_failure[:event].failed_callbacks)
    end
    false
  end

end
