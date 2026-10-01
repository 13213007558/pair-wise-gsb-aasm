# frozen_string_literal: true

module AASM::Core
  # Invokes an around_transition callback, handing it a controlled +proceed+
  # callable as its first argument. Supported callback shapes:
  #
  #   * a Proc/lambda evaluated in the record context
  #   * a Symbol/String naming a record method
  #   * an object responding to #call (including a Class with a #call instance
  #     method, instantiated with the record)
  #
  # Callbacks must declare at least one parameter for +proceed+; not calling
  # +proceed+ cancels the transition.
  class AroundInvoker
    def initialize(subject, record, args, proceed)
      @subject = subject
      @record = record
      @args = args
      @proceed = proceed
    end

    def invoke
      case @subject
      when Proc
        invoke_with(parameters: @subject.parameters, strict: @subject.lambda?) do |call_args|
          @record.instance_exec(*call_args, &@subject)
        end
      when Symbol, String
        method = @record.method(@subject.to_sym)
        invoke_with(parameters: method.parameters) do |call_args|
          @record.__send__(@subject, *call_args)
        end
      else
        unless callable_object?
          raise ArgumentError,
            "unsupported around_transition callback #{@subject.inspect} on #{@record.class}"
        end
        callable = @subject.is_a?(Class) ? @subject.new(@record) : @subject
        invoke_with(parameters: callable.method(:call).parameters) do |call_args|
          callable.call(*call_args)
        end
      end
    end

    private

    def invoke_with(parameters:, strict: false)
      unless accepts_proceed?(parameters)
        raise ArgumentError, rejection_message
      end
      yield build_call_args(parameters, strict)
    end

    def accepts_proceed?(parameters)
      parameters.any? { |type, _| type == :req || type == :opt || type == :rest }
    end

    # +proceed+ is always passed first, followed by the event's positional
    # arguments sliced to what the callback declares.
    def build_call_args(parameters, strict)
      rest = parameters.any? { |type, _| type == :rest }
      extras = if rest
                 @args.dup
               else
                 slots = parameters.count { |type, _| type == :req || type == :opt } - 1
                 @args.first([slots, 0].max)
               end
      call_args = [@proceed] + extras
      if strict && !rest
        slots = parameters.count { |type, _| type == :req || type == :opt }
        call_args.first(slots)
      else
        call_args
      end
    end

    def rejection_message
      case @subject
      when Symbol, String
        "around_transition callback '##{@subject}' on #{@record.class} must " \
        "accept a proceed argument so the transition can be executed"
      else
        "around_transition callback #{@subject.inspect} must accept a proceed " \
        "argument so the transition can be executed"
      end
    end

    def callable_object?
      (@subject.respond_to?(:call) && !@subject.is_a?(Proc)) ||
        (@subject.is_a?(Class) && @subject.instance_methods.include?(:call))
    end
  end
end
