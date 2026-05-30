# Mixin for APS REST calls. Include in any service that talks to the
# Autodesk Platform Services API.
#
# Usage:
#   class MyService
#     include ApsHttp
#     def initialize(token:) = @token = token
#   end
#
# All services follow the same pattern:
#   - Instantiated with token: keyword argument
#   - Token stored as @token
#   - HTTP calls pass @token explicitly to get/paginate

module ApsHttp
  # URL-safe query string builder — escapes both keys and values.
  def build_params(opts)
    opts.compact.map { |k, v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v.to_s)}" }.join("&")
  end

  # Paginate through any ACC/APS endpoint that uses offset/limit pagination.
  #
  # @param path         [String]  full path, e.g. "/construction/issues/v1/projects/X/issues"
  # @param access_token [String]  bearer token
  # @param extra_params [Hash]    additional query params merged on every page
  # @param page_size    [Integer] records per page (max depends on endpoint)
  # @yield              [Array]   each page's raw result array (optional)
  # @return             [Array]   all records across all pages
  def paginate(path, access_token, extra_params: {}, page_size: 100)
    all    = []
    offset = 0

    loop do
      params = build_params(extra_params.merge(offset: offset, limit: page_size))
      page   = get("#{path}?#{params}", access_token)
      batch  = page["results"] || []

      yield batch if block_given?
      all.concat(batch)

      total = page.dig("pagination", "totalResults").to_i
      break if all.length >= total || batch.empty?

      offset += page_size
    end

    all
  end

  # Raw GET — raises StandardError on HTTP error responses.
  def get(path, access_token)
    url = "#{Aps::Base::BASE_URL}#{path}"
    response = RestClient::Request.execute(
      method:       :get,
      url:          url,
      headers:      { Authorization: "Bearer #{access_token}", Accept: "application/json" },
      timeout:      30,
      open_timeout: 10
    )
    JSON.parse(response.body)
  rescue RestClient::ExceptionWithResponse => e
    Rails.logger.error("APS HTTP Error [GET #{path}]: #{e.response}")
    raise StandardError, "APS request failed (#{e.response.code})"
  end
end
