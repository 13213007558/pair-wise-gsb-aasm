# frozen_string_literal: true

module AASM::Core
  class Transition
    include AASM::DslHelper

    attr_reader :from, :to, :event, :opts, :failures, :resolver
    alias_method :options, :opts

    def initialize(event, opts, &block)
      add_options_from_dsl(opts, [:on_transition, :guard, :after, :success], &block) if block

      @event = event
      @from = opts[:from]
      @to = opts[:to]
      @allowed_to = Array(@to).dup.freeze
      @resolver = opts[:resolver]
      @guards = Array(opts[:guards]) + Array(opts[:guard]) + Array(opts[:if])
      @unless = Array(opts[:unless]) #TODO: This could use a better name
      @failures = []

      if opts[:on_transition]
        warn '[DEPRECATION] :on_transition is deprecated, use :after instead'
        opts[:after] = Array(opts[:after]) + Array(opts[:on_transition])
      end
      @after = Array(opts[:after])
      @after = @after[0] if @after.size == 1

      @success = Array(opts[:success])
      @success = @success[0] if @success.size == 1

      @opts = opts
    end

    # called internally by Ruby 1.9 after clone()
    def initialize_copy(orig)
      super
      @guards = @guards.dup
      @unless = @unless.dup
      @allowed_to = @allowed_to.dup
      @opts   = {}
      orig.opts.each_pair { |name, setting| @opts[name] = setting.is_a?(Hash) || setting.is_a?(Array) ? setting.dup : setting }
    end

    def allowed?(obj, *args)
      invoke_callbacks_compatible_with_guard(@guards, obj, args, :guard => true) &&
      invoke_callbacks_compatible_with_guard(@unless, obj, args, :unless => true)
    end

    def execute(obj, *args)
      invoke_callbacks_compatible_with_guard(event.state_machine.global_callbacks[:after_all_transitions], obj, args)
      invoke_callbacks_compatible_with_guard(@after, obj, args)
    end

    def execute_with_target(obj, target, *args)
      set_transition_context(obj, target)
      invoke_callbacks_compatible_with_guard(event.state_machine.global_callbacks[:after_all_transitions], obj, args, :set_to_state => false)
      invoke_callbacks_compatible_with_guard(@after, obj, args, :set_to_state => false)
    end

    def ==(obj)
      @from == obj.from && @to == obj.to
    end

    def from?(value)
      @from == value
    end

    def invoke_success_callbacks(obj, *args)
      _fire_callbacks(@success, obj, args)
    end

    def allowed_targets
      @allowed_to
    end

    def dynamic_target?
      !@resolver.nil?
    end

    def resolve_target(obj, requested_target, *args)
      return requested_target.to_sym if requested_target
      return allowed_targets.first unless dynamic_target?

      target = Invoker.new(@resolver, obj, args)
                    .with_default_return_value(nil)
                    .invoke
      target = target.to_sym if target.respond_to?(:to_sym)

      unless target.is_a?(Symbol) && allowed_targets.include?(target)
        raise AASM::InvalidTransitionTarget,
              "Resolved target #{target.inspect} is not allowed for event :#{event.name}. Allowed targets: #{allowed_targets.map(&:inspect).join(', ')}"
      end

      target
    end

    private

    def invoke_callbacks_compatible_with_guard(code, record, args, options={})
      if record.respond_to?(:aasm)
        record.aasm(event.state_machine.name).from_state = @from if record.aasm(event.state_machine.name).respond_to?(:from_state=)
        record.aasm(event.state_machine.name).to_state = @to if options.fetch(:set_to_state, true) && record.aasm(event.state_machine.name).respond_to?(:to_state=)
      end

      Invoker.new(code, record, args)
             .with_options(options)
             .with_failures(failures)
             .invoke
    end

    def _fire_callbacks(code, record, args)
      Invoker.new(code, record, args).invoke
    end

    def set_transition_context(record, target)
      return unless record.respond_to?(:aasm)
      aasm = record.aasm(event.state_machine.name)
      aasm.from_state = @from if aasm.respond_to?(:from_state=)
      aasm.to_state = target if aasm.respond_to?(:to_state=)
    end

    ruby2_keywords :execute if respond_to?(:ruby2_keywords, true)
    ruby2_keywords :execute_with_target if respond_to?(:ruby2_keywords, true)

  end
end # AASM
