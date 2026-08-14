module Projects
  # Per-project API-key management: the credential that registers monitors and
  # calls the management API. Issuance shows the raw sm_live_… token once.
  class ApiKeysController < ApplicationController
    include ProjectCredentialIssuance

    private
      def credential_class = ApiKey
      def credential_label = "API key"
  end
end
