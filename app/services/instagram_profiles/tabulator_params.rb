module InstagramProfiles
  class TabulatorParams
    def initialize(params:)
      @params = params
    end

    def filters
      raw = params[:filters].presence || params[:filter]
      return [] unless raw.present?

      entries =
        case raw
        when String
          JSON.parse(raw)
        when Array
          raw
        when ActionController::Parameters
          raw.to_unsafe_h.values
        else
          []
        end

      Array(entries).filter_map do |item|
        hash = item.respond_to?(:to_h) ? item.to_h : {}
        field = hash["field"].to_s
        next if field.blank?

        { field: field, value: hash["value"] }
      end
    rescue StandardError
      []
    end

    def sorters
      raw = params[:sorters].presence || params[:sort]
      return [] unless raw.present?

      case raw
      when String
        parsed = JSON.parse(raw)
        parsed.is_a?(Array) ? parsed : []
      when Array
        raw
      when ActionController::Parameters
        raw.to_unsafe_h.values
      else
        []
      end
    rescue StandardError
      []
    end

    def parse_tri_bool(value)
      normalized = value.to_s
      return nil if normalized.blank?
      return true if %w[true 1 yes].include?(normalized.downcase)
      return false if %w[false 0 no].include?(normalized.downcase)

      nil
    end

    def truthy?(key)
      ActiveModel::Type::Boolean.new.cast(params[key])
    end

    private

    attr_reader :params
  end
end
