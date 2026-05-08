Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "/health", to: proc { [ 200, {}, [ "ok" ] ] }

  # Defines the root path route ("/")
  # root "posts#index"
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
  namespace :api do
    namespace :v1 do
      # Authentication routes for the three-legged OAuth flow
      get "auth/login", to: "auth#login"
      get "auth/callback", to: "auth#callback"
      get "auth/status", to: "auth#status"
      post "auth/logout", to: "auth#logout"

      # hubs and projects routes
      get "hubs", to: "hubs#index"
      get "hubs/:hub_id/projects", to: "hubs#projects"
      get "hubs/:hub_id/projects/:project_id/folders", to: "projects#top_folders"
      get "projects/:project_id/folders/:folder_id/contents", to: "folders#contents"

      # items versions
      get "projects/:project_id/items/:item_id/versions", to: "items#versions"

      # translation and polling api
      post "translate", to: "translations#create"
      get "translate/:urn/status", to: "translations#status"

      # sharing url
      post "share", to: "shares#create"
    end
  end
  # Public viewer
  get "viewer/:token", to: "api/v1/viewer#show"
end
