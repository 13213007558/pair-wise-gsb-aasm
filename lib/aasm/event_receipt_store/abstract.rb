# frozen_string_literal: true

module AASM
  module EventReceiptStore
    class Abstract
      def claim(request)
        raise NotImplementedError, "#{self.class} must implement #claim"
      end

      def mark(receipt, status, attributes = {})
        raise NotImplementedError, "#{self.class} must implement #mark"
      end

      def find(object_key:, state_machine_name:, event_id:)
        raise NotImplementedError, "#{self.class} must implement #find"
      end
    end
  end
end
