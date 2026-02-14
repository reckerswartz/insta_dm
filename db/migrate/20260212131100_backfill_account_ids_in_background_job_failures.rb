class BackfillAccountIdsInBackgroundJobFailures < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    say_with_time "Backfilling instagram_account_id / instagram_profile_id on background_job_failures" do
      BackgroundJobFailure.where(instagram_account_id: nil).find_in_batches(batch_size: 500) do |batch|
        batch.each do |f|
          ids = extract_ids(f)
          next if ids[:instagram_account_id].blank? && ids[:instagram_profile_id].blank?

          f.update_columns(
            instagram_account_id: ids[:instagram_account_id],
            instagram_profile_id: ids[:instagram_profile_id]
          )
        end
      end
    end
  end

  def down
    # no-op
  end

  private

  def extract_ids(failure)
    meta = failure.metadata
    if meta.is_a?(Hash)
      aid = meta["instagram_account_id"] || meta[:instagram_account_id]
      pid = meta["instagram_profile_id"] || meta[:instagram_profile_id]
      return { instagram_account_id: int_or_nil(aid), instagram_profile_id: int_or_nil(pid) } if aid.present? || pid.present?
    end

    raw = failure.arguments_json.to_s
    return { instagram_account_id: nil, instagram_profile_id: nil } if raw.blank?

    begin
      parsed = JSON.parse(raw)
      h = Array(parsed).first
      h = h.to_h if h.respond_to?(:to_h)
      aid = h.is_a?(Hash) ? (h["instagram_account_id"] || h[:instagram_account_id]) : nil
      pid = h.is_a?(Hash) ? (h["instagram_profile_id"] || h[:instagram_profile_id]) : nil
      { instagram_account_id: int_or_nil(aid), instagram_profile_id: int_or_nil(pid) }
    rescue StandardError
      { instagram_account_id: nil, instagram_profile_id: nil }
    end
  end

  def int_or_nil(v)
    s = v.to_s.strip
    return nil if s.blank?
    Integer(s)
  rescue StandardError
    nil
  end
end

