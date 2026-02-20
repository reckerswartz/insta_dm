module Admin
  module BackgroundJobs
    class FailuresQuery
      DEFAULT_PER_PAGE = 50
      MIN_PER_PAGE = 10
      MAX_PER_PAGE = 200

      Result = Struct.new(:failures, :total, :pages, keyword_init: true)

      def initialize(
        params:,
        base_scope: BackgroundJobFailure.order(occurred_at: :desc, id: :desc),
        tabulator: Admin::BackgroundJobs::TabulatorParams.new(params: params)
      )
        @params = params
        @base_scope = base_scope
        @tabulator = tabulator
      end

      def call
        scope = apply_tabulator_filters(base_scope)
        scope = apply_search(scope, params[:q])
        scope = apply_remote_sort(scope) || scope

        page = normalize_page(params[:page])
        per_page = normalize_per_page(params[:per_page].presence || params[:size].presence)
        total = scope.count
        pages = (total / per_page.to_f).ceil
        failures = scope.offset((page - 1) * per_page).limit(per_page)

        Result.new(failures: failures, total: total, pages: pages)
      end

      private

      attr_reader :params, :base_scope, :tabulator

      def apply_tabulator_filters(scope)
        tabulator.filters.each do |filter|
          field = filter[:field]
          value = filter[:value]
          next if value.blank?

          case field
          when "job_class"
            term = "%#{value.to_s.downcase}%"
            scope = scope.where("LOWER(job_class) LIKE ?", term)
          when "queue_name"
            term = "%#{value.to_s.downcase}%"
            scope = scope.where("LOWER(COALESCE(queue_name,'')) LIKE ?", term)
          when "error_message"
            term = "%#{value.to_s.downcase}%"
            scope = scope.where("LOWER(COALESCE(error_message,'')) LIKE ?", term)
          when "failure_kind"
            scope = scope.where(failure_kind: value.to_s)
          when "retryable"
            scope = scope.where(retryable: ActiveModel::Type::Boolean.new.cast(value))
          end
        end

        scope
      end

      def apply_search(scope, query)
        value = query.to_s.strip
        return scope if value.blank?

        term = "%#{value.downcase}%"
        scope.where(
          "LOWER(job_class) LIKE ? OR LOWER(COALESCE(queue_name, '')) LIKE ? OR LOWER(error_class) LIKE ? OR LOWER(error_message) LIKE ?",
          term,
          term,
          term,
          term
        )
      end

      def apply_remote_sort(scope)
        first = tabulator.sorters.first
        return nil unless first.respond_to?(:[])

        field = first["field"].to_s
        dir = first["dir"].to_s.downcase == "desc" ? "DESC" : "ASC"

        case field
        when "occurred_at"
          scope.reorder(Arel.sql("occurred_at #{dir}, id #{dir}"))
        when "job_class"
          scope.reorder(Arel.sql("job_class #{dir}, occurred_at DESC, id DESC"))
        when "queue_name"
          scope.reorder(Arel.sql("queue_name #{dir} NULLS LAST, occurred_at DESC, id DESC"))
        when "error_class"
          scope.reorder(Arel.sql("error_class #{dir}, occurred_at DESC, id DESC"))
        when "failure_kind"
          scope.reorder(Arel.sql("failure_kind #{dir}, occurred_at DESC, id DESC"))
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
end
