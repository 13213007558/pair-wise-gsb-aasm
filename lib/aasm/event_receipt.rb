# frozen_string_literal: true

require 'digest'
require 'thread'

module AASM
  module EventReceipt
    STATUSES = [:not_accepted, :executing, :committed, :post_commit_callback_failed].freeze

    class Conflict < ArgumentError
      attr_reader :existing_receipt

      def initialize(existing_receipt)
        @existing_receipt = existing_receipt
        super("Event receipt #{existing_receipt.event_id.inspect} is already bound to a different event input")
      end
    end

    class Request
      attr_reader :event_id, :event_name, :state_machine_name, :persist, :arguments, :keyword_arguments, :block_source, :fingerprint

      def initialize(event_id:, event_name:, state_machine_name:, persist:, arguments:, keyword_arguments:, block_source: nil)
        @event_id = event_id
        @event_name = event_name.to_sym
        @state_machine_name = state_machine_name.to_sym
        @persist = persist
        @arguments = arguments
        @keyword_arguments = keyword_arguments
        @block_source = block_source
        @fingerprint = Digest::SHA256.hexdigest(payload.inspect)
      end

      def payload
        [state_machine_name, event_name, persist, normalized_value(arguments), normalized_value(keyword_arguments), block_source]
      end

      private

      def normalized_value(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).map do |key|
            [key.class.name, key.to_s, normalized_value(value[key])]
          end
        when Array
          ['array', value.map { |item| normalized_value(item) }]
        else
          [value.class.name, value.inspect]
        end
      end
    end

    class Receipt
      attr_reader :event_id, :event_name, :state_machine_name, :fingerprint, :status, :result, :error, :existing_receipt

      def initialize(request, status: :executing, result: nil, error: nil, existing_receipt: nil)
        @event_id = request.event_id
        @event_name = request.event_name
        @state_machine_name = request.state_machine_name
        @fingerprint = request.fingerprint
        @status = status
        @result = result
        @error = error
        @existing_receipt = existing_receipt
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      def accepted?
        status != :not_accepted
      end

      def not_accepted?
        status == :not_accepted
      end

      def conflict?
        error.is_a?(Conflict)
      end

      def executing?
        status == :executing
      end

      def committed?
        status == :committed
      end

      def post_commit_callback_failed?
        status == :post_commit_callback_failed
      end

      def terminal?
        committed? || post_commit_callback_failed? || (status == :not_accepted && !conflict?)
      end

      def wait(timeout = nil)
        deadline = timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil

        @mutex.synchronize do
          while executing?
            remaining = deadline ? deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil
            break if remaining && remaining <= 0
            @condition.wait(@mutex, remaining)
          end
        end

        self
      end

      def mark_rejected(result = false, error = nil)
        complete(:not_accepted, result, error)
      end

      def mark_committed(result)
        complete(:committed, result) if executing?
      end

      def mark_post_commit_callback_failed(result, error)
        complete(:post_commit_callback_failed, result, error)
      end

      private

      def complete(status, result, error = nil)
        @mutex.synchronize do
          return self if @status == :post_commit_callback_failed && status == :committed
          @status = status
          @result = result
          @error = error
          @condition.broadcast
        end
        self
      end
    end

    module Store
      def admit(_key, _request)
        raise NotImplementedError, "##{__method__} must be implemented by an event receipt store"
      end

      def reject(_receipt, _result = false, _error = nil)
        raise NotImplementedError, "##{__method__} must be implemented by an event receipt store"
      end

      def commit(_receipt, _result)
        raise NotImplementedError, "##{__method__} must be implemented by an event receipt store"
      end

      def mark_post_commit_callback_failed(_receipt, _result, _error)
        raise NotImplementedError, "##{__method__} must be implemented by an event receipt store"
      end

      def abort(_receipt)
        raise NotImplementedError, "##{__method__} must be implemented by an event receipt store"
      end

      def fetch(_key)
        raise NotImplementedError, "##{__method__} must be implemented by an event receipt store"
      end

      def wait(receipt, timeout = nil)
        receipt.wait(timeout)
      end
    end

    class MemoryStore
      include Store

      def initialize
        @receipts = {}
        @waiters = Hash.new(0)
        @mutex = Mutex.new
      end

      def admit(key, request)
        @mutex.synchronize do
          existing = @receipts[key]

          if existing
            if existing.fingerprint != request.fingerprint
              conflict = Conflict.new(existing)
              receipt = Receipt.new(request, status: :not_accepted, error: conflict, existing_receipt: existing)
              return [:conflict, receipt]
            end

            return [:duplicate, existing]
          end

          receipt = Receipt.new(request)
          @receipts[key] = receipt
          [:accepted, receipt]
        end
      end

      def reject(receipt, result = false, error = nil)
        receipt.mark_rejected(result, error) if receipt.executing?
      end

      def commit(receipt, result)
        receipt.mark_committed(result) if receipt.executing?
      end

      def mark_post_commit_callback_failed(receipt, result, error)
        receipt.mark_post_commit_callback_failed(result, error)
      end

      def abort(receipt)
        @mutex.synchronize do
          @receipts.delete_if do |_key, existing|
            existing.equal?(receipt) && existing.executing?
          end
        end
      end

      def fetch(key)
        @mutex.synchronize { @receipts[key] }
      end

      def wait(receipt, timeout = nil)
        @mutex.synchronize { @waiters[receipt.object_id] += 1 }
        receipt.wait(timeout)
      ensure
        @mutex.synchronize do
          @waiters[receipt.object_id] -= 1
          @waiters.delete(receipt.object_id) if @waiters[receipt.object_id].zero?
        end
      end

      def waiting?(receipt)
        @mutex.synchronize { @waiters.key?(receipt.object_id) }
      end
    end
  end
end
