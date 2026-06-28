Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Public ping hot path — the token is the credential. Both verbs so a bare
  # `curl` works; recorded as a "create" of a ping. (architecture.md §7)
  match "/ping/:ping_token", to: "pings#create", via: %i[get post], as: :ping

  # Throwaway status read for the Phase 0 walking skeleton (replaced by the
  # authenticated dashboard in Phase 1). JSON only.
  resources :monitors, only: :show, defaults: { format: :json }

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
