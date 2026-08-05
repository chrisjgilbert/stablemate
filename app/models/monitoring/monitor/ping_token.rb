module Monitoring
  class Monitor
    # The ping_token is the credential for the public ping endpoint, and is
    # treated as a secret.
    module PingToken
      extend ActiveSupport::Concern

      # 32 url-safe alphanumeric chars (~190 bits).
      TOKEN_LENGTH = 32

      included do
        before_validation :ensure_ping_token, on: :create
        validates :ping_token, presence: true, uniqueness: true
      end

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
