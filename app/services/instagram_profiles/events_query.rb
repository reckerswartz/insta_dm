module InstagramProfiles
  class EventsQuery
    DEFAULT_PER_PAGE = 25
    MIN_PER_PAGE = 10
    MAX_PER_PAGE = 100

    Result = Struct.new(:events, :total, :pages, keyword_init: true)

    def initialize(profile:, params:, tabulator: TabulatorParams.new(params: params))
      @profile = profile
      @params = params
      @tabulator = tabulator
    end

    def call
      scope = base_scope
      scope = apply_tabulator_event_filters(scope)
      query = params[:q].to_s.strip
      scope = apply_query(scope, query)
      scope = apply_remote_sort(scope) || scope.order(detected_at: :desc, id: :desc)

      page = normalize_page(params[:page])
      per_page = normalize_per_page(params[:per_page].presence || params[:size].presence)
      total = scope.count
      pages = (total / per_page.to_f).ceil
      rows = scope.offset((page - 1) * per_page).limit(per_page)

      Result.new(events: rows, total: total, pages: pages)
    end

    private

    attr_reader :profile, :params, :tabulator

    def base_scope
      profile.instagram_profile_events.with_attached_media.with_attached_preview_image
    end

    def apply_tabulator_event_filters(scope)
      tabulator.filters.each do |filter|
        field = filter[:field]
        value = filter[:value]
        next if value.blank?
        next unless field == "kind"

        term = "%#{value.to_s.downcase}%"
        scope = scope.where("LOWER(kind) LIKE ?", term)
      end
      scope
    end

    def apply_query(scope, query)
      return scope if query.blank?

      term = "%#{query.downcase}%"
      scope.where("LOWER(kind) LIKE ? OR LOWER(COALESCE(external_id, '')) LIKE ?", term, term)
    end

    def apply_remote_sort(scope)
      first = tabulator.sorters.first
      return nil unless first.respond_to?(:[])

      field = first["field"].to_s
      dir = first["dir"].to_s.downcase == "desc" ? "DESC" : "ASC"

      case field
      when "kind"
        scope.order(Arel.sql("kind #{dir}, detected_at DESC, id DESC"))
      when "occurred_at"
        scope.order(Arel.sql("occurred_at #{dir} NULLS LAST, detected_at DESC, id DESC"))
      when "detected_at"
        scope.order(Arel.sql("detected_at #{dir}, id #{dir}"))
      else
        nil
      end
    end

    def normalize_page(raw_page)
      value = raw_page.to_i
      value.positive? ? value : 1
    end

    def normalize_per_page(raw_per_page)
      value = raw_per_page.to_i
      value = DEFAULT_PER_PAGE if value <= 0
      value.clamp(MIN_PER_PAGE, MAX_PER_PAGE)
    end
  end
end
