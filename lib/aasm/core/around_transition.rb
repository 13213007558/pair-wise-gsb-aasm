# frozen_string_literal: true

module AASM
  module Core
    class AroundTransition
      class Proceed
        attr_reader :state_machine, :event, :from_state, :to_state, :args

        def initialize(chain, index, event, from_state, to_state, args)
          @chain = chain
          @index = index
          @state_machine = event.state_machine.name
          @event = event
          @from_state = from_state
          @to_state = to_state
          @args = args.dup
          @called = false
        end

        def call
          if @called
            @chain.mark_double_call
            raise AASM::AroundTransitionDoubleCallError, 'around_transition proceed can only be called once'
          end

          @called = true
          @chain.continue(@index)
        end

        def called?
          @called
        end

        def committed?
          @chain.committed?
        end
        alias_method :transitioned?, :committed?
      end

      def self.invoke(callbacks, record, args, event, from_state, to_state, &core)
        new(callbacks, record, args, event, from_state, to_state, &core).invoke
      end

      def initialize(callbacks, record, args, event, from_state, to_state, &core)
        @callbacks = Array(callbacks)
        @record = record
        @args = args
        @event = event
        @from_state = from_state
        @to_state = to_state
        @core = core
        @committed = false
        @last_result = nil
      end

      def invoke
        @last_result = run_callback(0)
      end

      def continue(index)
        @last_result = run_callback(index + 1)
      end

      def committed?
        @committed
      end

      def mark_double_call
        @double_call_raised = true
      end

      def double_call_raised?
        @double_call_raised == true
      end

      private

      def run_callback(index)
        if index == @callbacks.size
          @last_result = @core.call
          @committed = true if @last_result == true
          return @last_result
        end

        proceed = Proceed.new(self, index, @event, @from_state, @to_state, @args)
        callback_result = AASM::Core::Invoker.new(@callbacks[index], @record, [proceed, *@args]).invoke
        proceed.called? && !double_call_raised? ? @last_result : callback_result
      end
    end
  end
end
