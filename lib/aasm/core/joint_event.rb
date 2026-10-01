# frozen_string_literal: true

module AASM::Core
  # A joint event coordinates one event on each of several state machines
  # of the same object (e.g. +payment+ and +delivery+ of an order).
  #
  # Firing a joint event is a two-phase process:
  #
  # 1. check - the transition of every participant is resolved first. All
  #    guards run against the same, consistent pre-event state of every
  #    machine and nothing is changed yet. If any participant refuses, the
  #    joint +error+ callbacks run and no machine has been touched - no
  #    state changes and no success callbacks of any participant.
  # 2. commit - the state changes of all participants are committed one
  #    machine after another. Joint +before+ callbacks run before the first
  #    commit, joint +after+ callbacks after the last one. If a callback
  #    raises during or after the commit, the joint +error+ callbacks run
  #    and the exception is re-raised; state changes already committed stay
  #    committed (the current states report what has been committed) and
  #    arbitrary external side effects are not rolled back.
  class JointEvent
    include AASM::DslHelper

    attr_reader :name, :participants

    def initialize(name, participants, options = {}, &block)
      @name = name.to_sym
      @participants = participants.map do |state_machine_name, event_name|
        [state_machine_name.to_sym, event_name.to_sym]
      end
      @options = options
      add_options_from_dsl(@options, [:before, :after, :error], &block) if block
    end

    # true when every participant event may fire right now. Nothing is changed.
    def may_fire?(obj, *args)
      participants.all? do |state_machine_name, event_name|
        event = event_for(obj, state_machine_name, event_name)
        event && event.may_fire?(obj, *args)
      end
    end

    def fire(obj, *args)
      plans = []
      failure = nil

      # phase 1: check all targets against the pre-event state
      participants.each do |state_machine_name, event_name|
        event = event_for(obj, state_machine_name, event_name)
        transition = event && event.may_fire?(obj, *args)
        if transition
          plans << [state_machine_name, event_name, transition]
        else
          failure = [state_machine_name, event_name, event]
          break
        end
      end

      unless failure.nil?
        state_machine_name, event_name, event = failure
        failures = event ? event.failed_callbacks : []
        fire_callbacks(:error, obj, [AASM::InvalidTransition.new(obj, event_name, state_machine_name, failures), *args])
        return obj.send(
          :aasm_failed,
          state_machine_name,
          event_name,
          obj.aasm(state_machine_name).state_object_for_name(obj.aasm(state_machine_name).current_state),
          failures
        )
      end

      # phase 2: commit all participants
      fire_callbacks(:before, obj, args)
      begin
        plans.each do |state_machine_name, event_name, transition|
          # for plain Ruby objects persisting is a no-op write, so the
          # full callback chain (including success callbacks) runs
          obj.send(
            :aasm_fire_event,
            state_machine_name,
            event_name,
            { :persist => true, :resolved_transition => transition },
            *args
          )
        end
        fire_callbacks(:after, obj, args)
      rescue StandardError => e
        # already committed state changes stay committed; external side
        # effects are not rolled back
        fire_callbacks(:error, obj, [e, *args])
        raise
      end

      true
    end

  private

    def event_for(obj, state_machine_name, event_name)
      obj.class.aasm(state_machine_name).state_machine.events[event_name]
    end

    def fire_callbacks(callback_name, obj, args)
      Invoker.new(@options[callback_name], obj, args)
             .with_default_return_value(false)
             .invoke
    end
  end
end # AASM
