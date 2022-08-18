require "functions_framework"
require "net/http"
require "ed25519"
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

FunctionsFramework.http "discord-proxy" do |request|
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

  payload = {
    "context" => {
      "eventId" => "1144231683168617",
      "timestamp" => "2020-05-06T07:33:34.556Z",
      "eventType" => "google.pubsub.topic.publish",
      "resource" => {
        "service" => "pubsub.googleapis.com",
        "name" => "projects/sample-project/topics/gcf-test",
        "type" => "type.googleapis.com/google.pubsub.v1.PubsubMessage",
      },
    },
    "data" => {
      "@type" => "type.googleapis.com/google.pubsub.v1.PubsubMessage",
      "attributes" => {
        "attr1" => "attr1-value",
      },
      "data" => Base64.encode64(raw_body),
    }
  }

  Thread.new do
    Net::HTTP.post(
      URI("http://localhost:8080"),
      payload.to_json,
      {
        "Content-Type" => "application/json",
      }
    )
  end

  {
    "type" => 4,
    "data" => {
      "content" => "Proxied request to mc-scale",
    },
  }
end

