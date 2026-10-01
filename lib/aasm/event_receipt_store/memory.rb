# frozen_string_literal: true

require 'thread'

module AASM
  module EventReceiptStore
    class Memory < Abstract
      def initialize
        @receipts = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      def claim(request)
        key = receipt_key(request)
        fingerprint = request.fetch(:arguments_fingerprint)

        @mutex.synchronize do
          receipt = @receipts[key]

          if receipt
            ensure_matching_fingerprint!(receipt, fingerprint)
            if receipt.in_progress? && receipt.thread == Thread.current
              raise AASM::EventReceiptReentry,
                    "Event receipt #{request.fetch(:event_id).inspect} is already executing on this thread"
            end

            receipt.attempts += 1
            receipt.touch
            wait_while_in_progress(receipt) if receipt.in_progress?
            return receipt
          end

          receipt = AASM::EventReceipt.new(
            request.merge(
              status: :in_progress,
              attempts: 1,
              started_at: Time.now,
              thread: Thread.current
            )
          )
          @receipts[key] = receipt
          receipt
        end
      end

      def mark(receipt, status, attributes = {})
        raise ArgumentError, "Unknown event receipt status: #{status.inspect}" unless AASM::EventReceipt::STATUSES.include?(status)

        @mutex.synchronize do
          attributes.each { |name, value| receipt.public_send("#{name}=", value) }
          receipt.status = status
          receipt.finished_at = Time.now if receipt.terminal?
          receipt.committed_at = receipt.finished_at if receipt.committed_or_callback_failed?
          receipt.thread = nil if receipt.terminal?
          receipt.touch
          @condition.broadcast
          receipt
        end
      end

      def find(object_key:, state_machine_name:, event_id:)
        @mutex.synchronize do
          @receipts[[object_key, state_machine_name.to_sym, event_id]]
        end
      end

      def delete(object_key:, state_machine_name:, event_id:)
        @mutex.synchronize do
          @receipts.delete([object_key, state_machine_name.to_sym, event_id])
        end
      end

      def clear
        @mutex.synchronize { @receipts.clear }
      end

      private

      def receipt_key(request)
        [
          request.fetch(:object_key),
          request.fetch(:state_machine_name).to_sym,
          request.fetch(:event_id),
        ]
      end

      def ensure_matching_fingerprint!(receipt, fingerprint)
        return if receipt.arguments_fingerprint == fingerprint

        raise AASM::EventReceiptConflict,
              "Event receipt #{receipt.event_id.inspect} was already used for #{receipt.event_name.inspect} with different arguments"
      end

      def wait_while_in_progress(receipt)
        @condition.wait(@mutex) while receipt.in_progress?
      end
    end
  end
end
