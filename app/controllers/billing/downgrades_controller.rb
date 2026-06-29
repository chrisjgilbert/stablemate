module Billing
  # The gated "choose your 5" downgrade (PRD §5.6). Downgrading *is* creating a
  # downgrade — no custom verb. #new renders the picker (which monitors to keep
  # active); #create commits the choice: suspend the rest, cancel Stripe. The plan
  # flip itself lands via the verified webhook (the only writer of plan).
  class DowngradesController < BaseController
    def new
      @monitors = current_user.monitors.counting_toward_cap.order(:created_at).to_a
      @keep_limit = Stablemate::FREE_PLAN_MONITOR_LIMIT
    end

    def create
      result = current_user.downgrade_to_free!(keep_ids: params[:keep_ids])

      if result.ok?
        redirect_to billing_subscription_path,
          notice: "Downgrade scheduled. Unselected monitors were suspended.", status: :see_other
      else
        render_picker(status: :unprocessable_entity, alert: "Choose exactly #{Stablemate::FREE_PLAN_MONITOR_LIMIT} monitors to keep active.")
      end
    rescue ::Stripe::StripeError
      # Stripe is cancelled before any monitor is suspended (User::Downgrade#to_free!),
      # so a failure here leaves nothing half-done. Surface a generic retry message.
      render_picker(status: :service_unavailable, alert: "Couldn't complete the downgrade. Please try again.")
    end

    private
      def render_picker(status:, alert:)
        @monitors = current_user.monitors.counting_toward_cap.order(:created_at).to_a
        @keep_limit = Stablemate::FREE_PLAN_MONITOR_LIMIT
        flash.now[:alert] = alert
        render :new, status: status
      end
  end
end
