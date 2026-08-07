module Projects
  # Per-project ping-key management: the credential the gem puts on every
  # check-in. Issuance shows the raw sm_ping_… token exactly once, and a project
  # may hold several live keys at a time so rotation can overlap.
  class PingKeysController < ApplicationController
    include ProjectCredentialIssuance

    private
      def credential_class = PingKey
      def credential_label = "Ping key"
  end
end
