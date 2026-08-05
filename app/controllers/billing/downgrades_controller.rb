module Billing
  # Downgrade sub-resource. Two shapes share this controller: a VOLUNTARY
  # downgrade from Pro, and resolving an INVOLUNTARY choose-N lock (where the
  # account already dropped to Free but nothing was suspended yet, so #create only
  # picks which N stay active — no Stripe). The plan flip itself lands via the
  # verified webhook.
  class DowngradesController < BaseController
    def new
      load_downgrade
    end

    def create
      # Capture the shape of the account BEFORE committing — a successful resolve
      # clears the lock, and the cancel/suspends change every other answer too.
      choosing = current_user.must_choose_downgrade?
      suspending = current_user.over_free_cap_by.positive?
      leaving_pro = leaving_pro?
      result =
        if choosing
          current_user.resolve_downgrade_choice!(keep_ids: params[:keep_ids])
        else
          current_user.downgrade_to_free!(keep_ids: params[:keep_ids])
        end

      if result.ok?
        redirect_to billing_subscription_path, status: :see_other,
          notice: success_notice(choosing: choosing, suspending: suspending, leaving_pro: leaving_pro)
      else
        render_new(status: :unprocessable_entity,
          alert: "Choose exactly #{Stablemate::FREE_PLAN_MONITOR_LIMIT} monitors to keep active.")
      end
    rescue ::Stripe::StripeError, Pay::Error => e
      # cancel_now! wraps Stripe failures in Pay::Error; a real cancel failure would
      # otherwise escape as a 500. Stripe is cancelled before any monitor is
      # suspended, so a failure here leaves nothing half-done.
      Rails.logger.error("[billing] downgrade failed (user=#{current_user.id}): #{e.class}: #{e.message}")
      render_new(status: :service_unavailable, alert: "Couldn't complete the downgrade. Please try again.")
    end

    private
      def load_downgrade
        @keep_limit = Stablemate::FREE_PLAN_MONITOR_LIMIT
        @mode = downgrade_mode
        @leaving_pro = leaving_pro?
        @monitors = picker_monitors if @mode == :choose
      end

      # Is there actually a Pro to leave? The involuntary path arrives here with the
      # plan already on Free and the subscription already cancelled, so copy
      # promising to cancel one is a lie.
      def leaving_pro?
        current_user.billed_for_pro?
      end

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
        # Preload :project — the picker groups by it, so without this the group_by
        # would fire one SELECT per monitor.
        scope.includes(:project).order(:created_at).to_a
      end

      # Say only what actually happened: an account already on Free had no
      # subscription to cancel, and a within-cap downgrade suspended nothing.
      def success_notice(choosing:, suspending:, leaving_pro:)
        return "Monitors updated — the rest stay suspended." if choosing

        [
          leaving_pro ? "Downgrade scheduled." : "You're on the Free plan.",
          ("Unselected monitors were suspended." if suspending)
        ].compact.join(" ")
      end

      def render_new(status:, alert:)
        load_downgrade
        flash.now[:alert] = alert
        render :new, status: status
      end
  end
end
