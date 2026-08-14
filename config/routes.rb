Rails.application.routes.draw do
  resource :session, only: %i[new create destroy]
  resources :passwords, param: :token, only: %i[new create edit update]

  get  "sign_in",  to: "sessions#new",        as: :sign_in
  get  "sign_up",  to: "registrations#new",   as: :sign_up
  post "sign_up",  to: "registrations#create"
  resources :registrations, only: %i[new create]

  get "verify/:token", to: "email_verifications#show", as: :email_verification

  # The nested password resource is NOT the `resources :passwords` flow above —
  # see Accounts::PasswordsController for the distinction.
  resource :account, only: %i[show destroy] do
    resource :password, only: :update, module: :accounts
  end

  # Keys are managed from a project's show page (a key is one app's identity), so
  # issuance/revoke are a nested sub-resource.
  resources :projects do
    resources :api_keys, only: %i[create destroy], module: :projects
    # The check-in credential. A separate resource because it is a separate
    # table — that is what makes a ping key authenticating the management API
    # impossible rather than discouraged.
    resources :ping_keys, only: %i[create destroy], module: :projects
  end

  # CRUD plus the sub-resource controllers that replace custom verbs.
  resources :monitors do
    resource :pause, only: %i[create destroy], module: :monitors
    resource :ping_token, only: :update, module: :monitors
    resource :project, only: :update, module: :monitors
  end

  get "up" => "rails/health#show", as: :rails_health_check

  # API keys are per-project now: they're generated and revoked from a project's
  # show page. The old standalone settings/api_keys screen is gone — keep a
  # redirect so any bookmark lands on the projects list.
  namespace :settings do
    get "api_keys", to: redirect("/projects"), as: :api_keys
  end

  # Every billing controller is gated by Stablemate.billing_enabled?
  # (Billing::BaseController): on a keyless self-host instance the whole namespace
  # answers an opaque 404. Custom verbs are replaced by RESTful sub-resources:
  # upgrade = create a checkout; manage card = create a portal session;
  # downgrade = create the choose-5 selection.
  namespace :billing do
    resource :subscription, only: :show, controller: "subscriptions"
    resource :checkout, only: :create, controller: "checkouts"
    resource :portal_session, only: :create, controller: "portal_sessions"
    resource :downgrade, only: %i[new create], controller: "downgrades"
    # Stripe's signed, idempotent webhook — the only writer of User.plan.
    resource :webhook, only: :create, controller: "webhooks"
  end

  # Bearer-authed JSON API for the companion gem. Tenant-scoped to the API key's
  # owner; paths kept per the PRD.
  namespace :api do
    namespace :v1 do
      resources :monitors, only: %i[index show] do
        collection do
          post :sync, to: "monitors/syncs#create"
        end
        member do
          post :rotate, to: "monitors/ping_tokens#update"
        end
      end

      # The V1 check-in endpoint, addressed by task key. DECLARED STANDALONE, not
      # nested inside `resources :monitors, param: :registration_key`, which is
      # wrong three ways: it silently retargets `show` (so GET /api/v1/monitors/42
      # arrives as a registration key while find_monitor still reads params[:id]),
      # Rails prefixes the nested parent's parameter so the constraint would name
      # a segment that does not exist, and with the constraint inert dotted task
      # names break.
      #
      # The constraint and format: false are both required: Rails excludes dots
      # from dynamic segments and treats a trailing `.foo` as a format, and task
      # names like `reports.daily` are ordinary. POST only — a check-in resolves
      # incidents and emails "recovered", so anything that follows a link must not
      # be able to fire one.
      post "monitors/:registration_key/pings", to: "monitors/pings#create",
           constraints: { registration_key: %r{[^/]+} }, format: false, as: :monitor_pings

      # Proves the check-in credential end-to-end without recording a check-in.
      # GET is correct here and the POST-only rule above does not apply: this has
      # no side effects, and the credential rides the header.
      get "verify", to: "verifications#show", as: :verify
    end
  end

  # Public ping hot path — the token is the credential. Both verbs so a bare
  # `curl` works.
  match "/ping/:ping_token", to: "pings#create", via: %i[get post], as: :ping

  # Renders for everyone, signed in or not, regardless of the billing config-gate
  # — it's marketing, not a billing surface (unlike the Billing:: namespace, which
  # 404s when keyless).
  get "pricing", to: "pages#pricing"

  # Same shape as /pricing, and deliberately outside the billing config-gate — a
  # self-hoster's users read the same terms as anyone else's.
  get "terms",   to: "pages#terms"
  get "privacy", to: "pages#privacy"

  # Anonymous visitors get the marketing landing page; signed-in users are
  # redirected to their dashboard.
  root "pages#home"
end
