# frozen_string_literal: true

module AASM
  module Analysis
    # Read-only finite-state reachability analyzer.
    #
    # Explores the product of the participating state machines and the finite
    # abstract variables from the declared initial states. Transition guards
    # are interpreted solely through the finite, side-effect free conditions
    # declared in an {Abstraction}.
    #
    # A shortest witness event sequence is returned for every certain
    # violation. When the abstract model cannot fully cover the concrete
    # definition (an unabstracted reachable guard, a dynamic initial state, an
    # auto-firing +binding_event+ or a combination budget overflow) the result
    # is +:incomplete+ and safety is never reported.
    class Analyzer
      DEFAULT_BUDGET = 10_000

      attr_reader :model, :abstraction

      def initialize(model, abstraction)
        @model = model
        @abstraction = abstraction
      end

      def analyze
        blockers = model.blockers.map { |data| blocker(:unmodeled_callback, *data) }

        if model.initial_states.values.any?(&:nil?)
          return incomplete(blockers, 0)
        end
        return incomplete(blockers, 0) if abstraction.invariants.empty?

        budget = abstraction.budget
        roots = root_combinations
        queue = roots.map { |states, variables| make_node(states, variables, [], states, variables) }
        visited = {}
        unknown_tokens_seen = {}
        combinations = 0
        budget_exceeded = false

        # Flat BFS: nodes are enqueued grouped by depth implicitly, so the
        # first certain violation discovered is reached by a shortest event
        # sequence.
        until queue.empty?
          node = queue.shift
          key = combo_key(node[:states], node[:variables])
          next if visited.key?(key)
          visited[key] = true
          combinations += 1

          if combinations > budget
            budget_exceeded = true
            next
          end

          invariant = violated_invariant(node[:states], node[:variables])
          if invariant
            return violation_result(invariant, node, combinations) if node[:path].all? { |step| step[:certain] }

            # Reached only through an unabstracted guard; the reachable unknown
            # token is already recorded, so this cannot be reported as safe.
            next
          end

          each_successor(node) do |successor, unknown_tokens|
            unknown_tokens.each do |token|
              unknown_tokens_seen[token] = true
            end
            queue << successor unless visited.key?(combo_key(successor[:states], successor[:variables]))
          end
        end

        blockers << blocker(:budget_exceeded, budget) if budget_exceeded
        unknown_tokens_seen.each_key do |token|
          blockers << blocker(:unabstracted_guard, token)
        end
        blockers.empty? ? safe_result(combinations) : incomplete(blockers.uniq, combinations)
      end

      # Re-evaluate a recorded witness purely in the abstract model. Used by
      # {Result#replay!} to guarantee the returned event sequence really lands
      # on a combination that breaks an invariant, without instantiating the
      # analyzed class or executing Ruby callbacks.
      def replay_path(path, expected_invariant_name = nil, states = nil, variables = nil)
        states = (states || model.initial_states).dup
        variables = (variables || (path.first && path.first[:root_variables]) || {}).dup

        path.each do |step|
          context = Context.new(states, variables)
          machine = step[:machine]
          event_name = step[:event]
          source = states.fetch(machine)

          _found, transitions = model.candidates_for(machine, source)
                                     .find { |name, _| name == event_name }
          raise ReplayMismatch, "event #{event_name.inspect} unavailable from #{source.inspect}" unless transitions

          candidates = transitions.map(&:transition)
          winner_index = candidates.index do |transition|
            next false unless Array(transition.to).map(&:to_sym).include?(step[:to_state])

            model.evaluate_transition(transition, context, abstraction) == :enabled
          end
          raise ReplayMismatch, "no enabled transition #{event_name.inspect} -> #{step[:to_state].inspect} at #{states.inspect}" unless winner_index

          if winner_index != first_enabled_index(candidates, context)
            raise ReplayMismatch, "earlier transition would fire for #{event_name.inspect} at #{states.inspect}"
          end

          states[machine] = step[:to_state]
          expected_variables = post_assignments(variables, abstraction.effect_for(machine, event_name), context)
          unless expected_variables.any? { |assignment| assignment == step[:variables] }
            raise ReplayMismatch,
                  "variable assignment after #{event_name.inspect} is not reproducible: #{step[:variables].inspect}"
          end
          variables.replace(step[:variables])
        end

        final = violated_invariant(states, variables)
        raise ReplayMismatch, 'replayed event sequence does not violate an invariant' unless final
        if expected_invariant_name && final.name != expected_invariant_name
          raise ReplayMismatch, "expected violation of #{expected_invariant_name.inspect}, got #{final.name.inspect}"
        end

        { states: states, variables: variables, invariant: final.name }
      end

      private

      def root_combinations
        domains = abstraction.variables.transform_values do |variable|
          variable.initial.nil? ? variable.values : [variable.initial]
        end
        cartesian_product(domains).map { |variables| [model.initial_states.dup, variables] }
      end

      def cartesian_product(domains)
        return [{}] if domains.empty?

        names = domains.keys
        head, *rest = domains.values
        head.product(*rest).map { |values| names.zip(values).to_h }
      end

      def each_successor(node)
        states = node[:states]
        variables = node[:variables]

        model.machines.each do |machine|
          source = states.fetch(machine)
          model.candidates_for(machine, source).each do |event_name, candidates|
            context = Context.new(states, variables)
            outcomes = resolve_event(candidates.map(&:transition), context)
            effect_block = abstraction.effect_for(machine, event_name)

            outcomes.each do |outcome|
              post_assignments(variables, effect_block, context).each do |post_variables|
                Array(outcome[:to]).map(&:to_sym).each do |target|
                  next unless model.states.fetch(machine).include?(target)

                  next_states = states.merge(machine => target)
                  step = {
                    machine: machine,
                    event: event_name,
                    from_state: source,
                    to_state: target,
                    states: next_states,
                    variables: post_variables,
                    root_variables: node[:root_variables],
                    certain: outcome[:unknown].empty?
                  }
                  successor = make_node(next_states, post_variables, node[:path] + [step],
                                        node[:root_states], node[:root_variables])
                  yield successor, outcome[:unknown]
                end
              end
            end
          end
        end
      end

      # Resolve one event at one source state with AASM's ordered,
      # first-match-wins semantics. Guards without a condition are explored in
      # both directions (a sound over-approximation); each outcome records the
      # tokens it depended on so paths through them cannot prove safety.
      #
      # A candidate can only win when every earlier candidate does not fire.
      # A definitely-enabled earlier candidate also hides every later
      # candidate, so enumeration stops at that point.
      def resolve_event(transitions, context)
        results = []

        transitions.each do |transition|
          verdict = model.evaluate_transition(transition, context, abstraction)
          earlier = transitions.take_while { |candidate| !candidate.equal?(transition) }
          earlier_verdicts = earlier.map do |candidate|
            model.evaluate_transition(candidate, context, abstraction)
          end

          case verdict
          when :enabled
            # No earlier candidate may fire. A definitely-enabled earlier
            # candidate means this (and all later) candidate is unreachable.
            next if earlier_verdicts.any?(:enabled)

            unknown = earlier_verdicts.flat_map do |earlier_verdict|
              earlier_verdict == :disabled ? [] : earlier_verdict.last
            end
            results << { to: transition.to, unknown: unknown.uniq }

            # This candidate definitely fires when all earlier ones are known
            # disabled; then nothing later can win. When earlier candidates are
            # unknown, they *might* fire, but if they do not this candidate is
            # the winner anyway — later candidates are still hidden.
            break
          when :disabled
            next
          else
            _, unknown_tokens = verdict

            # For this unknown candidate to fire every earlier candidate must
            # not fire. An enabled earlier candidate wins outright; a disabled
            # earlier one is guaranteed not to; an unknown earlier one must be
            # assumed false, adding uncertainty.
            next if earlier_verdicts.any?(:enabled)

            unknown = unknown_tokens + earlier_verdicts.flat_map do |earlier_verdict|
              earlier_verdict == :disabled ? [] : earlier_verdict.last
            end
            results << { to: transition.to, unknown: unknown.uniq }
            # Do not stop: if this unknown candidate does not fire, a later
            # candidate still might.
          end
        end

        results
      end

      def first_enabled_index(transitions, context)
        transitions.index { |transition| model.evaluate_transition(transition, context, abstraction) == :enabled }
      end

      def post_assignments(variables, effect_block, pre_context)
        explicit = {}
        if effect_block
          returned = effect_block.call(pre_context) || {}
          unless returned.is_a?(Hash)
            raise ArgumentError, 'an event effect must return a Hash of variable assignments'
          end
          returned.each_key do |name|
            unless abstraction.variables.key?(name.to_sym)
              raise UnknownVariable, "event effect assigns unknown variable :#{name}"
            end
          end
          explicit = returned.transform_keys(&:to_sym)
        end
        [variables.merge(explicit)]
      end

      def violated_invariant(states, variables)
        context = Context.new(states, variables)
        abstraction.invariants.find { |invariant| !invariant.block.call(context) }
      end

      def combo_key(states, variables)
        [states, variables]
      end

      def make_node(states, variables, path, root_states, root_variables)
        { states: states, variables: variables, path: path,
          root_states: root_states, root_variables: root_variables }
      end

      def blocker(reason, *details)
        { reason: reason, details: details }
      end

      def violation_result(invariant, node, combinations)
        path = node[:path].each_with_index.map do |step, index|
          clean = step.except(:root_variables)
          clean[:root_variables] = node[:root_variables] if index.zero?
          clean
        end
        Result.new(
          :violation,
          model: model,
          abstraction: abstraction,
          violated_invariant: invariant,
          path: path,
          combinations_explored: combinations,
          root_states: node[:root_states],
          root_variables: node[:root_variables]
        )
      end

      def safe_result(combinations)
        Result.new(:safe, model: model, abstraction: abstraction, combinations_explored: combinations)
      end

      def incomplete(blockers, combinations)
        Result.new(:incomplete, model: model, abstraction: abstraction,
                   blockers: blockers.uniq, combinations_explored: combinations)
      end
    end
  end
end
