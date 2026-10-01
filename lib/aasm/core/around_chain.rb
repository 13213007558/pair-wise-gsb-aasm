# frozen_string_literal: true

module AASM::Core
  # Builds and runs the nested chain of around_transition callbacks that wrap
  # an about-to-happen transition. Every layer receives a controlled
  # +proceed+ object; invoking it drives the next inner layer and, for the
  # innermost callback, performs the real transition (state write plus success
  # callbacks). Across the whole chain +proceed+ can be invoked at most once.
  #
  # If no callback ever calls +proceed+, the transition is cancelled: the
  # record keeps its original state and no success callback is invoked.
  #
  # Exceptions raised before +proceed+ commits bubble up unchanged (the
  # transition never happened). Exceptions raised after a successful commit
  # are wrapped in AASM::TransitionCommittedError so callers can tell the
  # state was already written.
  class AroundChain
    attr_reader :record, :args, :state_machine

    # callbacks: ordered list of callbacks, outermost first
    # core: block performing the real transition, executed at most once
    def initialize(record, state_machine, callbacks, args, &core)
      @record = record
      @state_machine = state_machine
      @callbacks = callbacks
      @args = args
      @core = core
      @called = false
      @committed = false
    end

    # Runs the full around chain. Returns false when the transition was
    # cancelled by an around callback, otherwise the result of the core.
    def run
      if @callbacks.empty?
        invoke_core
        true
      else
        invoke_layer(0)
        committed? ? true : false
      end
    end

    def committed?
      @committed
    end

    private

    # invoke_layer is itself only ever reached through a proceed of the layer
    # directly outside it, except for the outermost layer which is started by
    # #run.
    def invoke_layer(index)
      return if index >= @callbacks.length

      callback = @callbacks[index]
      next_step = if index == @callbacks.length - 1
                    -> { invoke_core }
                  else
                    -> { invoke_layer(index + 1) }
                  end

      begin
        AroundInvoker.new(callback, @record, @args, next_step).invoke
      rescue => e
        raise if e.is_a?(AASM::DoubleProceedError)
        # A failure after the core committed (typical: post-proceed logic of
        # an outer callback) must not be mistaken for a failed transition.
        if @committed
          raise AASM::TransitionCommittedError.new(@record, @state_machine.name, e)
        end
        raise
      end
    end

    def invoke_core
      if @called
        raise AASM::DoubleProceedError.new(
          "around_transition proceed was called more than once; " \
          "the transition can only be executed once"
        )
      end
      @called = true
      result = @core.call
      # a truthy result means the state was actually written; a falsy result
      # (e.g. persistence declined) leaves the record uncommitted
      @committed = true if result
      result
    end
  end
end
