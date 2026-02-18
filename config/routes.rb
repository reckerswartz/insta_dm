Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  root "instagram_accounts#index"

  namespace :admin do
    get :background_jobs, to: "background_jobs#dashboard"
    get "background_jobs/failures", to: "background_jobs#failures", as: :background_job_failures
    get "background_jobs/failures/:id", to: "background_jobs#failure", as: :background_job_failure
    post "background_jobs/failures/:id/retry", to: "background_jobs#retry_failure", as: :retry_background_job_failure
    post "background_jobs/clear_all", to: "background_jobs#clear_all_jobs", as: :clear_all_background_jobs
    resources :issues, only: %i[index update] do
      member do
        post :retry_job
      end
    end
    resources :storage_ingestions, only: [:index]
  end

  mount MissionControl::Jobs::Engine, at: "/admin/jobs"

  resources :instagram_accounts, only: %i[index show create update destroy] do
    member do
      post :select
      post :manual_login
      post :import_cookies
      get :export_cookies
      post :validate_session
      post :sync_next_profiles
      post :sync_profile_stories
      post :sync_stories_with_comments
      post :sync_all_stories_continuous
      get :story_media_archive
      post :generate_llm_comment
      get :technical_details
      post :run_continuous_processing
    end
  end

  # Primary sync source: followers + following.
  resource :follow_graph_sync, only: :create
  resource :feed_capture, only: :create

  resources :instagram_profiles, only: %i[index show] do
    resources :instagram_profile_messages, only: :create
    resources :instagram_profile_posts, only: [] do
      post :analyze, on: :member
      post :forward_comment, on: :member
    end

    collection do
      post :download_missing_avatars, to: "instagram_profile_actions#download_missing_avatars"
    end

    member do
      get :events
      get :captured_posts_section
      get :downloaded_stories_section
      get :messages_section
      get :action_history_section
      get :events_table_section
      patch :tags, to: "instagram_profiles#tags"
      post :analyze, to: "instagram_profile_actions#analyze"
      post :fetch_details, to: "instagram_profile_actions#fetch_details"
      post :verify_messageability, to: "instagram_profile_actions#verify_messageability"
      post :download_avatar, to: "instagram_profile_actions#download_avatar"
      post :sync_stories, to: "instagram_profile_actions#sync_stories"
      post :sync_stories_force, to: "instagram_profile_actions#sync_stories_force"
      post :sync_stories_debug, to: "instagram_profile_actions#sync_stories_debug"
    end
  end

  resources :instagram_posts, only: %i[index show]

  # AI Dashboard
  resources :ai_dashboard, only: [:index] do
    collection do
      post :test_service
      post :test_all_services
    end
  end

  # Legacy endpoints kept for now (conversation/story recipients + bulk sending).
  resource :sync, only: :create
  resources :recipients, only: [] do
    collection { patch :update_all }
  end
  resources :messages, only: :create

  get "up" => "rails/health#show", as: :rails_health_check
end
