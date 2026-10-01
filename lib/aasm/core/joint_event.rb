# frozen_string_literal: true

module AASM::Core
  # A joint event couples one event on each of several state machines of the
  # same object into a single atomic operation. Firing a joint event happens
  # in three phases:
  #
  # 1. checks   - all before-callbacks run and all guards are evaluated
  #               against the consistent pre-event state. If anything fails
  #               here, no machine is changed at all.
  # 2. commit   - the new state is written on every involved machine.
  # 3. cleanup  - all remaining callbacks (enter/exit/success/after) run.
  #               A failure here is reported through the error callbacks,
  #               but already committed states are never rolled back and
  #               arbitrary external side effects are not undone.
  class JointEvent
    include AASM::DslHelper

    attr_reader :name, :targets, :options

    def initialize(name, targets, options = {}, &block)
      @name = name.to_sym
      @targets = self.class.normalize_targets(targets)
      @options = options
      add_options_from_dsl(@options, [
        :after,
        :before,
        :ensure,
        :error,
        :success,
      ], &block) if block
    end

    def self.normalize_targets(targets)
      targets.to_a.map do |machine_name, event_name|
        [machine_name.to_sym, event_name.to_sym]
      end.freeze
    end

    # resolves the targets to [machine_name, event] pairs, raising
    # AASM::UnknownStateMachineError or AASM::UndefinedEvent for
    # unknown machines or events
    def resolve(obj)
      @targets.map do |machine_name, event_name|
        obj.aasm(machine_name) # raises AASM::UnknownStateMachineError if missing
        event = obj.class.aasm(machine_name).state_machine.events[event_name]
        if event.nil?
          raise AASM::UndefinedEvent, "Event :#{event_name} doesn't exist on state machine :#{machine_name}"
        end
        [machine_name, event]
      end
    end

    # a neutered version of fire - it only executes the guards of every
    # involved event (against the current, pre-event state) to determine
    # whether the joint event could be fired right now.
    def may_fire?(obj, *args)
      resolve(obj).all? { |(_machine_name, event)| event.may_fire?(obj, *args) }
    end

    def fire_callbacks(callback_name, record, *args)
      Invoker.new(@options[callback_name], record, args)
             .with_default_return_value(false)
             .invoke
    end

    def ==(event)
      if event.is_a? Symbol
        name == event
      else
        name == event.name
      end
    end

    def to_s
      name.to_s
    end
  end
end # AASM
