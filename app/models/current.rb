class Current < ActiveSupport::CurrentAttributes
  attribute :active_job_id,
    :provider_job_id,
    :job_class,
    :queue_name,
    :instagram_account_id,
    :instagram_profile_id

  def job_context
    {
      active_job_id: active_job_id,
      provider_job_id: provider_job_id,
      job_class: job_class,
      queue_name: queue_name,
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id
    }
  end
end
