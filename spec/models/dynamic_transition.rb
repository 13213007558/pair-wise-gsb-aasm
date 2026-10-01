# frozen_string_literal: true

class DynamicTransition
  include AASM

  attr_reader :resolution_count, :reviewer, :escalated

  def initialize
    @resolution_count = 0
  end

  aasm do
    state :pending, initial: true
    state :approved
    state :manual_review
    state :rejected

    event :review do
      transitions from: :pending,
                  to: [:approved, :manual_review],
                  resolver: :resolve_review
    end

    event :review_with_lambda do
      transitions from: :pending,
                  to: [:approved, :manual_review],
                  resolver: ->(reviewer, escalate: false) { resolve_review(reviewer, escalate: escalate) }
    end

    event :attempt_blocked_review do
      transitions from: :pending,
                  to: [:approved, :manual_review],
                  guard: :block_review?,
                  resolver: :resolve_review
    end

    event :review_to_unknown_target do
      transitions from: :pending,
                  to: [:approved, :manual_review],
                  resolver: :resolve_unknown_target
    end
  end

  def resolve_review(reviewer = nil, escalate: false)
    @resolution_count += 1
    @reviewer = reviewer
    @escalated = escalate
    escalate ? :manual_review : :approved
  end

  def resolve_unknown_target
    :unknown
  end

  def block_review?
    false
  end
end

class NamedDynamicTransition
  include AASM

  attr_reader :resolution_count, :reviewer, :escalated

  def initialize
    @resolution_count = 0
  end

  aasm(:workflow) do
    state :pending, initial: true
    state :approved
    state :manual_review

    event :review do
      transitions from: :pending,
                    to: [:approved, :manual_review],
                    resolver: :resolve_review
    end
  end

  def resolve_review(reviewer, escalate: false)
    @resolution_count += 1
    @reviewer = reviewer
    @escalated = escalate
    escalate ? :manual_review : :approved
  end
end
