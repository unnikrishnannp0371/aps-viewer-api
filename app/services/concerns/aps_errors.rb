module ApsErrors
  class Base          < StandardError; end
  class Unauthorized  < Base; end  # 401
  class Forbidden     < Base; end  # 403
  class NotFound      < Base; end  # 404
  class RateLimited   < Base; end  # 429
  class ServerError   < Base; end  # 5xx
end
