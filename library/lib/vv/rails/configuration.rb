module Vv
  module Rails
    class Configuration
      attr_accessor :channel_prefix,    # "vv" — stream name prefix
                    :cable_url,         # WebSocket URL for plugin discovery
                    :allowed_origins,   # Origins allowed to connect (CORS for WebSocket)
                    :authenticate,      # Proc for connection auth: ->(params) { User.find(params[:token]) }
                    :on_connect,        # Proc called when plugin connects
                    :on_disconnect      # Proc called when plugin disconnects

      def initialize
        @channel_prefix = "vv"
        @cable_url = nil
        @allowed_origins = nil  # nil = allow all (dev), set in production
        @authenticate = nil
        @on_connect = nil
        @on_disconnect = nil
      end
    end

    class << self
      attr_writer :configuration

      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end
    end
  end
end
