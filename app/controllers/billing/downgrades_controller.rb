module Billing
  # Downgrade sub-resource. Two shapes share this controller:
  #   * a VOLUNTARY downgrade from Pro — over the Free cap it's the "choose which N
  #     to keep" picker (PRD §5.6), at/under the cap it's a plain confirm (WU-5);
  #   * resolving an INVOLUNTARY choose-N lock (WU-6) — the account already dropped
  #     to Free and its over-cap monitors were auto-suspended, so #create only
  #     re-picks which N stay active (no Stripe).
  # #new renders the picker or the confirm; #create commits. The plan flip itself
  # lands via the verified webhook (the only writer of plan).
  class DowngradesController < BaseController
    def new
      @keep_limit = Stablemate::FREE_PLAN_MONITOR_LIMIT
      @mode = downgrade_mode
      @monitors = picker_monitors if @mode == :choose
    end

    def create
      # Capture the mode BEFORE committing — a successful resolve clears the lock.
      choosing = current_user.must_choose_downgrade?
      result =
        if choosing
          current_user.resolve_downgrade_choice!(keep_ids: params[:keep_ids])
        else
          current_user.downgrade_to_free!(keep_ids: params[:keep_ids])
        end

      if result.ok?
        redirect_to billing_subscription_path, notice: success_notice(choosing), status: :see_other
      else
        render_new(status: :unprocessable_entity,
          alert: "Choose exactly #{Stablemate::FREE_PLAN_MONITOR_LIMIT} monitors to keep active.")
      end
    rescue ::Stripe::StripeError, Pay::Error => e
      # cancel_now! wraps Stripe failures in Pay::Error; a real cancel failure would
      # otherwise escape as a 500. Stripe is cancelled before any monitor is
      # suspended (User::Downgrade#to_free!), so a failure here leaves nothing
      # half-done. (The choose-N resolve path makes no Stripe call.) Log it so the
      # swallowed failure isn't invisible to us.
      Rails.logger.error("[billing] downgrade failed (user=#{current_user.id}): #{e.class}: #{e.message}")
      render_new(status: :service_unavailable, alert: "Couldn't complete the downgrade. Please try again.")
    end

    private
      # Choose-N when the account owes an involuntary decision, or a voluntary
      # downgrade while still over the Free cap; otherwise a plain confirm (WU-5).
      def downgrade_mode
        return :choose if current_user.must_choose_downgrade?
        return :choose if current_user.over_free_cap_by.positive?

        :confirm
      end

      # In the involuntary lock, list ALL monitors (incl. the auto-suspended ones)
      # so the user can re-pick which N to keep; a voluntary over-cap downgrade only
      # chooses among the currently-active ones.
      def picker_monitors
        scope = current_user.must_choose_downgrade? ? current_user.monitors : current_user.monitors.counting_toward_cap
        scope.order(:created_at).to_a
      end

      def success_notice(choosing)
        if choosing
          "Monitors updated — the rest stay suspended."
        else
          "Downgrade scheduled. Unselected monitors were suspended."
        end
      end

      def render_new(status:, alert:)
        @keep_limit = Stablemate::FREE_PLAN_MONITOR_LIMIT
        @mode = downgrade_mode
        @monitors = picker_monitors if @mode == :choose
        flash.now[:alert] = alert
        render :new, status: status
      end
  end
end
