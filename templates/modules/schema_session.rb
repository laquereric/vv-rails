# modules/schema_session.rb — Session and Turn tables + ActiveRecord models
#
# Depends on: base, schema_llm


@vv_applied_modules ||= []; @vv_applied_modules << "schema_session"

after_bundle do
  generate "migration", "CreateSessions title:string metadata:json"
  generate "migration", "CreateTurns session:references model:references message_history:json request:text completion:text input_tokens:integer output_tokens:integer duration_ms:integer"

  # Add preset as a nullable reference (preset is optional on Turn)
  turns_migration = Dir.glob("db/migrate/*_create_turns.rb").first
  inject_into_file turns_migration, after: "t.references :model, null: false, foreign_key: true\n" do
    "      t.references :preset, null: true, foreign_key: true\n"
  end

  file "app/models/session.rb", <<~RUBY
    class Session < ApplicationRecord
      has_many :turns, -> { order(:created_at) }, dependent: :destroy

      validates :title, presence: true

      def events
        Rails.configuration.event_store.read.stream("session:\#{id}").to_a
      end

      def messages_from_events
        events.map { |e| Vv::Rails::Events.to_message_hash(e) }
      end

      def as_json(options = {})
        super(options.merge(include: options[:include] || {}, methods: []))
      end
    end
  RUBY

  file "app/models/turn.rb", <<~RUBY
    class Turn < ApplicationRecord
      belongs_to :session
      belongs_to :model
      belongs_to :preset, optional: true

      validates :message_history, presence: true
      validates :request, presence: true

      def token_count
        (input_tokens || 0) + (output_tokens || 0)
      end
    end
  RUBY
end
