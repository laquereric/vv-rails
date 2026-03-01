require "rails_event_store"

module Vv
  module Rails
    module Events
      # Form lifecycle
      FormOpened         = Class.new(RailsEventStore::Event)
      FormPolled         = Class.new(RailsEventStore::Event)
      FormStateChanged   = Class.new(RailsEventStore::Event)

      # User interaction
      UserInputReceived  = Class.new(RailsEventStore::Event)
      FieldHelpRequested = Class.new(RailsEventStore::Event)

      # System
      FormErrorOccurred  = Class.new(RailsEventStore::Event)
      NavigationOccurred = Class.new(RailsEventStore::Event)
      DataQueried        = Class.new(RailsEventStore::Event)

      # Assistant
      AssistantResponded = Class.new(RailsEventStore::Event)

      TYPE_MAP = {
        "form_open"  => FormOpened,
        "form_poll"  => FormPolled,
        "form_state" => FormStateChanged,
        "user_input" => UserInputReceived,
        "field_help" => FieldHelpRequested,
        "form_error" => FormErrorOccurred,
        "navigation" => NavigationOccurred,
        "data_query" => DataQueried,
        "assistant"  => AssistantResponded,
      }.freeze

      REVERSE_MAP = TYPE_MAP.invert.freeze
      ALL = TYPE_MAP.values.freeze

      def self.for(message_type)
        TYPE_MAP[message_type]
      end

      def self.message_type_for(event)
        REVERSE_MAP[event.class]
      end

      def self.to_message_hash(event)
        {
          "role"         => event.data[:role] || event.data["role"],
          "message_type" => message_type_for(event),
          "content"      => event.data[:content] || event.data["content"],
        }
      end
    end
  end
end
