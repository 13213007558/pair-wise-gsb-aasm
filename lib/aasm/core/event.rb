# frozen_string_literal: true

module AASM::Core
  class Event
    include AASM::DslHelper

    Selection = Struct.new(:transition, :target, keyword_init: true)

    attr_reader :name, :state_machine, :options, :default_display_name

    def initialize(name, state_machine, options = {}, &block)
      @name = name
      @state_machine = state_machine
      @transitions = []
      @guards = Array(options[:guard] || options[:guards] || options[:if])
      @unless = Array(options[:unless]) #TODO: This could use a better name
      @default_display_name = name.to_s.gsub(/_/, ' ').capitalize

      # from aasm4
      @options = options # QUESTION: .dup ?
      add_options_from_dsl(@options, [
        :after,
        :after_commit,
        :after_transaction,
        :before,
        :before_transaction,
        :ensure,
        :error,
        :before_success,
        :success,
      ], &block) if block
    end

    # called internally by Ruby 1.9 after clone()
    def initialize_copy(orig)
      super
      @transitions = @transitions.collect { |transition| transition.clone }
      @guards      = @guards.dup
      @unless      = @unless.dup
      @options     = {}
      orig.options.each_pair { |name, setting| @options[name] = setting.is_a?(Hash) || setting.is_a?(Array) ? setting.dup : setting }
    end

    # a neutered version of fire - it doesn't actually fire the event, it just
    # executes the transition guards to determine if a transition is even
    # an option given current conditions.
    def may_fire?(obj, *args)
      select_transition(obj, *args)
    end

    def fire(obj, options={}, *args)
      selection = options[:selection] || select_transition(obj, *args)
      return nil unless selection

      callback_args = args.dup
      if callback_args.first.respond_to?(:to_sym) && callback_args.first.to_sym == selection.target
        callback_args.shift
      end
      selection.transition.execute_with_target(obj, selection.target, *callback_args)
      selection.target
    end

    def transitions_from_state?(state)
      transitions_from_state(state).any?
    end

    def transitions_from_state(state)
      @transitions.select { |t| t.from.nil? or t.from == state }
    end

    def transitions_to_state?(state)
      transitions_to_state(state).any?
    end

    def transitions_to_state(state)
      @transitions.select { |t| Array(t.to).include?(state) }
    end

    def fire_global_callbacks(callback_name, record, *args)
      invoke_callbacks(state_machine.global_callbacks[callback_name], record, args)
    end

    def fire_callbacks(callback_name, record, *args)
      # strip out the first element in args if it's a valid to_state
      # #given where we're coming from, this condition implies args not empty
      invoke_callbacks(@options[callback_name], record, args)
    end

    def fire_transition_callbacks(obj, selection, *args)
      selection&.transition&.invoke_success_callbacks(obj, *args)
    end

    def ==(event)
      if event.is_a? Symbol
        name == event
      else
        name == event.name
      end
    end

    ## DSL interface
    def transitions(definitions=nil, &block)
      if definitions # define new transitions
        # Create a separate transition for each from-state to the given state
        Array(definitions[:from]).each do |s|
          @transitions << AASM::Core::Transition.new(self, attach_event_guards(definitions.merge(:from => s.to_sym)), &block)
        end
        # Create a transition if :to is specified without :from (transitions from ANY state)
        if !definitions[:from] && (definitions[:to] || definitions[:resolver])
          @transitions << AASM::Core::Transition.new(self, attach_event_guards(definitions), &block)
        end
      end
      @transitions
    end

    def failed_callbacks
      transitions.flat_map(&:failures)
    end

    def to_s
      name.to_s
    end

  private

    def attach_event_guards(definitions)
      unless @guards.empty?
        given_guards = Array(definitions.delete(:guard) || definitions.delete(:guards) || definitions.delete(:if))
        definitions[:guards] = @guards + given_guards # from aasm4
      end
      unless @unless.empty?
        given_unless = Array(definitions.delete(:unless))
        definitions[:unless] = given_unless + @unless
      end
      definitions
    end

    def select_transition(obj, *args)
      clear_failed_callbacks
      transitions = @transitions.select { |t| t.from == obj.aasm(state_machine.name).current_state || t.from == nil}
      return nil if transitions.size == 0

      event_args = args.dup
      to_state = nil
      if event_args.first.respond_to?(:to_sym) && transitions.flat_map(&:allowed_targets).include?(event_args.first.to_sym)
        to_state = event_args.shift.to_sym
      end

      # nop, to_state is a valid to-state

      transitions.each do |transition|
        requested_target = to_state if to_state && transition.allowed_targets.include?(to_state)
        next if to_state && requested_target.nil?

        if transition.allowed?(obj, *event_args)
          target = transition.resolve_target(obj, requested_target, *event_args)
          set_transition_context(obj, transition.from, target)
          return Selection.new(transition: transition, target: target)
        end
      end
      nil
    end

    def set_transition_context(obj, from_state, to_state)
      aasm = obj.aasm(state_machine.name)
      aasm.from_state = from_state if aasm.respond_to?(:from_state=)
      aasm.to_state = to_state if aasm.respond_to?(:to_state=)
    end

    def clear_failed_callbacks
      # https://github.com/aasm/aasm/issues/383, https://github.com/aasm/aasm/issues/599
      transitions.each { |transition| transition.failures.clear }
    end

    def invoke_callbacks(code, record, args)
      Invoker.new(code, record, args)
             .with_default_return_value(false)
             .invoke
    end

    ruby2_keywords :may_fire?, :fire, :select_transition if respond_to?(:ruby2_keywords, true)
  end
end # AASM
