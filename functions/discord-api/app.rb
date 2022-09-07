require "functions_framework"
require "ed25519"
require "google/cloud/pubsub"
require "pry-byebug" if ENV["PRY"]

PUB_KEY = ENV["VERIFY_KEY"]
VERIFY_KEY = Ed25519::VerifyKey.new([PUB_KEY].pack("H*"))

SIG_HEADER = "HTTP_X_SIGNATURE_ED25519"
TS_HEADER = "HTTP_X_SIGNATURE_TIMESTAMP"

DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE = { "type" => 5 }
UNKNOWN_COMMAND = {
  "type" => 4,
  "data" => {
    "content" => "Unknown command.",
  },
}

def response_message(message)
  { "type" => 4, "data" => { "content" => message } }
end

def publish(topic, message)
  client = Google::Cloud::PubSub.new
  topic = client.topic(topic)
  topic.publish(message)
end

FunctionsFramework.http "discord-api" do |request|
  raw_body = request.body.read
  sig_header = request.get_header(SIG_HEADER)
  signature = [sig_header].pack("H*")

  ts_header = request.get_header(TS_HEADER)
  message = ts_header + raw_body

  begin
    VERIFY_KEY.verify(signature, message)
  rescue Ed25519::VerifyError
    return [401, {}, ["invalid request signature"]]
  end
  body = JSON.parse(raw_body)

  return { "type" => 1 } if body["type"] == 1

  command = body.dig("data", "name")
  if command == "k8s-utils"
    subcommand = body.dig("data", "options", 0, "name")

    return response_message(<<~MSG) unless VALID_SUBCOMMANDS.include?(subcommand)
      Unknown subcommand: `#{subcommand}`.
    MSG

    if subcommand == "scale-up"
      publish("k8s-utils-scale-up", raw_body)
    elsif subcommand == "scale-down"
      publish("k8s-utils-scale-down", raw_body)
    elsif subcommand == "status"
      publish("k8s-utils-status", raw_body)
    end

    return DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
  elsif command == "mc-scale"
    subcommand = body.dig("data", "options", 0, "value")

    if subcommand == "on" || subcommand == "off"
      publish("discord-events", raw_body)

      return response_message(<<~MSG)
        The command `/mc-scale` is deprecated use `/k8s-utils` instead.

        Turning the server #{subcommand}.
      MSG
    elsif subcommand == "status"
      publish("discord-events", raw_body)

      return response_message(<<~MSG)
        The command `/mc-scale` is deprecated use `/k8s-utils` instead.

        Fetching server status.
      MSG
    end
  end

  UNKNOWN_COMMAND
end
