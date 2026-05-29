# app/services/auth/auth_service.rb

require "json"
require "base64"
require "uri"
require "rest-client"

module Auth
  class AuthService
    class << self
      # ── URL constants ────────────────────────────────────────────────────

      def base_url
        ENV.fetch("APS_BASE_URL", "https://developer.api.autodesk.com")
      end

      def authorize_url
        ENV.fetch("APS_AUTHORIZE_URL", "#{base_url}/authentication/v2/authorize")
      end

      def token_url
        ENV.fetch("APS_TOKEN_URL", "#{base_url}/authentication/v2/token")
      end

      def user_info_url
        ENV.fetch("APS_USER_INFO_URL", "https://api.userprofile.autodesk.com/userinfo")
      end

      # ── Credentials ──────────────────────────────────────────────────────

      def client_id     = ENV["APS_CLIENT_ID"]
      def client_secret = ENV["APS_CLIENT_SECRET"]
      def scope         = ENV["APS_SCOPE"]

      # ── OAuth Login URL (3-Legged) ────────────────────────────────────────

      def auth_url(callback_url)
        params = {
          response_type: "code",
          client_id:     client_id,
          redirect_uri:  callback_url,
          scope:         scope
        }
        "#{authorize_url}?#{URI.encode_www_form(params)}"
      end

      # ── Token exchange ────────────────────────────────────────────────────

      def exchange_code_for_token(code, callback_url)
        post_form(token_url, grant_type: "authorization_code", code: code, redirect_uri: callback_url)
      end

      def refresh_token(refresh_token_value)
        post_form(token_url, grant_type: "refresh_token", refresh_token: refresh_token_value)
      end

      def two_legged_token
        response = post_form(token_url, grant_type: "client_credentials", scope: "viewables:read")
        Rails.logger.info("2-legged token response keys: #{response.keys}")
        response["access_token"]
      end

      # ── Session helpers ───────────────────────────────────────────────────

      # Returns a valid access token from the session, auto-refreshing if needed.
      def valid_access_token(session)
        token      = session[:aps_access_token]
        expires_at = session[:aps_expires_at].to_i

        return token if token.present? && Time.current.to_i < (expires_at - 300)

        refresh_access_token(session)
      end

      def refresh_access_token(session)
        refresh = session[:aps_refresh_token]
        return nil if refresh.blank?

        response = refresh_token(refresh)
        return nil unless response["access_token"]

        session[:aps_access_token]  = response["access_token"]
        session[:aps_refresh_token] = response["refresh_token"] if response["refresh_token"].present?
        session[:aps_expires_at]    = Time.current.to_i + response["expires_in"].to_i
        session[:aps_access_token]
      rescue StandardError => e
        Rails.logger.error("APS Refresh Error: #{e.message}")
        nil
      end

      # ── User info ─────────────────────────────────────────────────────────

      def fetch_user_info(access_token)
        response = RestClient.get(
          user_info_url,
          Authorization: "Bearer #{access_token}",
          Accept:        "application/json"
        )
        JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("APS User Info Error: #{e.response.body}")
        raise StandardError, "Failed to fetch user info"
      end

      private

      # ── HTTP helpers ──────────────────────────────────────────────────────

      def post_form(url, payload)
        response = RestClient.post(url, payload, {
          Authorization: "Basic #{basic_auth_token}",
          content_type:  "application/x-www-form-urlencoded",
          accept:        :json
        })
        JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("APS Auth Error: #{e.response}")
        raise StandardError, "APS Authentication Failed"
      end

      def basic_auth_token
        Base64.strict_encode64("#{client_id}:#{client_secret}")
      end
    end
  end
end
