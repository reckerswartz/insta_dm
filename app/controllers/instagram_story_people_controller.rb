class InstagramStoryPeopleController < ApplicationController
  before_action :require_current_account!
  before_action :set_profile
  before_action :set_person, only: %i[
    show
    confirm
    mark_incorrect
    link_profile_owner
    merge
    separate_face
  ]
  before_action :set_feedback_service, only: %i[
    confirm
    mark_incorrect
    link_profile_owner
    merge
    separate_face
  ]

  def show
    @post_groups = grouped_post_faces(@person)
    @story_groups = grouped_story_faces(@person)
    @post_face_count = @person.instagram_post_faces.count
    @story_face_count = @person.instagram_story_faces.count
    @total_appearances = @post_face_count + @story_face_count
    @merge_candidates = @profile.instagram_story_people.recently_seen.where.not(id: @person.id).limit(80)
  end

  def confirm
    @feedback_service.confirm_person!(
      person: @person,
      label: params[:label],
      real_person_status: params[:real_person_status]
    )
    redirect_to person_path(@person), notice: "Identity confirmed for #{@person.display_label}."
  rescue StandardError => e
    redirect_to person_path(@person), alert: "Unable to confirm identity: #{e.message}"
  end

  def mark_incorrect
    @feedback_service.mark_incorrect!(
      person: @person,
      reason: params[:reason]
    )
    redirect_to person_path(@person), notice: "#{@person.display_label} was marked as incorrect."
  rescue StandardError => e
    redirect_to person_path(@person), alert: "Unable to mark person as incorrect: #{e.message}"
  end

  def link_profile_owner
    @feedback_service.link_profile_owner!(person: @person)
    redirect_to person_path(@person), notice: "#{@person.display_label} is now linked as the profile owner."
  rescue StandardError => e
    redirect_to person_path(@person), alert: "Unable to set profile owner link: #{e.message}"
  end

  def merge
    target_person = @profile.instagram_story_people.find(params[:target_person_id])
    @feedback_service.merge_people!(source_person: @person, target_person: target_person)
    redirect_to person_path(target_person), notice: "Merged #{@person.display_label} into #{target_person.display_label}."
  rescue StandardError => e
    redirect_to person_path(@person), alert: "Unable to merge identities: #{e.message}"
  end

  def separate_face
    face = find_face!(params[:face_type], params[:face_id])
    new_person = @feedback_service.separate_face!(person: @person, face: face)
    redirect_to person_path(new_person), notice: "Created #{new_person.display_label} from a separated detection."
  rescue StandardError => e
    redirect_to person_path(@person), alert: "Unable to separate detection: #{e.message}"
  end

  private

  def set_profile
    @profile = current_account.instagram_profiles.find(params[:instagram_profile_id])
  end

  def set_person
    @person = @profile.instagram_story_people.find(params[:id])
  end

  def set_feedback_service
    @feedback_service = PersonIdentityFeedbackService.new
  end

  def person_path(person)
    instagram_profile_instagram_story_person_path(@profile, person)
  end

  def find_face!(face_type, face_id)
    token = face_type.to_s.strip
    id = face_id.to_i
    raise ActiveRecord::RecordNotFound, "Face id missing" unless id.positive?

    if token == "story"
      InstagramStoryFace
        .joins(:instagram_story)
        .where(instagram_stories: { instagram_profile_id: @profile.id })
        .find(id)
    else
      InstagramPostFace
        .joins(:instagram_profile_post)
        .where(instagram_profile_posts: { instagram_profile_id: @profile.id })
        .find(id)
    end
  end

  def grouped_post_faces(person)
    faces = person.instagram_post_faces
      .includes(instagram_profile_post: [ media_attachment: :blob, preview_image_attachment: :blob ])
      .order(created_at: :desc)
      .limit(240)
      .to_a

    grouped_faces(
      faces: faces,
      owner_key: :instagram_profile_post_id,
      count_rows: InstagramPostFace
        .where(instagram_profile_post_id: faces.map(&:instagram_profile_post_id).uniq)
        .where.not(instagram_story_person_id: nil)
        .pluck(:instagram_profile_post_id, :instagram_story_person_id)
    )
  end

  def grouped_story_faces(person)
    faces = person.instagram_story_faces
      .includes(instagram_story: [ media_attachment: :blob ])
      .order(created_at: :desc)
      .limit(240)
      .to_a

    grouped_faces(
      faces: faces,
      owner_key: :instagram_story_id,
      count_rows: InstagramStoryFace
        .where(instagram_story_id: faces.map(&:instagram_story_id).uniq)
        .where.not(instagram_story_person_id: nil)
        .pluck(:instagram_story_id, :instagram_story_person_id)
    )
  end

  def grouped_faces(faces:, owner_key:, count_rows:)
    return [] if faces.empty?

    people_count_by_owner = count_rows
      .group_by(&:first)
      .transform_values { |rows| rows.map(&:last).uniq.size }

    faces
      .group_by(&owner_key)
      .map do |owner_id, row_faces|
        owner = row_faces.first.public_send(owner_key.to_s.sub(/_id\z/, ""))
        next unless owner

        total_people = people_count_by_owner[owner_id].to_i
        {
          owner: owner,
          faces: row_faces.first(8),
          face_count_for_person: row_faces.length,
          total_people: total_people,
          scope: total_people > 1 ? "multiple_people" : "single_person",
          occurred_at: owner.respond_to?(:taken_at) ? owner.taken_at : nil
        }
      end
      .compact
      .sort_by { |row| [ row[:occurred_at] || Time.at(0), row[:owner].id ] }
      .reverse
  end
end
