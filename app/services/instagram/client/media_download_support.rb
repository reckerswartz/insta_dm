module Instagram
  class Client
    module MediaDownloadSupport
      private

      def download_media_with_metadata(url:, user_agent:, redirect_limit: 3)
        media_download_service.call(url: url, user_agent: user_agent, redirect_limit: redirect_limit)
      end

      def media_download_service
        @media_download_service ||= MediaDownloadService.new(base_url: INSTAGRAM_BASE_URL)
      end
    end
  end
end
