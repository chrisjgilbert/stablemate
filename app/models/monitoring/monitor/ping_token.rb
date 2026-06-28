module Monitoring
  class Monitor
    # The ping_token is the credential for the public ping endpoint: random,
    # unguessable, unique, and treated as a secret. Generated on create; can be
    # rotated to invalidate the old ping URL.
    module PingToken
      extend ActiveSupport::Concern

      # 32 url-safe alphanumeric chars (~190 bits) — unguessable, no encoding worries.
      TOKEN_LENGTH = 32

      included do
        before_validation :ensure_ping_token, on: :create
        validates :ping_token, presence: true, uniqueness: true
      end

      # Replace the token with a fresh unique value (invalidates the old URL).
      def rotate_ping_token!
        update!(ping_token: self.class.generate_ping_token)
      end

      class_methods do
        def generate_ping_token
          SecureRandom.alphanumeric(TOKEN_LENGTH)
        end
      end

      private
        def ensure_ping_token
          self.ping_token = self.class.generate_ping_token if ping_token.blank?
        end
    end
  end
end
