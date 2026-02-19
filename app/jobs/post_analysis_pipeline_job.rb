class PostAnalysisPipelineJob < ApplicationJob
  private

  def load_pipeline_context!(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    post = profile.instagram_profile_posts.find(instagram_profile_post_id)
    pipeline_state = Ai::PostAnalysisPipelineState.new(post: post)
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    return nil unless pipeline

    {
      account: account,
      profile: profile,
      post: post,
      pipeline_state: pipeline_state,
      pipeline: pipeline
    }
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def enqueue_pipeline_finalizer(account:, profile:, post:, pipeline_run_id:, attempts: 0)
    FinalizePostAnalysisPipelineJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: pipeline_run_id,
      attempts: attempts
    )
  rescue StandardError
    nil
  end

  def format_error(error)
    "#{error.class}: #{error.message}".byteslice(0, 320)
  end
end
