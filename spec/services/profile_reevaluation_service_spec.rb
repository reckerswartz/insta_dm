require 'rails_helper'
require 'securerandom'

RSpec.describe ProfileReevaluationService, type: :service do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }
  let(:profile) do
    account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 150
    )
  end
  let(:service) { described_class.new(account: account, profile: profile) }

  describe '#reevaluate_after_content_scan!' do
    context 'when profile has no existing demographics' do
      let!(:post1) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 25,
              'age_confidence' => 0.4
            }
          }
        )
      end

      it 'creates profile re-evaluation event' do
        expect {
          service.send(:reevaluate_after_content_scan!, content_type: 'post', content_id: 123)
        }.to change { profile.instagram_profile_events.where(kind: 'profile_reevaluated').count }.by(1)
      end
    end

    context 'when profile was recently analyzed' do
      before do
        profile.update!(ai_last_analyzed_at: 10.minutes.ago)
      end

      it 'skips re-evaluation due to time limit' do
        expect {
          service.send(:reevaluate_after_content_scan!, content_type: 'post', content_id: 123)
        }.not_to change { profile.instagram_profile_events.where(kind: 'profile_reevaluated').count }
      end
    end

    context 'when profile has demographic evidence from posts' do
      let!(:post1) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 25,
              'age_confidence' => 0.4,
              'gender' => 'female',
              'gender_confidence' => 0.5
            }
          }
        )
      end

      before do
        profile.update!(ai_last_analyzed_at: 2.hours.ago)
      end

      it 'updates profile demographics from post evidence' do
        expect {
          service.send(:reevaluate_after_content_scan!, content_type: 'post', content_id: 123)
        }.to change { profile.reload.ai_estimated_age }.from(nil).to(25)
         .and change { profile.reload.ai_estimated_gender }.from(nil).to('female')
      end
    end

    context 'when there is conflicting evidence' do
      let!(:post1) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 25,
              'age_confidence' => 0.4
            }
          }
        )
      end

      let!(:post2) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 40,
              'age_confidence' => 0.4
            }
          }
        )
      end

      before do
        profile.update!(ai_last_analyzed_at: 2.hours.ago)
      end

      it 'detects and logs conflicting evidence' do
        expect(Rails.logger).to receive(:warn).with(/Conflicting evidence.*age_conflict/)
        service.send(:reevaluate_after_content_scan!, content_type: 'post', content_id: 123)
      end
    end

    context 'when confidence is low' do
      let!(:post1) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 25,
              'age_confidence' => 0.2  # Low confidence
            }
          }
        )
      end

      let!(:post2) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 26,
              'age_confidence' => 0.25  # Low confidence
            }
          }
        )
      end

      let!(:post3) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 24,
              'age_confidence' => 0.3  # Low confidence
            }
          }
        )
      end

      let!(:post4) do
        profile.instagram_profile_posts.create!(
          instagram_account: account,
          shortcode: "post_#{SecureRandom.hex(3)}",
          analysis: {
            'inferred_demographics' => {
              'age' => 27,
              'age_confidence' => 0.28  # Low confidence
            }
          }
        )
      end

      before do
        profile.update!(
          ai_last_analyzed_at: 2.hours.ago,
          ai_estimated_age: 25,
          ai_age_confidence: 0.2  # Low confidence to trigger re-verification
        )
      end

      it 'schedules re-verification when confidence is low and evidence exists' do
        expect(AnalyzeInstagramProfileJob).to receive(:perform_later).with(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          profile_action_log_id: nil
        )
        
        service.send(:reevaluate_after_content_scan!, content_type: 'post', content_id: 123)
      end
    end
  end

  describe 'private methods' do
    describe '#normalize_gender' do
      it 'normalizes various gender inputs' do
        expect(service.send(:normalize_gender, 'woman')).to eq('female')
        expect(service.send(:normalize_gender, 'MAN')).to eq('male')
        expect(service.send(:normalize_gender, 'NonBinary')).to eq('non-binary')
        expect(service.send(:normalize_gender, '')).to be_nil
        expect(service.send(:normalize_gender, nil)).to be_nil
      end
    end

    describe '#normalize_location' do
      it 'normalizes location strings' do
        expect(service.send(:normalize_location, 'new york, ny')).to eq('New York, Ny')
        expect(service.send(:normalize_location, '  los angeles  ')).to eq('Los Angeles')
        expect(service.send(:normalize_location, '')).to be_nil
        expect(service.send(:normalize_location, nil)).to be_nil
      end
    end

    describe '#extract_demographics_from_text' do
      it 'extracts age from text' do
        text = "Just turned 25 years old and loving life!"
        result = service.send(:extract_demographics_from_text, text)
        expect(result[:age]).to eq(25)
        expect(result[:age_confidence]).to eq(0.28)
      end

      it 'extracts gender from text' do
        text = "She/her and loving every moment"
        result = service.send(:extract_demographics_from_text, text)
        expect(result[:gender]).to eq('female')
        expect(result[:gender_confidence]).to eq(0.4)
      end

      it 'extracts location from text' do
        text = "Based in San Francisco, loving the weather"
        result = service.send(:extract_demographics_from_text, text)
        expect(result[:location]).to eq('San Francisco')
        expect(result[:location_confidence]).to eq(0.35)
      end
    end
  end
end
