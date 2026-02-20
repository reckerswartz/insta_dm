module InstagramProfiles
  class ProfilesIndexQuery
    DEFAULT_PER_PAGE = 50
    MIN_PER_PAGE = 10
    MAX_PER_PAGE = 200

    Result = Struct.new(
      :q,
      :filter,
      :page,
      :per_page,
      :total,
      :pages,
      :profiles,
      keyword_init: true
    )

    def initialize(account:, params:, tabulator: TabulatorParams.new(params: params))
      @account = account
      @params = params
      @tabulator = tabulator
    end

    def call
      scope = apply_tabulator_profile_filters(base_scope)
      query = params[:q].to_s.strip
      scope = apply_query(scope, query)

      filter = {
        mutual: tabulator.truthy?(:mutual),
        following: tabulator.truthy?(:following),
        follows_you: tabulator.truthy?(:follows_you),
        can_message: tabulator.truthy?(:can_message)
      }
      scope = apply_filter(scope, filter: filter)
      scope = apply_remote_sort(scope) || apply_sort(scope, params[:sort].to_s)

      page = normalize_page(params[:page])
      per_page = normalize_per_page(params[:per_page].presence || params[:size].presence)
      total = scope.count
      pages = (total / per_page.to_f).ceil
      rows = scope.offset((page - 1) * per_page).limit(per_page)

      Result.new(
        q: query,
        filter: filter,
        page: page,
        per_page: per_page,
        total: total,
        pages: pages,
        profiles: rows
      )
    end

    private

    attr_reader :account, :params, :tabulator

    def base_scope
      account.instagram_profiles
    end

    def apply_tabulator_profile_filters(scope)
      tabulator.filters.each do |filter|
        field = filter[:field]
        value = filter[:value]
        next if value.blank?

        case field
        when "username"
          term = "%#{value.to_s.downcase}%"
          scope = scope.where("LOWER(username) LIKE ?", term)
        when "display_name"
          term = "%#{value.to_s.downcase}%"
          scope = scope.where("LOWER(COALESCE(display_name, '')) LIKE ?", term)
        when "following"
          parsed = tabulator.parse_tri_bool(value)
          scope = scope.where(following: parsed) unless parsed.nil?
        when "follows_you"
          parsed = tabulator.parse_tri_bool(value)
          scope = scope.where(follows_you: parsed) unless parsed.nil?
        when "mutual"
          parsed = tabulator.parse_tri_bool(value)
          if parsed == true
            scope = scope.where(following: true, follows_you: true)
          elsif parsed == false
            scope = scope.where.not(following: true, follows_you: true)
          end
        when "can_message"
          scope = if value.to_s == "unknown"
            scope.where(can_message: nil)
          else
            parsed = tabulator.parse_tri_bool(value)
            parsed.nil? ? scope : scope.where(can_message: parsed)
          end
        end
      end
      scope
    end

    def apply_query(scope, query)
      return scope if query.blank?

      term = "%#{query.downcase}%"
      scope.where("LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?", term, term)
    end

    def apply_filter(scope, filter:)
      scope = scope.where(following: true, follows_you: true) if filter[:mutual]
      scope = scope.where(following: true) if filter[:following]
      scope = scope.where(follows_you: true) if filter[:follows_you]
      scope = scope.where(can_message: true) if filter[:can_message]
      scope
    end

    def apply_sort(scope, sort)
      case sort
      when "username_asc"
        scope.order(Arel.sql("username ASC"))
      when "username_desc"
        scope.order(Arel.sql("username DESC"))
      when "recent_sync"
        scope.order(Arel.sql("last_synced_at DESC NULLS LAST, username ASC"))
      when "messageable"
        scope.order(Arel.sql("can_message DESC NULLS LAST, username ASC"))
      when "recent_active"
        scope.order(Arel.sql("last_active_at DESC NULLS LAST, username ASC"))
      else
        scope.order(Arel.sql("following DESC, follows_you DESC, username ASC"))
      end
    end

    def apply_remote_sort(scope)
      first = tabulator.sorters.first
      return nil unless first.respond_to?(:[])

      field = first["field"].to_s
      dir = first["dir"].to_s.downcase == "desc" ? "DESC" : "ASC"

      case field
      when "username"
        scope.order(Arel.sql("username #{dir}"))
      when "display_name"
        scope.order(Arel.sql("display_name #{dir} NULLS LAST, username ASC"))
      when "following"
        scope.order(Arel.sql("following #{dir}, username ASC"))
      when "follows_you"
        scope.order(Arel.sql("follows_you #{dir}, username ASC"))
      when "mutual"
        scope.order(Arel.sql("following #{dir}, follows_you #{dir}, username ASC"))
      when "can_message"
        scope.order(Arel.sql("can_message #{dir} NULLS LAST, username ASC"))
      when "last_synced_at"
        scope.order(Arel.sql("last_synced_at #{dir} NULLS LAST, username ASC"))
      when "last_active_at"
        scope.order(Arel.sql("last_active_at #{dir} NULLS LAST, username ASC"))
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
