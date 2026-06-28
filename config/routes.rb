Rails.application.routes.draw do
  # Authentication (Rails 8 generator). The session resource is the sign-in/out
  # endpoint; we add friendly /sign_in + /sign_up aliases per the design (R3).
  resource :session
  resources :passwords, param: :token

  get  "sign_in",  to: "sessions#new",        as: :sign_in
  get  "sign_up",  to: "registrations#new",   as: :sign_up
  post "sign_up",  to: "registrations#create"
  resources :registrations, only: %i[new create]

  # Non-blocking email verification link.
  get "verify/:token", to: "email_verifications#show", as: :email_verification

  # Authenticated monitor UI. CRUD plus the sub-resource controllers that replace
  # custom verbs: pause/resume and rotate-token (architecture.md §7).
  resources :monitors do
    resource :pause, only: %i[create destroy], module: :monitors
    resource :ping_token, only: :update, module: :monitors
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # API-key management UI (session-authed, owner-only). Generate-once modal +
  # masked list + revoke. (architecture.md §7)
  namespace :settings do
    resources :api_keys, only: %i[index create destroy]
  end

  # Bearer-authed JSON API for the companion gem. Tenant-scoped to the API key's
  # owner. Sync + read + token rotation; paths kept per the PRD. (architecture.md §7)
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
    end
  end

  # Public ping hot path — the token is the credential. Both verbs so a bare
  # `curl` works; recorded as a "create" of a ping. (architecture.md §7)
  match "/ping/:ping_token", to: "pings#create", via: %i[get post], as: :ping

  # Defines the root path route ("/")
  root "monitors#index"
end
