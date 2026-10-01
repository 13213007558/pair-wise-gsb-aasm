# frozen_string_literal: true

require 'digest'

module AASM
  class EventReceipt
    STATUSES = [
      :not_accepted,
      :in_progress,
      :committed,
      :post_commit_callback_failed,
    ].freeze

    TERMINAL_STATUSES = [
      :not_accepted,
      :committed,
      :post_commit_callback_failed,
    ].freeze

    attr_accessor :event_id, :object_key, :state_machine_name, :event_name,
                  :arguments_fingerprint, :status, :result, :error,
                  :from_state, :to_state, :attempts, :created_at,
                  :updated_at, :started_at, :committed_at, :finished_at,
                  :thread, :post_commit_started

    def initialize(attributes = {})
      @attempts = 0
      @created_at = Time.now
      @updated_at = @created_at
      attributes.each do |name, value|
        public_send("#{name}=", value)
      end
    end

    def key
      [object_key, state_machine_name, event_id]
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    def not_accepted?
      status == :not_accepted
    end

    def in_progress?
      status == :in_progress
    end

    def committed?
      status == :committed
    end

    def post_commit_callback_failed?
      status == :post_commit_callback_failed
    end

    def committed_or_callback_failed?
      committed? || post_commit_callback_failed?
    end

    def touch
      self.updated_at = Time.now
      self
    end

    def begin_post_commit
      self.post_commit_started = true
      self.committed_at ||= Time.now
    end

    def self.argument_fingerprint(event_name, positional_arguments, keyword_arguments, block = nil)
      payload = [
        event_name.to_s,
        stable_value(positional_arguments),
        stable_value(keyword_arguments),
        block && [block.object_id, block.source_location],
      ]
      Digest::SHA256.hexdigest(Marshal.dump(payload))
    end

    def self.stable_value(value)
      case value
      when Hash
        value.map { |key, entry| [stable_value(key), stable_value(entry)] }.sort_by(&:first)
      when Array
        value.map { |entry| stable_value(entry) }
      when Symbol, String, Integer, Float, NilClass, TrueClass, FalseClass
        [value.class.name, value]
      else
        [value.class.name, value.inspect]
      end
    end
  end
end
