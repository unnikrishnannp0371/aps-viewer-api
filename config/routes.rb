Rails.application.routes.draw do
  # ── Health check ───────────────────────────────────────────────────────────
  get "/health", to: proc { [ 200, {}, [ "ok" ] ] }

  get "debug/token", to: proc { |env|
    token = env["rack.session"][:aps_access_token]
    [ 200, { "Content-Type" => "application/json" }, [ { token: token }.to_json ] ]
  }

  # ── API ────────────────────────────────────────────────────────────────────
  namespace :api do
    namespace :v1 do
      # Auth
      get  "auth/login",        to: "auth#login"
      get  "auth/callback",     to: "auth#callback"
      get  "auth/status",       to: "auth#status"
      post "auth/logout",       to: "auth#logout"
      get  "auth/viewer-token", to: "auth#viewer_token"

      # Hubs + Projects
      get "hubs",                  to: "hubs#index"
      get "hubs/:hub_id/projects", to: "hubs#projects"

      # Folders + Items
      get "hubs/:hub_id/projects/:project_id/folders",        to: "projects#top_folders"
      get "projects/:project_id/folders/:folder_id/contents", to: "folders#contents"
      get "projects/:project_id/items/:item_id/versions",     to: "items#versions"

      # Model Derivative
      post "translate",             to: "translations#create"
      get  "translate/:urn/status", to: "translations#status"

      # Share
      post "share", to: "shares#create"

      # Issues
      get "projects/:project_id/issues",     to: "issues#index"
      get "projects/:project_id/issues/:id", to: "issues#show"

      # RFIs
      get "projects/:project_id/rfis", to: "rfis#index"

      # Submittals
      get "projects/:project_id/submittals", to: "submittals#index"

      # Health score
      get "projects/:project_id/health", to: "health#index"

      # Clashes
      get "projects/:project_id/clashes/summary", to: "clashes#summary"

      # Viewer
      get "viewer/auth/:urn", to: "viewer_auth#show"
      get "viewer/:token",    to: "viewer#show"
    end
  end
end
