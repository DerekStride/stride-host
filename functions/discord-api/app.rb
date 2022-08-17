require "functions_framework"
require "ed25519"
require "google/cloud/pubsub"
require "pry-byebug" if ENV["PRY"]

PUB_KEY = ENV["VERIFY_KEY"]
VERIFY_KEY = Ed25519::VerifyKey.new([PUB_KEY].pack("H*"))

SIG_HEADER = "HTTP_X_SIGNATURE_ED25519"
TS_HEADER = "HTTP_X_SIGNATURE_TIMESTAMP"
TOPIC = "discord-events"

UNKNOWN_COMMAND = {
  "type" => 4,
  "data" => {
    "content" => "Unknown command.",
  },
}

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

  result = UNKNOWN_COMMAND

  if body.dig("data", "name") == "mc-scale"
    client = Google::Cloud::PubSub.new
    topic = client.topic(TOPIC)

    topic.publish(JSON.dump(body["data"]))
    scale_up = body.dig("data", "options", 0, "value") == "on"

    result = {
      "type" => 4,
      "data" => {
        "content" => "Turning the server #{scale_up ? "on" : "off"}.",
      },
    }
  end

  result
end
