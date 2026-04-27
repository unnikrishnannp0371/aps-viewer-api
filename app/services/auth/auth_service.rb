require "json"
require "base64"
require "uri"
require "rest-client"

module Auth
  class AuthService
    class << self
      #
      # ----------------------------
      # ENV Helpers
      # ----------------------------
      #

      def authorize_url
        ENV["APS_AUTHORIZE_URL"] || "https://developer.api.autodesk.com/authentication/v2/authorize"
      end

      def token_url
        ENV["APS_TOKEN_URL"] || "https://developer.api.autodesk.com/authentication/v2/token"
      end

      def client_id
        ENV["APS_CLIENT_ID"]
      end

      def client_secret
        ENV["APS_CLIENT_SECRET"]
      end

      def scope
        ENV["APS_SCOPE"]
      end

      #
      # ----------------------------
      # OAuth Login URL (3-Legged)
      # ----------------------------
      #

      def auth_url(callback_url)
        params = {
          response_type: "code",
          client_id: client_id,
          redirect_uri: callback_url,
          scope: scope
        }

        "#{authorize_url}?#{URI.encode_www_form(params)}"
      end

      #
      # ----------------------------
      # Exchange Code → Access Token
      # ----------------------------
      #

      def exchange_code_for_token(code, callback_url)
        payload = {
          grant_type: "authorization_code",
          code: code,
          redirect_uri: callback_url
        }

        post_form(token_url, payload)
      end

      #
      # ----------------------------
      # Refresh Access Token
      # ----------------------------
      #

      def refresh_token(refresh_token_value)
        payload = {
          grant_type: "refresh_token",
          refresh_token: refresh_token_value
        }

        post_form(token_url, payload)
      end

      #
      # ----------------------------
      # Two-Legged Token
      # ----------------------------
      #

      def two_legged_token
        payload = {
          grant_type: "client_credentials",
          scope: scope
        }

        response = post_form(token_url, payload)
        response["access_token"]
      end

      #
      # ----------------------------
      # Shared HTTP POST Helper
      # ----------------------------
      #

      def post_form(url, payload)
        headers = {
          Authorization: "Basic #{basic_auth_token}",
          content_type: "application/x-www-form-urlencoded",
          accept: :json
        }

        response = RestClient.post(url, payload, headers)
        JSON.parse(response.body)

      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("APS Auth Error: #{e.response}")
        raise StandardError, "APS Authentication Failed"
      end

      #
      # ----------------------------
      # Basic Auth Header
      # ----------------------------
      #

      def basic_auth_token
        Base64.strict_encode64("#{client_id}:#{client_secret}")
      end

      def valid_access_token(session)
        if session[:aps_access_token].present? &&
          session[:aps_expires_at].present? &&
          Time.current.to_i < session[:aps_expires_at].to_i

          return session[:aps_access_token]
        end
        refresh_access_token(session)
      end

      def refresh_access_token(session)
        refresh = session[:aps_refresh_token]
        return nil if refresh.blank?

        response = refresh_token(refresh)
        return nil unless response["access_token"]

        session[:aps_access_token] = response["access_token"]
        session[:aps_refresh_token] = response["refresh_token"] if response["refresh_token"].present?
        session[:aps_expires_at] = Time.current.to_i + response["expires_in"].to_i

        session[:aps_access_token]

      rescue StandardError => e
        Rails.logger.error("APS Refresh Error: #{e.message}")
        nil
      end
    end
  end
end
